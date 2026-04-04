import Foundation
import Combine
import CloudKit
import ObjectiveC
import Network
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum CloudReachabilityStatus: String, Equatable {
    case unknown
    case online
    case constrained
    case offline
}

enum CloudSyncState: Equatable {
    case idle
    case syncing
    case degraded
}

private struct CloudRequestTimeoutError: LocalizedError {
    let operationName: String

    var errorDescription: String? {
        "Connection timed out while syncing \(operationName)."
    }
}

private final class TimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var hasResumed = false

    nonisolated func claimResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !hasResumed else { return false }
        hasResumed = true
        return true
    }
}

struct ImageSaveResult {
    let asset: CKAsset
    let cachedPath: String?
    let tempURL: URL
}

struct SourceExportSnapshot {
    let categories: [Category]
    let tags: [Tag]
    let recipes: [Recipe]
}

private struct PendingFavoriteOperation: Codable {
    let recipeRecordName: String
    let recipeZoneName: String
    let recipeZoneOwnerName: String
    let isFavorite: Bool

    init(recipeID: CKRecord.ID, isFavorite: Bool) {
        self.recipeRecordName = recipeID.recordName
        self.recipeZoneName = recipeID.zoneID.zoneName
        self.recipeZoneOwnerName = recipeID.zoneID.ownerName
        self.isFavorite = isFavorite
    }

    var recipeID: CKRecord.ID {
        let zoneID = CKRecordZone.ID(zoneName: recipeZoneName, ownerName: recipeZoneOwnerName)
        return CKRecord.ID(recordName: recipeRecordName, zoneID: zoneID)
    }
}

@MainActor
class CloudKitManager: ObservableObject {
    static let shared = CloudKitManager()
    
    // MARK: - Published Properties
    @Published var currentSource: Source?
    @Published var sources: [Source] = []
    @Published var categories: [Category] = []
    @Published var tags: [Tag] = []
    @Published var recipes: [Recipe] = []
    @Published var recipeCounts: [CKRecord.ID: Int] = [:]
    @Published var isLoading = false
    @Published var error: String?
    @Published var isCloudKitAvailable = true // Assume available until proven otherwise
    @Published var isOfflineMode = false
    @Published var canEditSharedSources = false
    @Published private(set) var favoriteRecipeKeys: Set<String> = []
    @Published private(set) var reachabilityStatus: CloudReachabilityStatus = .unknown
    @Published private(set) var cloudSyncState: CloudSyncState = .idle
    @Published private(set) var cloudStatusMessage: String?
    @Published private(set) var lastSuccessfulCloudSyncAt: Date?
    
    // MARK: - Private Properties
    let container: CKContainer
    private var privateDatabase: CKDatabase { container.privateCloudDatabase }
    private var sharedDatabase: CKDatabase { container.sharedCloudDatabase }
    private var userIdentifier: String? = UserDefaults.standard.string(forKey: "iCloudUserID")
    private let personalZoneID = CKRecordZone.ID(zoneName: "PersonalSources", ownerName: CKCurrentUserDefaultName)
    private lazy var personalZone: CKRecordZone = CKRecordZone(zoneID: personalZoneID)
    private var hasEnsuredPersonalZone = false
    private var ensurePersonalZoneTask: Task<Void, Never>?
    private let networkMonitor = NWPathMonitor()
    private let networkMonitorQueue = DispatchQueue(label: "iCook.CloudKitNetworkMonitor")
    private let cloudRequestTimeoutSeconds: Double = 12
    private var activeCloudRequestCount = 0
    
    // Caches
    private var sourceCache: [CKRecord.ID: Source] = [:]
    private var categoryCache: [CKRecord.ID: Category] = [:]
    private var tagCache: [CKRecord.ID: Tag] = [:]
    private var recipeCache: [CKRecord.ID: Recipe] = [:]
    private enum CacheFileType: String {
        case categories
        case tags
        case recipes
        case recipeCounts
    }
    private lazy var cacheDirectoryURL: URL = {
        let defaultURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let directory = defaultURL.appendingPathComponent("CloudKitCache", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }()
    private lazy var imageCacheDirectory: URL = {
        let directory = cacheDirectoryURL.appendingPathComponent("Images", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }()
    private var participantIdentityCache: [CKRecord.ID: CKUserIdentity] = [:]
    private var sharedSourceEditability: [CKRecord.ID: Bool] = [:]
    private var locallyDeletedSourceIDs = Set<CKRecord.ID>()
    private var pendingFavoriteOperations: [String: PendingFavoriteOperation] = [:]
    private let favoriteRecipeKeysKey = "FavoriteRecipeKeys"
    private let pendingFavoriteOperationsKey = "PendingFavoriteOperations"
    private let favoriteMigrationCompletedKey = "FavoriteRecipeCloudMigrationCompleted"
    private let canonicalFavoriteOwnerToken = "__me__"
    private let lastSuccessfulCloudSyncAtKey = "LastSuccessfulCloudSyncAt"
    
    init() {
        self.container = CKContainer(identifier: "iCloud.com.georgebabichev.iCook")
        self.lastSuccessfulCloudSyncAt = UserDefaults.standard.object(forKey: lastSuccessfulCloudSyncAtKey) as? Date
        startNetworkMonitor()
        loadSharedSourceIDs()
        loadFavoriteStateLocalCache()
        // Load from local cache immediately
        loadSourcesLocalCache()
        Task {
            await setupiCloudUser()
            if isCloudKitAvailable {
                await ensurePersonalZoneExists()
                await loadFavorites()
            }
        }
    }

    private func startNetworkMonitor() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.handleNetworkPathUpdate(path)
            }
        }
        networkMonitor.start(queue: networkMonitorQueue)
    }

    private func handleNetworkPathUpdate(_ path: NWPath) {
        let nextStatus: CloudReachabilityStatus
        switch path.status {
        case .satisfied:
            nextStatus = (path.isConstrained || path.isExpensive) ? .constrained : .online
        case .unsatisfied, .requiresConnection:
            nextStatus = .offline
        @unknown default:
            nextStatus = .unknown
        }

        reachabilityStatus = nextStatus

        if nextStatus == .offline {
            cloudStatusMessage = "You’re offline. Showing cached data."
        } else if cloudSyncState != .degraded {
            cloudStatusMessage = nil
        }

        updateOfflineMode()
    }

    private func updateOfflineMode() {
        isOfflineMode = !isCloudKitAvailable || reachabilityStatus == .offline || cloudSyncState == .degraded
    }

    private func beginCloudRequest() {
        activeCloudRequestCount += 1
        if cloudSyncState != .degraded {
            cloudSyncState = .syncing
        }
        updateOfflineMode()
    }

    private func endCloudRequest() {
        activeCloudRequestCount = max(0, activeCloudRequestCount - 1)
        if activeCloudRequestCount == 0, cloudSyncState != .degraded {
            cloudSyncState = .idle
            if reachabilityStatus != .offline {
                cloudStatusMessage = nil
            }
        }
        updateOfflineMode()
    }

    private func markCloudDegraded(for error: Error, operationName: String) {
        guard isNetworkRelatedError(error) else { return }
        cloudSyncState = .degraded
        if error is CloudRequestTimeoutError {
            cloudStatusMessage = "Connection is weak. Showing cached data."
        } else if reachabilityStatus == .offline {
            cloudStatusMessage = "You’re offline. Showing cached data."
        } else {
            cloudStatusMessage = "Sync is unavailable right now. Showing cached data."
        }
        printD("Cloud request degraded for \(operationName): \(error.localizedDescription)")
        updateOfflineMode()
    }

    private func markCloudHealthyIfNeeded() {
        recordSuccessfulCloudSync()

        if cloudSyncState == .degraded {
            cloudSyncState = activeCloudRequestCount > 0 ? .syncing : .idle
        } else if activeCloudRequestCount == 0 {
            cloudSyncState = .idle
        }

        if reachabilityStatus != .offline {
            cloudStatusMessage = nil
        }
        updateOfflineMode()
    }

    private func recordSuccessfulCloudSync(at date: Date = Date()) {
        lastSuccessfulCloudSyncAt = date
        UserDefaults.standard.set(date, forKey: lastSuccessfulCloudSyncAtKey)
    }

    private nonisolated func withTimeout<T>(
        seconds: Double,
        operationName: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let state = TimeoutState()

        return try await withCheckedThrowingContinuation { continuation in
            let operationTask = Task { @MainActor in
                do {
                    let value = try await operation()
                    guard state.claimResume() else { return }
                    continuation.resume(returning: value)
                } catch {
                    guard state.claimResume() else { return }
                    continuation.resume(throwing: error)
                }
            }

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                operationTask.cancel()
                guard state.claimResume() else { return }
                continuation.resume(throwing: CloudRequestTimeoutError(operationName: operationName))
            }
        }
    }

    func prepareForRetry() {
        error = nil
        if reachabilityStatus != .offline {
            cloudStatusMessage = "Checking iCloud connection..."
        }
        updateOfflineMode()
    }
    
    // MARK: - Setup
    private func setupiCloudUser() async {
        do {
            let container = self.container
            let status = try await withTimeout(seconds: cloudRequestTimeoutSeconds, operationName: "iCloud account") {
                try await container.accountStatus()
            }
            guard status == .available else {
                isCloudKitAvailable = false
                switch status {
                case .noAccount:
                    self.error = "iCloud not available. Using local storage only."
                case .restricted:
                    self.error = "iCloud access is restricted for this account."
                case .couldNotDetermine:
                    self.error = "Could not determine iCloud account status."
                case .temporarilyUnavailable:
                    self.error = "iCloud is temporarily unavailable."
                case .available:
                    self.error = nil
                @unknown default:
                    self.error = "iCloud not available. Using local storage only."
                }
                cloudStatusMessage = self.error
                updateOfflineMode()
                printD("CloudKit unavailable due to account status: \(status.rawValue)")
                return
            }
        } catch {
            printD("Failed to get iCloud account status: \(error.localizedDescription)")
            if let ckError = error as? CKError, ckError.code == .notAuthenticated {
                isCloudKitAvailable = false
                self.error = "iCloud not available. Using local storage only."
                cloudStatusMessage = self.error
                updateOfflineMode()
                return
            }
        }
        
        do {
            let container = self.container
            let userRecord = try await withTimeout(seconds: cloudRequestTimeoutSeconds, operationName: "iCloud user") {
                try await container.userRecordID()
            }
            userIdentifier = userRecord.recordName
            UserDefaults.standard.set(userRecord.recordName, forKey: "iCloudUserID")
            normalizeFavoriteStateForCurrentUser()
            isCloudKitAvailable = true
            self.error = nil
            updateOfflineMode()
            printD("iCloud user authenticated successfully")
        } catch {
            printD("Error setting up iCloud user: \(error.localizedDescription)")
            if let ckError = error as? CKError, ckError.code == .notAuthenticated {
                isCloudKitAvailable = false
                printD("CloudKit unavailable: User not signed into iCloud. Using local-only mode.")
                self.error = "iCloud not available. Using local storage only."
                cloudStatusMessage = self.error
            } else if handleOfflineFallback(for: error) {
                self.error = "Network unavailable. Using cached data."
            } else {
                self.error = "Failed to connect to iCloud"
            }
            updateOfflineMode()
        }
    }
    
    private func ensureUserIdentifier() async {
        if let userIdentifier, !userIdentifier.isEmpty { return }
        do {
            let container = self.container
            let userRecord = try await withTimeout(seconds: cloudRequestTimeoutSeconds, operationName: "iCloud user") {
                try await container.userRecordID()
            }
            userIdentifier = userRecord.recordName
            UserDefaults.standard.set(userRecord.recordName, forKey: "iCloudUserID")
            normalizeFavoriteStateForCurrentUser()
            printD("Ensured userIdentifier: \(userRecord.recordName)")
        } catch {
            printD("Failed to ensure userIdentifier: \(error.localizedDescription)")
        }
    }
    
    
    // MARK: - Local Cache (UserDefaults backup)
    private func saveSourcesLocalCache() {
        do {
            let encoded = try JSONEncoder().encode(sources)
            UserDefaults.standard.set(encoded, forKey: "SourcesCache")
            printD("Cached \(sources.count) sources locally")
        } catch {
            printD("Error saving sources cache: \(error.localizedDescription)")
        }
    }
    
    func saveCurrentSourceID() {
        if let sourceID = currentSource?.id {
            UserDefaults.standard.set(sourceID.recordName, forKey: "SelectedSourceID")
            UserDefaults.standard.set(sourceID.zoneID.zoneName, forKey: "SelectedSourceZoneName")
            UserDefaults.standard.set(sourceID.zoneID.ownerName, forKey: "SelectedSourceZoneOwner")
            printD("Saved selected source: \(sourceID.recordName)")
        }
    }
    
    private func loadSourcesLocalCache() {
        do {
            guard let data = UserDefaults.standard.data(forKey: "SourcesCache") else { return }
            let decoded = try JSONDecoder().decode([Source].self, from: data)
            sources = decoded
            
            // Try to restore the previously selected source
            if let savedSourceID = UserDefaults.standard.string(forKey: "SelectedSourceID") {
                let savedZoneName = UserDefaults.standard.string(forKey: "SelectedSourceZoneName")
                let savedZoneOwner = UserDefaults.standard.string(forKey: "SelectedSourceZoneOwner") ?? CKCurrentUserDefaultName
                let savedRecordID: CKRecord.ID
                if let zoneName = savedZoneName {
                    let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: savedZoneOwner)
                    savedRecordID = CKRecord.ID(recordName: savedSourceID, zoneID: zoneID)
                } else {
                    savedRecordID = CKRecord.ID(recordName: savedSourceID)
                }
                if let savedSource = sources.first(where: { $0.id == savedRecordID }) {
                    currentSource = savedSource
                    printD("Restored previously selected source: \(savedSource.name)")
                    return
                }
            }
            
            // Fallback: pick default source if no saved selection
            if currentSource == nil, !sources.isEmpty {
                currentSource = sources.first(where: { $0.isPersonal }) ?? sources.first
            }
            printD("Loaded \(sources.count) sources from local cache")
        } catch {
            printD("Error loading sources cache: \(error.localizedDescription)")
        }
    }
    
    private func sanitizedFileComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(scalars)
    }
    
    private func cacheIdentifier(for id: CKRecord.ID) -> String {
        let components = [id.zoneID.ownerName, id.zoneID.zoneName, id.recordName]
        return components.map { sanitizedFileComponent($0) }.joined(separator: "_")
    }

    private func summarizedFavoriteKey(_ key: String) -> String {
        let components = key.split(separator: "|", omittingEmptySubsequences: false)
        guard components.count == 3 else { return key }
        return "\(components[0])|\(components[1])|\(components[2].suffix(8))"
    }

    private func favoriteTraceKeys(_ keys: some Sequence<String>) -> String {
        let values = Array(keys.prefix(5)).map(summarizedFavoriteKey)
        return values.isEmpty ? "[]" : "[\(values.joined(separator: ", "))]"
    }

    private func canonicalFavoriteOwnerName(_ ownerName: String) -> String {
        if ownerName == CKCurrentUserDefaultName {
            return canonicalFavoriteOwnerToken
        }
        if let userIdentifier, !userIdentifier.isEmpty, ownerName == userIdentifier {
            return canonicalFavoriteOwnerToken
        }
        return ownerName
    }

    private func normalizedFavoriteKey(_ key: String) -> String {
        let components = key.split(separator: "|", omittingEmptySubsequences: false)
        guard components.count == 3 else { return key }
        let ownerName = canonicalFavoriteOwnerName(String(components[0]))
        return [ownerName, String(components[1]), String(components[2])].joined(separator: "|")
    }

    func favoriteKey(for recipeID: CKRecord.ID) -> String {
        [
            canonicalFavoriteOwnerName(recipeID.zoneID.ownerName),
            recipeID.zoneID.zoneName,
            recipeID.recordName
        ].joined(separator: "|")
    }

    private func recipeID(fromFavoriteKey key: String) -> CKRecord.ID? {
        let components = key.split(separator: "|", omittingEmptySubsequences: false)
        guard components.count == 3 else { return nil }
        let ownerComponent = String(components[0])
        let ownerName = ownerComponent == canonicalFavoriteOwnerToken ? CKCurrentUserDefaultName : ownerComponent
        let zoneID = CKRecordZone.ID(zoneName: String(components[1]), ownerName: ownerName)
        return CKRecord.ID(recordName: String(components[2]), zoneID: zoneID)
    }

    private func favoriteRecordID(for recipeID: CKRecord.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: "favorite_\(cacheIdentifier(for: recipeID))", zoneID: personalZoneID)
    }

    private func favoriteRecord(for recipeID: CKRecord.ID) -> CKRecord {
        let record = CKRecord(recordType: "FavoriteRecipe", recordID: favoriteRecordID(for: recipeID))
        record["recipeRecordName"] = recipeID.recordName
        record["recipeZoneName"] = recipeID.zoneID.zoneName
        record["recipeZoneOwnerName"] = recipeID.zoneID.ownerName
        record["lastModified"] = Date()
        return record
    }

    private func favoriteRecipeID(from record: CKRecord) -> CKRecord.ID? {
        guard let recipeRecordName = record["recipeRecordName"] as? String,
              let recipeZoneName = record["recipeZoneName"] as? String,
              let recipeZoneOwnerName = record["recipeZoneOwnerName"] as? String else {
            return nil
        }
        let zoneID = CKRecordZone.ID(zoneName: recipeZoneName, ownerName: recipeZoneOwnerName)
        return CKRecord.ID(recordName: recipeRecordName, zoneID: zoneID)
    }

    private func fetchAllFavoriteRecords() async throws -> [CKRecord] {
        beginCloudRequest()
        defer { endCloudRequest() }

        var changeToken: CKServerChangeToken?
        var favoriteRecords: [CKRecord] = []

        repeat {
            let database = privateDatabase
            let zoneID = personalZoneID
            let currentChangeToken = changeToken
            let batch = try await withTimeout(seconds: cloudRequestTimeoutSeconds, operationName: "favorites") {
                try await database.recordZoneChanges(
                    inZoneWith: zoneID,
                    since: currentChangeToken,
                    desiredKeys: ["recipeRecordName", "recipeZoneName", "recipeZoneOwnerName"],
                    resultsLimit: 400
                )
            }

            let records = batch.modificationResultsByID.values.compactMap { result -> CKRecord? in
                guard case .success(let modification) = result else { return nil }
                let record = modification.record
                return record.recordType == "FavoriteRecipe" ? record : nil
            }
            favoriteRecords.append(contentsOf: records)
            changeToken = batch.changeToken

            if !batch.moreComing {
                break
            }
        } while true

        return favoriteRecords
    }

    private func persistFavoriteRecipeKeysCache() {
        UserDefaults.standard.set(Array(favoriteRecipeKeys).sorted(), forKey: favoriteRecipeKeysKey)
    }

    private func persistPendingFavoriteOperations() {
        do {
            let encoded = try JSONEncoder().encode(Array(pendingFavoriteOperations.values))
            UserDefaults.standard.set(encoded, forKey: pendingFavoriteOperationsKey)
        } catch {
            printD("Error saving pending favorite operations: \(error.localizedDescription)")
        }
    }

    private func effectiveFavoriteKeys(with serverKeys: Set<String>) -> Set<String> {
        var merged = serverKeys
        for operation in pendingFavoriteOperations.values {
            let key = favoriteKey(for: operation.recipeID)
            if operation.isFavorite {
                merged.insert(key)
            } else {
                merged.remove(key)
            }
        }
        return merged
    }

    private func loadFavoriteStateLocalCache() {
        if let cachedKeys = UserDefaults.standard.stringArray(forKey: favoriteRecipeKeysKey) {
            favoriteRecipeKeys = Set(cachedKeys.map(normalizedFavoriteKey))
        }

        if let data = UserDefaults.standard.data(forKey: pendingFavoriteOperationsKey) {
            do {
                let decoded = try JSONDecoder().decode([PendingFavoriteOperation].self, from: data)
                pendingFavoriteOperations = Dictionary(uniqueKeysWithValues: decoded.map { (favoriteKey(for: $0.recipeID), $0) })
            } catch {
                printD("Error loading pending favorite operations: \(error.localizedDescription)")
            }
        }

        let didCompleteMigration = UserDefaults.standard.bool(forKey: favoriteMigrationCompletedKey)
        if !didCompleteMigration, pendingFavoriteOperations.isEmpty, !favoriteRecipeKeys.isEmpty {
            for key in favoriteRecipeKeys {
                guard let recipeID = recipeID(fromFavoriteKey: key) else { continue }
                pendingFavoriteOperations[key] = PendingFavoriteOperation(recipeID: recipeID, isFavorite: true)
            }
            persistPendingFavoriteOperations()
            UserDefaults.standard.set(true, forKey: favoriteMigrationCompletedKey)
        }

        favoriteRecipeKeys = effectiveFavoriteKeys(with: favoriteRecipeKeys)
        persistFavoriteRecipeKeysCache()
        printD("[FavoritesTrace] loadFavoriteStateLocalCache cached=\(favoriteRecipeKeys.count) pending=\(pendingFavoriteOperations.count) keys=\(favoriteTraceKeys(favoriteRecipeKeys.sorted()))")
    }

    private func normalizeFavoriteStateForCurrentUser() {
        let previousKeys = favoriteRecipeKeys
        favoriteRecipeKeys = Set(favoriteRecipeKeys.map(normalizedFavoriteKey))
        pendingFavoriteOperations = Dictionary(
            uniqueKeysWithValues: pendingFavoriteOperations.values.map { (favoriteKey(for: $0.recipeID), $0) }
        )
        persistFavoriteRecipeKeysCache()
        persistPendingFavoriteOperations()
        if previousKeys != favoriteRecipeKeys {
            printD("[FavoritesTrace] normalizeFavoriteStateForCurrentUser user=\(userIdentifier ?? "nil") keysBefore=\(previousKeys.count) keysAfter=\(favoriteRecipeKeys.count) keys=\(favoriteTraceKeys(favoriteRecipeKeys.sorted()))")
        } else {
            printD("[FavoritesTrace] normalizeFavoriteStateForCurrentUser user=\(userIdentifier ?? "nil") keys=\(favoriteRecipeKeys.count) pending=\(pendingFavoriteOperations.count)")
        }
    }

    private func applyFavoriteStateLocally(_ isFavorite: Bool, for recipeID: CKRecord.ID) {
        let key = favoriteKey(for: recipeID)
        if isFavorite {
            favoriteRecipeKeys.insert(key)
        } else {
            favoriteRecipeKeys.remove(key)
        }
        persistFavoriteRecipeKeysCache()
    }

    private func queueFavoriteSync(_ isFavorite: Bool, for recipeID: CKRecord.ID) {
        let operation = PendingFavoriteOperation(recipeID: recipeID, isFavorite: isFavorite)
        pendingFavoriteOperations[favoriteKey(for: recipeID)] = operation
        persistPendingFavoriteOperations()
    }
    
    private func cacheFileURL(for type: CacheFileType, sourceID: CKRecord.ID, categoryID: CKRecord.ID? = nil) -> URL {
        var filename = "\(type.rawValue)_\(cacheIdentifier(for: sourceID))"
        if let categoryID = categoryID {
            filename += "_\(cacheIdentifier(for: categoryID))"
        }
        return cacheDirectoryURL.appendingPathComponent(filename + ".json")
    }
    
    // Track shared source IDs locally so we can mark them as shared even if the CloudKit flag is missing
    private var sharedSourceIDs: Set<String> = []
    private let sharedSourceIDsKey = "SharedSourceIDs"
    private let recentlyUnsharedKey = "RecentlyUnsharedIDs"
    private let revokedNotifiedKey = "RevokedNotifiedIDs"
    private var revokedNotifiedIDs: Set<String> = [] {
        didSet {
            UserDefaults.standard.set(Array(revokedNotifiedIDs), forKey: revokedNotifiedKey)
        }
    }
    private let revokedToastKey = "RevokedToastShown"
    private var revokedToastShownIDs: Set<String> = [] {
        didSet {
            UserDefaults.standard.set(Array(revokedToastShownIDs), forKey: revokedToastKey)
        }
    }
    // NOTE: we previously tried KVS sync; removed due to missing entitlement
    
    private func appIconThumbnailData() -> Data? {
#if os(iOS)
        // Load from assets and apply rounded mask
        if let image = UIImage(named: "AppIconShareThumbnail") ?? UIImage(named: "AppIconShareThumbnail.png") {
            let radius = min(image.size.width, image.size.height) * 0.22
            let renderer = UIGraphicsImageRenderer(size: image.size)
            let rounded = renderer.image { _ in
                let rect = CGRect(origin: .zero, size: image.size)
                UIBezierPath(roundedRect: rect, cornerRadius: radius).addClip()
                image.draw(in: rect)
            }
            return rounded.pngData()
        }
        // Fallback: try primary icon
        if let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String],
           let last = files.last,
           let image = UIImage(named: last) {
            let radius = min(image.size.width, image.size.height) * 0.22
            let renderer = UIGraphicsImageRenderer(size: image.size)
            let rounded = renderer.image { _ in
                let rect = CGRect(origin: .zero, size: image.size)
                UIBezierPath(roundedRect: rect, cornerRadius: radius).addClip()
                image.draw(in: rect)
            }
            return rounded.pngData()
        }
        return nil
#elseif os(macOS)
        if let image = NSImage(named: "AppIconShareThumbnail") ?? NSImage(named: "AppIconShareThumbnail.png") {
            return image.pngDataUsingTIFF()
        }
        if let tiff = NSApplication.shared.applicationIconImage.tiffRepresentation {
            return Data(tiff)
        }
        return nil
#else
        return nil
#endif
    }
    
    private func loadSharedSourceIDs() {
        if let ids = UserDefaults.standard.array(forKey: sharedSourceIDsKey) as? [String] {
            sharedSourceIDs = Set(ids)
            printD("Loaded sharedSourceIDs: \(sharedSourceIDs.count) \(sharedSourceIDs)")
        }
        if let unshared = UserDefaults.standard.array(forKey: recentlyUnsharedKey) as? [String] {
            recentlyUnsharedIDs = Set(unshared)
            printD("Loaded recentlyUnsharedIDs: \(recentlyUnsharedIDs.count) \(recentlyUnsharedIDs)")
        }
        // No ubiquitous merge; rely on CloudKit records and local cache only
        if let revoked = UserDefaults.standard.array(forKey: revokedNotifiedKey) as? [String] {
            revokedNotifiedIDs = Set(revoked)
            printD("Loaded revokedNotifiedIDs: \(revokedNotifiedIDs.count)")
        }
        if let toast = UserDefaults.standard.array(forKey: revokedToastKey) as? [String] {
            revokedToastShownIDs = Set(toast)
            printD("Loaded revokedToastShownIDs: \(revokedToastShownIDs.count)")
        }
        // Clear any stale shared IDs on app start if user explicitly unshared last session
        if !recentlyUnsharedIDs.isEmpty {
            sharedSourceIDs.subtract(recentlyUnsharedIDs)
            saveSharedSourceIDs()
        }
    }
    
    
    private func saveSharedSourceIDs() {
        UserDefaults.standard.set(Array(sharedSourceIDs), forKey: sharedSourceIDsKey)
    }
    
    // Track shared keys detected during a load pass so we can rebuild the cache cleanly.
    private var collectedSharedKeys: Set<String> = []
    private var isCollectingSharedKeys = false
    
    // Track sources explicitly unshared locally to avoid re-marking from stale data
    private var recentlyUnsharedIDs: Set<String> = [] {
        didSet {
            let arr = Array(recentlyUnsharedIDs)
            UserDefaults.standard.set(arr, forKey: recentlyUnsharedKey)
        }
    }
    
    private func markSharedSource(id: CKRecord.ID) {
        let key = cacheIdentifier(for: id)
        sharedSourceIDs.insert(key)
        recentlyUnsharedIDs.remove(key)
        saveSharedSourceIDs()
        if isCollectingSharedKeys {
            collectedSharedKeys.insert(key)
        }
    }
    
    private func unmarkSharedSource(id: CKRecord.ID) {
        let key = cacheIdentifier(for: id)
        sharedSourceIDs.remove(key)
        saveSharedSourceIDs()
    }
    
    /// Mark a source as shared locally so UI updates immediately after saving a share.
    func markSourceShared(_ source: Source) {
        markSharedSource(id: source.id)
        sources = sources.map { src in
            if src.id == source.id {
                var updated = src
                updated.isPersonal = isSharedOwner(src) ? true : false
                return updated
            }
            return src
        }
        sourceCache[source.id]?.isPersonal = isSharedOwner(source)
        if let current = currentSource, current.id == source.id {
            currentSource?.isPersonal = isSharedOwner(source)
        }
        saveSourcesLocalCache()
        saveCurrentSourceID()
    }
    
    private func saveCategoriesLocalCache(_ categories: [Category], for source: Source) {
        let url = cacheFileURL(for: .categories, sourceID: source.id)
        do {
            let encoded = try JSONEncoder().encode(categories)
            try encoded.write(to: url, options: .atomic)
            printD("Cached \(categories.count) categories for \(source.name)")
        } catch {
            printD("Error saving categories cache: \(error.localizedDescription)")
        }
    }
    
    private func loadCategoriesLocalCache(for source: Source) -> [Category]? {
        let url = cacheFileURL(for: .categories, sourceID: source.id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([Category].self, from: data)
        } catch {
            printD("Error loading categories cache: \(error.localizedDescription)")
            return nil
        }
    }

    private func saveTagsLocalCache(_ tags: [Tag], for source: Source) {
        let url = cacheFileURL(for: .tags, sourceID: source.id)
        do {
            let encoded = try JSONEncoder().encode(tags)
            try encoded.write(to: url, options: .atomic)
            printD("Cached \(tags.count) tags for \(source.name)")
        } catch {
            printD("Error saving tags cache: \(error.localizedDescription)")
        }
    }

    private func loadTagsLocalCache(for source: Source) -> [Tag]? {
        let url = cacheFileURL(for: .tags, sourceID: source.id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([Tag].self, from: data)
        } catch {
            printD("Error loading tags cache: \(error.localizedDescription)")
            return nil
        }
    }
    
    private func saveRecipesLocalCache(_ recipes: [Recipe], for source: Source, categoryID: CKRecord.ID?) {
        let url = cacheFileURL(for: .recipes, sourceID: source.id, categoryID: categoryID)
        do {
            let encoded = try JSONEncoder().encode(recipes)
            try encoded.write(to: url, options: .atomic)
            let scopeDescription = categoryID.map { "category \($0.recordName)" } ?? "all categories"
            printD("Cached \(recipes.count) recipes for source \(source.name) (\(scopeDescription))")
        } catch {
            printD("Error saving recipes cache: \(error.localizedDescription)")
        }
    }
    
    /// Persist a snapshot of recipes to the all-recipes cache for a source.
    func cacheRecipesSnapshot(_ recipes: [Recipe], for source: Source) {
        saveRecipesLocalCache(recipes, for: source, categoryID: nil)
    }
    
    private func loadRecipesLocalCache(for source: Source, categoryID: CKRecord.ID?) -> [Recipe]? {
        let url = cacheFileURL(for: .recipes, sourceID: source.id, categoryID: categoryID)
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                let decoded = try JSONDecoder().decode([Recipe].self, from: data)
                return decoded.map { recipeWithCachedImage($0, fromCloudKitRecord: false) }
            } catch {
                printD("Error loading recipes cache: \(error.localizedDescription)")
            }
        }
        
        // Fallback to global cache if category-specific cache is missing
        if let categoryID = categoryID {
            let globalURL = cacheFileURL(for: .recipes, sourceID: source.id, categoryID: nil)
            guard FileManager.default.fileExists(atPath: globalURL.path) else { return nil }
            do {
                let data = try Data(contentsOf: globalURL)
                let allRecipes = try JSONDecoder().decode([Recipe].self, from: data)
                let filtered = allRecipes.filter { $0.categoryID == categoryID }
                return filtered.map { recipeWithCachedImage($0, fromCloudKitRecord: false) }
            } catch {
                printD("Error loading fallback recipes cache: \(error.localizedDescription)")
            }
        }
        
        return nil
    }
    
    /// Load cached categories, recipe counts, and recipes for a source without network.
    func loadCachedData(for source: Source) {
        if let cachedCategories = loadCategoriesLocalCache(for: source) {
            categories = cachedCategories
        }
        if let cachedTags = loadTagsLocalCache(for: source) {
            tags = cachedTags
        } else {
            tags = []
        }
        let cachedCounts = loadRecipeCountsLocalCache(for: source)
        if !cachedCounts.isEmpty {
            recipeCounts = cachedCounts
        }
        if let cachedRecipes = loadRecipesLocalCache(for: source, categoryID: nil) {
            recipes = cachedRecipes
        }
    }
    
    private struct CachedRecordCount: Codable {
        let recordName: String
        let zoneName: String
        let zoneOwnerName: String
        let count: Int
        
        var recordID: CKRecord.ID {
            let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: zoneOwnerName)
            return CKRecord.ID(recordName: recordName, zoneID: zoneID)
        }
    }
    
    private func saveRecipeCountsLocalCache(_ counts: [CKRecord.ID: Int], for source: Source) {
        let url = cacheFileURL(for: .recipeCounts, sourceID: source.id)
        let entries = counts.map { key, value in
            CachedRecordCount(
                recordName: key.recordName,
                zoneName: key.zoneID.zoneName,
                zoneOwnerName: key.zoneID.ownerName,
                count: value
            )
        }
        do {
            let encoded = try JSONEncoder().encode(entries)
            try encoded.write(to: url, options: .atomic)
            printD("Cached recipe counts for \(source.name)")
        } catch {
            printD("Error saving recipe counts cache: \(error.localizedDescription)")
        }
    }
    
    private func loadRecipeCountsLocalCache(for source: Source) -> [CKRecord.ID: Int] {
        let url = cacheFileURL(for: .recipeCounts, sourceID: source.id)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            let data = try Data(contentsOf: url)
            let entries = try JSONDecoder().decode([CachedRecordCount].self, from: data)
            var counts: [CKRecord.ID: Int] = [:]
            for entry in entries {
                counts[entry.recordID] = entry.count
            }
            return counts
        } catch {
            printD("Error loading recipe counts cache: \(error.localizedDescription)")
            return [:]
        }
    }
    
    private func markOnlineIfNeeded() {
        markCloudHealthyIfNeeded()
    }
    
    private func isNetworkRelatedError(_ error: Error) -> Bool {
        if error is CloudRequestTimeoutError {
            return true
        }
        if let ckError = error as? CKError {
            switch ckError.code {
            case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy:
                return true
            case .partialFailure:
                if let partialErrors = ckError.userInfo[CKPartialErrorsByItemIDKey] as? [CKRecord.ID: Error] {
                    return partialErrors.values.contains { isNetworkRelatedError($0) }
                }
            default:
                break
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet,
                    .timedOut,
                    .networkConnectionLost,
                    .cannotFindHost,
                    .cannotConnectToHost,
                    .dnsLookupFailed:
                return true
            default:
                break
            }
        }
        return false
    }

    private func exportDatabaseContext(for source: Source) -> (database: CKDatabase, zoneID: CKRecordZone.ID) {
        let isOwner = isSharedOwner(source)
        let database = isOwner || source.isPersonal ? privateDatabase : sharedDatabase
        let zoneID = isOwner || source.isPersonal ? personalZoneID : source.id.zoneID
        return (database, zoneID)
    }

    func exportSnapshot(for source: Source) async -> SourceExportSnapshot {
        let cachedCategories = loadCategoriesLocalCache(for: source) ?? []
        let cachedTags = loadTagsLocalCache(for: source) ?? []
        let cachedRecipes = loadRecipesLocalCache(for: source, categoryID: nil) ?? []
        let cachedSnapshot = SourceExportSnapshot(
            categories: cachedCategories,
            tags: cachedTags,
            recipes: cachedRecipes
        )

        guard isCloudKitAvailable else {
            return cachedSnapshot
        }

        do {
            let sourceReference = CKRecord.Reference(recordID: source.id, action: .none)
            let context = exportDatabaseContext(for: source)

            let categoryQuery = CKQuery(
                recordType: "Category",
                predicate: NSPredicate(format: "sourceID == %@", sourceReference)
            )
            categoryQuery.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]

            let tagQuery = CKQuery(
                recordType: "Tag",
                predicate: NSPredicate(format: "sourceID == %@", sourceReference)
            )
            tagQuery.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]

            let recipeQuery = CKQuery(
                recordType: "Recipe",
                predicate: NSPredicate(format: "sourceID == %@", sourceReference)
            )
            recipeQuery.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]

            let categoryResults = try await fetchAllQueryMatchResults(
                matching: categoryQuery,
                in: context.database,
                zoneID: context.zoneID
            )
            let categories = categoryResults.compactMap { _, result -> Category? in
                guard case .success(let record) = result else { return nil }
                return Category.from(record)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            let tagResults = try await fetchAllQueryMatchResults(
                matching: tagQuery,
                in: context.database,
                zoneID: context.zoneID
            )
            let tags = tagResults.compactMap { _, result -> Tag? in
                guard case .success(let record) = result else { return nil }
                return Tag.from(record)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            let recipeResults = try await fetchAllQueryMatchResults(
                matching: recipeQuery,
                in: context.database,
                zoneID: context.zoneID
            )
            let recipes = recipeResults.compactMap { _, result -> Recipe? in
                guard case .success(let record) = result,
                      let recipe = Recipe.from(record) else {
                    return nil
                }
                return recipeWithCachedImage(recipe)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            saveCategoriesLocalCache(categories, for: source)
            saveTagsLocalCache(tags, for: source)
            saveRecipesLocalCache(recipes, for: source, categoryID: nil)

            var recipeCounts: [CKRecord.ID: Int] = [:]
            for recipe in recipes {
                recipeCounts[recipe.categoryID, default: 0] += 1
            }
            saveRecipeCountsLocalCache(recipeCounts, for: source)
            markOnlineIfNeeded()

            return SourceExportSnapshot(categories: categories, tags: tags, recipes: recipes)
        } catch {
            if !handleOfflineFallback(for: error) {
                printD("Error building export snapshot for \(source.name): \(error.localizedDescription)")
            }
            return cachedSnapshot
        }
    }
    
    private func handleOfflineFallback(for error: Error) -> Bool {
        if isNetworkRelatedError(error) {
            markCloudDegraded(for: error, operationName: "CloudKit")
            printD("Network unavailable, falling back to cache: \(error.localizedDescription)")
            return true
        }
        return false
    }

    private func isFavoriteSchemaBootstrapError(_ error: Error) -> Bool {
        let description = error.localizedDescription.lowercased()
        return description.contains("did not find record type") || description.contains("not marked queryable")
    }

    private func shouldRetryFavoriteOperationAfterEnsuringZone(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        switch ckError.code {
        case .zoneNotFound, .userDeletedZone:
            return true
        default:
            return false
        }
    }

    private func isExistingFavoriteRecordError(_ error: Error) -> Bool {
        if let ckError = error as? CKError, ckError.code == .serverRecordChanged {
            return true
        }

        let description = error.localizedDescription.lowercased()
        return description.contains("already exists") || description.contains("record to insert already exists")
    }

    private func syncFavoriteOperation(_ operation: PendingFavoriteOperation) async throws {
        if operation.isFavorite {
            do {
                _ = try await privateDatabase.save(favoriteRecord(for: operation.recipeID))
            } catch {
                if isExistingFavoriteRecordError(error) {
                    // The desired state is already present on the server.
                    return
                }
                throw error
            }
        } else {
            do {
                try await privateDatabase.deleteRecord(withID: favoriteRecordID(for: operation.recipeID))
            } catch let ckError as CKError where ckError.code == .unknownItem {
                // Deleting an already-removed favorite is a valid converged state.
            }
        }
    }
    
    private func versionToken(for date: Date) -> String {
        let millis = Int(date.timeIntervalSince1970 * 1000)
        return "v\(millis)"
    }
    
    private func imageCacheURL(for recipeID: CKRecord.ID, versionToken: String) -> URL {
        let filename = cacheIdentifier(for: recipeID) + "_\(versionToken).asset"
        return imageCacheDirectory.appendingPathComponent(filename)
    }
    
    private func removeCachedImages(for recipeID: CKRecord.ID) {
        let prefix = cacheIdentifier(for: recipeID) + "_"
        let fm = FileManager.default
        if let contents = try? fm.contentsOfDirectory(atPath: imageCacheDirectory.path) {
            for entry in contents where entry.hasPrefix(prefix) && entry.hasSuffix(".asset") {
                let url = imageCacheDirectory.appendingPathComponent(entry)
                try? fm.removeItem(at: url)
            }
        }
        // Clean up legacy single-file cache name
        let legacy = imageCacheDirectory.appendingPathComponent(cacheIdentifier(for: recipeID) + ".asset")
        if fm.fileExists(atPath: legacy.path) {
            try? fm.removeItem(at: legacy)
        }
    }
    
    private func cacheImageData(_ data: Data, for recipeID: CKRecord.ID, versionToken: String) -> String? {
        let destination = imageCacheURL(for: recipeID, versionToken: versionToken)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try data.write(to: destination, options: .atomic)
            let attrs = try FileManager.default.attributesOfItem(atPath: destination.path)
            if let size = attrs[.size] as? NSNumber, size.intValue > 0 {
                return destination.path
            } else {
                try? FileManager.default.removeItem(at: destination)
                return cachedImagePath(for: recipeID)
            }
        } catch {
            return cachedImagePath(for: recipeID)
        }
    }
    
    private func cacheImageAsset(_ asset: CKAsset, for recipeID: CKRecord.ID, versionToken: String, existingPath: String?) -> String? {
        guard let sourceURL = asset.fileURL else {
            // If we don't have a local asset file, keep the existing cached image if any
            return existingPath ?? cachedImagePath(for: recipeID)
        }
        
        let destination = imageCacheURL(for: recipeID, versionToken: versionToken)
        do {
            // Replace any existing versioned file to avoid "item exists" errors
            if FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            // Validate non-empty file; otherwise keep existing
            let attrs = try FileManager.default.attributesOfItem(atPath: destination.path)
            if let size = attrs[.size] as? NSNumber, size.intValue > 0 {
                return destination.path
            } else {
                try? FileManager.default.removeItem(at: destination)
                return existingPath ?? cachedImagePath(for: recipeID)
            }
        } catch {
            return existingPath ?? cachedImagePath(for: recipeID)
        }
    }
    
    private func cachedImagePath(for recipeID: CKRecord.ID, versionToken: String? = nil) -> String? {
        let prefix = cacheIdentifier(for: recipeID) + "_"
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: imageCacheDirectory.path) else {
            let legacy = imageCacheDirectory.appendingPathComponent(cacheIdentifier(for: recipeID) + ".asset")
            return fm.fileExists(atPath: legacy.path) ? legacy.path : nil
        }
        
        let matches = contents
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".asset") }
            .sorted()
        
        if let versionToken = versionToken,
           let match = matches.first(where: { $0.contains("_\(versionToken).asset") }) {
            return imageCacheDirectory.appendingPathComponent(match).path
        }
        
        if let latest = matches.last {
            return imageCacheDirectory.appendingPathComponent(latest).path
        }
        
        let legacy = imageCacheDirectory.appendingPathComponent(cacheIdentifier(for: recipeID) + ".asset")
        return fm.fileExists(atPath: legacy.path) ? legacy.path : nil
    }
    
    /// Public helper to retrieve a cached image path for a recipe if it exists.
    func cachedImagePathForRecipe(_ recipeID: CKRecord.ID) -> String? {
        cachedImagePath(for: recipeID)
    }

    /// Public helper to retrieve cached recipes for a source/category without hitting network.
    func cachedRecipes(for source: Source, categoryID: CKRecord.ID?) -> [Recipe]? {
        loadRecipesLocalCache(for: source, categoryID: categoryID)
    }

    /// Public helper to cache recipes for a specific scope (all or per-category).
    func cacheRecipes(_ recipes: [Recipe], for source: Source, categoryID: CKRecord.ID?) {
        saveRecipesLocalCache(recipes, for: source, categoryID: categoryID)
    }
    
    private func removeCachedImage(for recipeID: CKRecord.ID) {
        removeCachedImages(for: recipeID)
    }

    func loadFavorites() async {
        await ensureUserIdentifier()
        normalizeFavoriteStateForCurrentUser()
        printD("[FavoritesTrace] loadFavorites start user=\(userIdentifier ?? "nil") cloudAvailable=\(isCloudKitAvailable) cached=\(favoriteRecipeKeys.count) pending=\(pendingFavoriteOperations.count)")

        guard isCloudKitAvailable else {
            favoriteRecipeKeys = effectiveFavoriteKeys(with: favoriteRecipeKeys)
            persistFavoriteRecipeKeysCache()
            printD("[FavoritesTrace] loadFavorites offline merged=\(favoriteRecipeKeys.count) keys=\(favoriteTraceKeys(favoriteRecipeKeys.sorted()))")
            return
        }

        await ensurePersonalZoneExists()

        do {
            try await syncPendingFavoriteOperations()
            let records = try await fetchAllFavoriteRecords()
            let serverKeys = Set(records.compactMap { record -> String? in
                guard let recipeID = favoriteRecipeID(from: record) else { return nil }
                return favoriteKey(for: recipeID)
            })

            favoriteRecipeKeys = effectiveFavoriteKeys(with: serverKeys)
            persistFavoriteRecipeKeysCache()
            markOnlineIfNeeded()
            printD("[FavoritesTrace] loadFavorites success server=\(serverKeys.count) merged=\(favoriteRecipeKeys.count) keys=\(favoriteTraceKeys(favoriteRecipeKeys.sorted()))")
        } catch {
            if handleOfflineFallback(for: error) {
                favoriteRecipeKeys = effectiveFavoriteKeys(with: favoriteRecipeKeys)
                persistFavoriteRecipeKeysCache()
                printD("[FavoritesTrace] loadFavorites offlineFallback merged=\(favoriteRecipeKeys.count) error=\(error.localizedDescription)")
                return
            }

            let errorDescription = error.localizedDescription
            if isFavoriteSchemaBootstrapError(error) {
                favoriteRecipeKeys = effectiveFavoriteKeys(with: favoriteRecipeKeys)
                persistFavoriteRecipeKeysCache()
                printD("[FavoritesTrace] loadFavorites bootstrapError preserved=\(favoriteRecipeKeys.count) error=\(errorDescription)")
                return
            }

            printD("Error loading favorites: \(errorDescription)")
            favoriteRecipeKeys = effectiveFavoriteKeys(with: favoriteRecipeKeys)
            persistFavoriteRecipeKeysCache()
            printD("[FavoritesTrace] loadFavorites error preserved=\(favoriteRecipeKeys.count) error=\(errorDescription)")
        }
    }

    func setFavorite(_ isFavorite: Bool, for recipeID: CKRecord.ID) async -> Bool {
        error = nil
        applyFavoriteStateLocally(isFavorite, for: recipeID)
        queueFavoriteSync(isFavorite, for: recipeID)
        printD("[FavoritesTrace] setFavorite value=\(isFavorite) recipe=\(recipeID.recordName.suffix(8)) key=\(summarizedFavoriteKey(favoriteKey(for: recipeID))) local=\(favoriteRecipeKeys.count) pending=\(pendingFavoriteOperations.count)")

        guard isCloudKitAvailable else {
            return true
        }

        do {
            await ensurePersonalZoneExists()
            try await syncPendingFavoriteOperations(surfaceErrorForKey: favoriteKey(for: recipeID))
            markOnlineIfNeeded()
        } catch {
            if handleOfflineFallback(for: error) {
                return true
            }

            printD("Error syncing favorite state: \(error.localizedDescription)")
            self.error = "Failed to sync favorites"
        }

        return true
    }

    private func syncPendingFavoriteOperations(surfaceErrorForKey: String? = nil) async throws {
        let operations = pendingFavoriteOperations.values.sorted {
            favoriteKey(for: $0.recipeID) < favoriteKey(for: $1.recipeID)
        }

        printD("[FavoritesTrace] syncPendingFavoriteOperations start count=\(operations.count) surfaceKey=\(surfaceErrorForKey.map(summarizedFavoriteKey) ?? "nil")")

        for operation in operations {
            let operationKey = favoriteKey(for: operation.recipeID)

            do {
                do {
                    try await syncFavoriteOperation(operation)
                } catch {
                    if shouldRetryFavoriteOperationAfterEnsuringZone(error) {
                        hasEnsuredPersonalZone = false
                        await ensurePersonalZoneExists()
                        try await syncFavoriteOperation(operation)
                    } else {
                        throw error
                    }
                }

                pendingFavoriteOperations.removeValue(forKey: operationKey)
                persistPendingFavoriteOperations()
                printD("[FavoritesTrace] syncPendingFavoriteOperations success key=\(summarizedFavoriteKey(operationKey)) isFavorite=\(operation.isFavorite) remaining=\(pendingFavoriteOperations.count)")
            } catch {
                if isNetworkRelatedError(error) {
                    printD("[FavoritesTrace] syncPendingFavoriteOperations networkError key=\(summarizedFavoriteKey(operationKey)) error=\(error.localizedDescription)")
                    throw error
                }

                if surfaceErrorForKey == operationKey && !isFavoriteSchemaBootstrapError(error) {
                    self.error = "Failed to sync favorites"
                }
                printD("[FavoritesTrace] syncPendingFavoriteOperations error key=\(summarizedFavoriteKey(operationKey)) isFavorite=\(operation.isFavorite) error=\(error.localizedDescription)")
                printD("Error syncing pending favorite operation: \(error.localizedDescription)")
            }
        }
    }
    
    private func recipeWithCachedImage(_ recipe: Recipe, fromCloudKitRecord: Bool = true) -> Recipe {
        var updatedRecipe = recipe
        let fm = FileManager.default
        let token = versionToken(for: recipe.lastModified)

        guard recipe.imageAsset != nil else {
            if fromCloudKitRecord {
                removeCachedImages(for: recipe.id)
                updatedRecipe.cachedImagePath = nil
            } else if let current = recipe.cachedImagePath,
                      fm.fileExists(atPath: current) {
                updatedRecipe.cachedImagePath = current
            } else if let fallback = cachedImagePath(for: recipe.id),
                      fm.fileExists(atPath: fallback) {
                updatedRecipe.cachedImagePath = fallback
            } else {
                updatedRecipe.cachedImagePath = nil
            }
            return updatedRecipe
        }

        // Prefer an already-cached file for the exact record version.
        if let versionedPath = cachedImagePath(for: recipe.id, versionToken: token),
           fm.fileExists(atPath: versionedPath) {
            updatedRecipe.cachedImagePath = versionedPath
            return updatedRecipe
        }

        // If we have a currently rendered image, keep it unless we can materialize a newer version.
        // This avoids losing images for metadata-only updates (e.g. tag edits) where the asset itself
        // did not change and CloudKit may not provide a fresh local asset file during save.
        if let current = recipe.cachedImagePath,
           fm.fileExists(atPath: current) {
            if current.contains("_\(token).asset") {
                updatedRecipe.cachedImagePath = current
                return updatedRecipe
            }

            if let asset = recipe.imageAsset,
               let localPath = cacheImageAsset(asset, for: recipe.id, versionToken: token, existingPath: current),
               fm.fileExists(atPath: localPath) {
                updatedRecipe.cachedImagePath = localPath
            } else {
                updatedRecipe.cachedImagePath = current
            }
            return updatedRecipe
        }

        // No current cache path; try to materialize from asset or any legacy cache.
        if let asset = recipe.imageAsset,
           let localPath = cacheImageAsset(asset, for: recipe.id, versionToken: token, existingPath: nil),
           fm.fileExists(atPath: localPath) {
            updatedRecipe.cachedImagePath = localPath
        } else if let fallback = cachedImagePath(for: recipe.id),
                  fm.fileExists(atPath: fallback) {
            updatedRecipe.cachedImagePath = fallback
        } else {
            updatedRecipe.cachedImagePath = nil
        }
        return updatedRecipe
    }
    
    // MARK: - Source Management
    func loadSources() async {
        await ensureUserIdentifier()
        normalizeFavoriteStateForCurrentUser()

        isLoading = true
        isCollectingSharedKeys = true
        collectedSharedKeys.removeAll()
        defer {
            isLoading = false
            isCollectingSharedKeys = false
        }
        
        // Keep any locally cached shared sources so we don't drop them if SharedDB queries fail
        let cachedSharedSources = sources.filter { !$0.isPersonal }
        
        // If CloudKit is not available, use local cache only
        guard isCloudKitAvailable else {
            printD("CloudKit not available, using cached sources only")
            return
        }
        
        do {
            // Load personal sources from private database
            let personalSources: [Source]
            do {
                personalSources = try await fetchSourcesFromDatabase(privateDatabase, isPersonal: true)
            } catch let ckError as CKError where ckError.code == .zoneNotFound {
                printD("Personal zone missing during loadSources, recreating and retrying once")
                await ensurePersonalZoneExists()
                personalSources = try await fetchSourcesFromDatabase(privateDatabase, isPersonal: true)
            }
            
            var allSources = personalSources
            
            // Try to load shared sources from shared database
            var sharedSources: [Source] = []
            do {
                sharedSources = try await fetchSourcesFromDatabase(sharedDatabase, isPersonal: false)
            } catch {
                let errorDesc = error.localizedDescription
                // SharedDB doesn't support zone-wide queries, so this is expected
                if !errorDesc.contains("SharedDB does not support Zone Wide queries") {
                    printD("Note: Could not load shared sources: \(errorDesc)")
                }
            }
            // If none returned (due to SharedDB query limitations), enumerate shared zones.
            if sharedSources.isEmpty {
                let zoneSources = await fetchSharedSourcesViaZones()
                sharedSources.append(contentsOf: zoneSources)
            }
            allSources.append(contentsOf: sharedSources)
            
            // Clear any stale unshared flags for fetched shared sources before we normalize flags
            if !sharedSources.isEmpty {
                let fetchedKeysNow = Set(allSources.map { cacheIdentifier(for: $0.id) })
                let revived = recentlyUnsharedIDs.intersection(fetchedKeysNow)
                if !revived.isEmpty {
                    recentlyUnsharedIDs.subtract(revived)
                    printD("Cleared unshared flags for fetched shared sources: \(revived)")
                }
            }
            
            // Any fetched shared sources should clear stale unshared flags so they aren't filtered out
            if !sharedSources.isEmpty {
                let sharedKeys = sharedSources.map { cacheIdentifier(for: $0.id) }
                let cleared = recentlyUnsharedIDs.intersection(sharedKeys)
                if !cleared.isEmpty {
                    recentlyUnsharedIDs.subtract(cleared)
                    printD("Cleared unshared flags for fetched shared sources: \(cleared)")
                }
            }
            
            // Remove any cached shared sources that no longer exist (revoked/removed)
            let missingShared = cachedSharedSources.filter { cached in
                !allSources.contains(where: { $0.id == cached.id })
            }
            if !missingShared.isEmpty {
                printD("Pruning \(missingShared.count) missing shared sources from cache")
                for missing in missingShared {
                    sourceCache.removeValue(forKey: missing.id)
                    unmarkSharedSource(id: missing.id)
                    let key = cacheIdentifier(for: missing.id)
                    recentlyUnsharedIDs.insert(key)
                    // delete any cached files for this source
                    let fm = FileManager.default
                    let prefix = cacheIdentifier(for: missing.id)
                    if let files = try? fm.contentsOfDirectory(atPath: cacheDirectoryURL.path) {
                        for entry in files where entry.contains(prefix) {
                            let url = cacheDirectoryURL.appendingPathComponent(entry)
                            try? fm.removeItem(at: url)
                        }
                    }
                    // also clear any recipe/category caches for this source
                    categoryCache.removeValue(forKey: missing.id)
                    recipeCache = recipeCache.filter { $0.key.zoneID != missing.id.zoneID }
                }
            }
            
            // Normalize shared flag based on zone ownership
            // First, ensure recently unshared IDs are removed from shared cache
            if !recentlyUnsharedIDs.isEmpty {
                sharedSourceIDs.subtract(recentlyUnsharedIDs)
                saveSharedSourceIDs()
            }
            
            allSources = allSources.map { source in
                var updated = source
                let owner = isSharedOwner(source)
                let key = cacheIdentifier(for: source.id)
                var cachedShared = sharedSourceIDs.contains(key)
                let wasUnshared = recentlyUnsharedIDs.contains(key)
                if owner && wasUnshared {
                    recentlyUnsharedIDs.remove(key)
                }
                // If this is an owned/personal source and no longer in a shared zone, drop stale shared marker
                if owner && updated.isPersonal && !shouldBeSharedBasedOnZone(updated) && cachedShared {
                    sharedSourceIDs.remove(key)
                    saveSharedSourceIDs()
                    cachedShared = false
                }
                if (shouldBeSharedBasedOnZone(source) || cachedShared) && !wasUnshared {
                    updated.isPersonal = owner
                    markSharedSource(id: updated.id)
                } else if let userIdentifier, !userIdentifier.isEmpty, source.owner != userIdentifier {
                    updated.isPersonal = false
                    if !wasUnshared {
                        markSharedSource(id: updated.id)
                    } else {
                        printD("Skipping shared mark due to recent unshare: \(source.name)")
                    }
                }
                return updated
            }
            
            // Drop any recently unshared sources so they disappear from the list
            allSources = allSources.filter { source in
                let key = cacheIdentifier(for: source.id)
                let shouldDrop = recentlyUnsharedIDs.contains(key) && !isSharedOwner(source)
                if shouldDrop {
                    printD("Filtering out revoked source from list: \(source.name)")
                    sourceCache.removeValue(forKey: source.id)
                    unmarkSharedSource(id: source.id)
                }
                return !shouldDrop
            }
            
            // Prune sharedSourceIDs entries that no longer exist in the fetched list
            let fetchedKeys = Set(allSources.map { cacheIdentifier(for: $0.id) })
            // If a previously unshared key is now fetched again, clear its unshared flag
            let revived = recentlyUnsharedIDs.intersection(fetchedKeys)
            if !revived.isEmpty {
                recentlyUnsharedIDs.subtract(revived)
                printD("Cleared unshared flags for re-fetched shared sources: \(revived)")
            }
            let staleSharedKeys = sharedSourceIDs.subtracting(fetchedKeys)
            if !staleSharedKeys.isEmpty {
                printD("Pruning \(staleSharedKeys.count) stale shared keys from cache")
                sharedSourceIDs.subtract(staleSharedKeys)
                recentlyUnsharedIDs.formUnion(staleSharedKeys)
                saveSharedSourceIDs()
            }
            
            let fetchedSourceIDs = Set(allSources.map(\.id))
            let confirmedDeletedSourceIDs = locallyDeletedSourceIDs.subtracting(fetchedSourceIDs)
            if !confirmedDeletedSourceIDs.isEmpty {
                locallyDeletedSourceIDs.subtract(confirmedDeletedSourceIDs)
            }

            if !locallyDeletedSourceIDs.isEmpty {
                allSources.removeAll { locallyDeletedSourceIDs.contains($0.id) }
            }

            if let current = currentSource,
               !allSources.contains(where: { $0.id == current.id }) {
                currentSource = allSources.first
                saveCurrentSourceID()
            }
            
            // Sort with owned collections first (personal or shared owner), then by lastModified desc.
            allSources.sort { lhs, rhs in
                let lhsOwned = isSharedOwner(lhs) || lhs.isPersonal
                let rhsOwned = isSharedOwner(rhs) || rhs.isPersonal
                if lhsOwned != rhsOwned { return lhsOwned && !rhsOwned }
                return lhs.lastModified > rhs.lastModified
            }
            
            self.sources = allSources
            await refreshSharedSourceEditability(for: allSources)
            // Reset sharedSourceIDs to include any cached/shared markers plus fetched shared sources.
            let fetchedSharedKeys = Set(allSources.filter { !$0.isPersonal }.map { cacheIdentifier(for: $0.id) })
            let rebuiltSharedKeys = collectedSharedKeys.union(fetchedSharedKeys)
            sharedSourceIDs = rebuiltSharedKeys.intersection(fetchedKeys)
            saveSharedSourceIDs()
            
            if let currentID = currentSource?.id,
               let refreshed = allSources.first(where: { $0.id == currentID }) {
                currentSource = refreshed
            } else {
                currentSource = allSources.first
            }
            saveSourcesLocalCache()
            // Set default source if none selected
            if currentSource == nil, !allSources.isEmpty {
                currentSource = allSources.first(where: { $0.isPersonal }) ?? allSources.first
            }
            updateSharedEditabilityFlag()
        } catch {
            let errorDesc = error.localizedDescription
            // Silently handle schema/indexing errors - CloudKit is still setting up
            if !errorDesc.contains("Did not find record type") && !errorDesc.contains("not marked queryable") {
                printD("Error loading sources: \(errorDesc)")
            }
            // If no sources exist yet, simply stay empty and wait for user to create one
        }
    }
    
    private func fetchSourcesFromDatabase(_ database: CKDatabase, isPersonal: Bool) async throws -> [Source] {
        // Use a queryable field (lastModified) instead of TRUEPREDICATE to avoid "recordName is not marked queryable" error
        // This predicate matches all records where lastModified is after the distant past (i.e., all records)
        let predicate = NSPredicate(format: "lastModified >= %@", Date.distantPast as NSDate)
        let query = CKQuery(recordType: "Source", predicate: predicate)
        let zoneID: CKRecordZone.ID? = isPersonal ? personalZoneID : nil
        let results = try await fetchAllQueryMatchResults(matching: query, in: database, zoneID: zoneID)
        
        return results.compactMap { _, result in
            guard case .success(let record) = result,
                  var source = Source.from(record) else {
                return nil
            }
            if (source.owner.isEmpty || source.owner == "Unknown"),
               let userIdentifier, !userIdentifier.isEmpty {
                source.owner = userIdentifier
            }
            source.isPersonal = isPersonal
            // If the record is shared (owner side), mark and normalize
            if record.share != nil {
                markSharedSource(id: source.id)
                let owner = isOwnedByCurrentUser(source)
                // Owner keeps personal permissions; participants are marked shared
                source.isPersonal = owner ? true : false
                printD("Detected shared source via record.share: \(source.name) (owner=\(source.owner)) ownerMatch=\(owner)")
            }
            return source
        }
    }

    private typealias QueryMatchResults = [CKRecord.ID: Result<CKRecord, Error>]

    private func fetchAllQueryMatchResults(
        matching query: CKQuery,
        in database: CKDatabase,
        zoneID: CKRecordZone.ID?
    ) async throws -> QueryMatchResults {
        beginCloudRequest()
        defer { endCloudRequest() }

        var allResults: QueryMatchResults = [:]

        let queryDatabase = database
        let queryZoneID = zoneID
        let initialQuery = query
        let (initialResults, initialCursor) = try await withTimeout(seconds: cloudRequestTimeoutSeconds, operationName: "recipes") {
            try await queryDatabase.records(matching: initialQuery, inZoneWith: queryZoneID)
        }
        allResults.merge(initialResults) { existing, _ in existing }

        var nextCursor = initialCursor
        while let currentCursor = nextCursor {
            let pageDatabase = database
            let cursor = currentCursor
            let (pageResults, fetchedNextCursor) = try await withTimeout(seconds: cloudRequestTimeoutSeconds, operationName: "recipes") {
                try await pageDatabase.records(continuingMatchFrom: cursor)
            }
            allResults.merge(pageResults) { existing, _ in existing }
            nextCursor = fetchedNextCursor
        }

        markCloudHealthyIfNeeded()
        return allResults
    }
    
    func createSource(name: String, isPersonal: Bool = true) async -> Bool {
        error = nil
        await ensureUserIdentifier()
        // First-launch users can attempt creation before startup setup finishes.
        // Re-run auth setup to avoid a race with iCloud account initialization.
        await setupiCloudUser()
        guard isCloudKitAvailable else {
            self.error = "iCloud not available. Sign in to iCloud and try again."
            return false
        }
        if isPersonal {
            await ensurePersonalZoneExists()
        }
        let recordID = isPersonal
        ? CKRecord.ID(recordName: UUID().uuidString, zoneID: personalZoneID)
        : CKRecord.ID()
        let source = Source(
            id: recordID,
            name: name,
            isPersonal: isPersonal,
            owner: userIdentifier ?? UserDefaults.standard.string(forKey: "iCloudUserID") ?? "Unknown",
            lastModified: Date()
        )
        
        // If CloudKit is available, save to it
        if isCloudKitAvailable {
            do {
                let database = isPersonal ? privateDatabase : sharedDatabase
                let record = source.toCKRecord()
                printD("Saving source to CloudKit: \(source.name) (record: \(record.recordID.recordName))")
                let savedRecord = try await database.save(record)
                printD("Successfully saved to CloudKit: \(savedRecord.recordID.recordName)")
                
                if let savedSource = Source.from(savedRecord) {
                    sourceCache[savedSource.id] = savedSource
                    // Add to UI immediately without waiting for query
                    // Reassign the entire array so SwiftUI detects the change
                    self.sources = (sources + [savedSource]).sorted { $0.lastModified > $1.lastModified }
                    saveSourcesLocalCache()
                    if currentSource == nil {
                        currentSource = savedSource
                    }
                    printD("Source created: \(savedSource.name)")
                    return true
                }
                self.error = "Failed to decode created source record"
                return false
            } catch {
                printD("Error creating source: \(error.localizedDescription)")
                if let ckError = error as? CKError {
                    printD("CKError code: \(ckError.errorCode)")
                    printD("CKError description: \(ckError.errorUserInfo)")
                    switch ckError.code {
                    case .notAuthenticated:
                        self.error = "iCloud account not authenticated. Open Settings and sign in to iCloud."
                    case .permissionFailure:
                        self.error = "iCloud permission denied for this account."
                    case .quotaExceeded:
                        self.error = "iCloud storage quota exceeded for this account."
                    default:
                        self.error = "Failed to create source"
                    }
                } else {
                    self.error = "Failed to create source"
                }
                return false
            }
        } else {
            // CloudKit not available, save locally only
            printD("CloudKit not available, saving source locally only: \(source.name)")
            sourceCache[source.id] = source
            self.sources = (sources + [source]).sorted { $0.lastModified > $1.lastModified }
            saveSourcesLocalCache()
            if currentSource == nil {
                currentSource = source
            }
            printD("Source created locally: \(source.name)")
            return true
        }
    }
    
    func deleteSource(_ source: Source) async {
        error = nil
        guard source.isPersonal || isSharedOwner(source) else {
            self.error = "Only collection owners can delete it."
            return
        }

        locallyDeletedSourceIDs.insert(source.id)

        do {
            let isOwner = isSharedOwner(source)
            let database = isOwner || source.isPersonal ? privateDatabase : sharedDatabase
            let zoneID = source.id.zoneID
            let childRecordIDs = try await fetchChildRecordIDs(for: source.id, in: database, zoneID: zoneID)

            if !childRecordIDs.recipes.isEmpty {
                try await deleteRecords(withIDs: childRecordIDs.recipes, in: database)
            }
            if !childRecordIDs.categories.isEmpty {
                try await deleteRecords(withIDs: childRecordIDs.categories, in: database)
            }
            if !childRecordIDs.tags.isEmpty {
                try await deleteRecords(withIDs: childRecordIDs.tags, in: database)
            }

            try await database.deleteRecord(withID: source.id)

            for recipeID in childRecordIDs.recipes {
                recipeCache.removeValue(forKey: recipeID)
                removeCachedImages(for: recipeID)
            }
            for categoryID in childRecordIDs.categories {
                categoryCache.removeValue(forKey: categoryID)
                recipeCounts.removeValue(forKey: categoryID)
            }
            for tagID in childRecordIDs.tags {
                tagCache.removeValue(forKey: tagID)
            }

            categories.removeAll { $0.sourceID == source.id }
            tags.removeAll { $0.sourceID == source.id }
            recipes.removeAll { $0.sourceID == source.id }

            removeLocalCacheFiles(for: source)

            sourceCache.removeValue(forKey: source.id)
            // Remove from local array - reassign to ensure SwiftUI detects change
            self.sources = sources.filter { $0.id != source.id }
            unmarkSharedSource(id: source.id)
            let sourceKey = cacheIdentifier(for: source.id)
            sharedSourceIDs.remove(sourceKey)
            recentlyUnsharedIDs.remove(sourceKey)
            saveSharedSourceIDs()

            if currentSource?.id == source.id {
                currentSource = self.sources.first
                if currentSource == nil {
                    categories.removeAll()
                    tags.removeAll()
                    recipes.removeAll()
                    recipeCounts.removeAll()
                }
            }

            updateSharedEditabilityFlag()
            saveSourcesLocalCache()
            saveCurrentSourceID()
            printD("Deleted source and child records: \(source.name) (categories=\(childRecordIDs.categories.count), recipes=\(childRecordIDs.recipes.count), tags=\(childRecordIDs.tags.count))")
        } catch {
            locallyDeletedSourceIDs.remove(source.id)
            printD("Error deleting source: \(error.localizedDescription)")
            self.error = "Failed to delete source"
        }
    }

    private struct ChildRecordIDs {
        var categories: [CKRecord.ID] = []
        var recipes: [CKRecord.ID] = []
        var tags: [CKRecord.ID] = []
    }

    private func fetchChildRecordIDs(for sourceID: CKRecord.ID, in database: CKDatabase, zoneID: CKRecordZone.ID) async throws -> ChildRecordIDs {
        let sourceRef = CKRecord.Reference(recordID: sourceID, action: .none)
        let categories = try await fetchRecordIDs(recordType: "Category", sourceRef: sourceRef, in: database, zoneID: zoneID)
        let recipes = try await fetchRecordIDs(recordType: "Recipe", sourceRef: sourceRef, in: database, zoneID: zoneID)
        let tags = try await fetchRecordIDs(recordType: "Tag", sourceRef: sourceRef, in: database, zoneID: zoneID)
        return ChildRecordIDs(categories: categories, recipes: recipes, tags: tags)
    }

    private func fetchRecordIDs(
        recordType: String,
        sourceRef: CKRecord.Reference,
        in database: CKDatabase,
        zoneID: CKRecordZone.ID
    ) async throws -> [CKRecord.ID] {
        let predicate = NSPredicate(format: "sourceID == %@", sourceRef)
        let query = CKQuery(recordType: recordType, predicate: predicate)
        let results = try await fetchAllQueryMatchResults(matching: query, in: database, zoneID: zoneID)
        return results.compactMap { _, result in
            switch result {
            case .success(let record):
                return record.recordID
            case .failure(let error):
                printD("Failed to resolve \(recordType) during source deletion: \(error.localizedDescription)")
                return nil
            }
        }
    }

    private func deleteRecords(withIDs recordIDs: [CKRecord.ID], in database: CKDatabase) async throws {
        for recordID in recordIDs {
            do {
                try await database.deleteRecord(withID: recordID)
            } catch let ckError as CKError where ckError.code == .unknownItem {
                continue
            }
        }
    }

    private func removeLocalCacheFiles(for source: Source) {
        let fm = FileManager.default
        let directFiles = [
            cacheFileURL(for: .categories, sourceID: source.id),
            cacheFileURL(for: .tags, sourceID: source.id),
            cacheFileURL(for: .recipes, sourceID: source.id, categoryID: nil),
            cacheFileURL(for: .recipeCounts, sourceID: source.id)
        ]

        for url in directFiles where fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: url)
        }

        if let files = try? fm.contentsOfDirectory(at: cacheDirectoryURL, includingPropertiesForKeys: nil) {
            let recipePrefix = "recipes_\(cacheIdentifier(for: source.id))_"
            for url in files where url.lastPathComponent.hasPrefix(recipePrefix) {
                try? fm.removeItem(at: url)
            }
        }
    }
    
    func updateSource(_ source: Source, newName: String) async {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        guard isCloudKitAvailable && !isOfflineMode else {
            self.error = "You're offline. Renaming collections is disabled."
            return
        }
        guard source.isPersonal || isSharedOwner(source) else {
            printD("Update source denied for collaborator: \(source.name)")
            self.error = "Only collection owners can rename it."
            return
        }
        
        do {
            let database = source.isPersonal || isSharedOwner(source) ? privateDatabase : sharedDatabase
            let serverRecord = try await database.record(for: source.id)
            serverRecord["name"] = trimmedName
            serverRecord["lastModified"] = Date()
            
            let savedRecord = try await database.save(serverRecord)
            
            if var updatedSource = Source.from(savedRecord) {
                // Preserve shared markers for owners so UI stays in sync
                if savedRecord.share != nil {
                    markSharedSource(id: savedRecord.recordID)
                    updatedSource.isPersonal = isSharedOwner(source)
                }
                
                sourceCache[updatedSource.id] = updatedSource
                self.sources = sources.map { $0.id == updatedSource.id ? updatedSource : $0 }
                if currentSource?.id == updatedSource.id {
                    currentSource = updatedSource
                }
                saveSourcesLocalCache()
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .sourcesRefreshed, object: nil)
                }
                printD("Source renamed: \(updatedSource.name)")
            }
        } catch {
            printD("Error updating source: \(error.localizedDescription)")
            self.error = "Failed to rename collection"
        }
    }
    
    func isSharedSource(_ source: Source) -> Bool {
        let key = cacheIdentifier(for: source.id)
        if recentlyUnsharedIDs.contains(key) {
            // defensive: scrub any lingering shared flag
            sharedSourceIDs.remove(key)
            saveSharedSourceIDs()
            return false
        }
        if sharedSourceIDs.contains(key) {
            return true
        }
        // Treat anything outside the personal zone or marked non-personal as shared
        if !source.isPersonal {
            return true
        }
        if shouldBeSharedBasedOnZone(source) {
            return true
        }
        if let userIdentifier, !userIdentifier.isEmpty, source.owner != userIdentifier {
            return true
        }
        return false
    }
    
    func isSharedOwner(_ source: Source) -> Bool {
        guard let userIdentifier else { return false }
        let ownsByRecord = source.owner == userIdentifier
        let ownsByZone = source.id.zoneID.ownerName == CKCurrentUserDefaultName
        return ownsByRecord || ownsByZone
    }

    func canEditSharedSource(_ source: Source) -> Bool {
        if source.isPersonal || isSharedOwner(source) {
            return true
        }
        return sharedSourceEditability[source.id] ?? false
    }
    
    private func isOwnedByCurrentUser(_ source: Source) -> Bool {
        guard let userIdentifier else { return false }
        return source.owner == userIdentifier || source.id.zoneID.ownerName == CKCurrentUserDefaultName
    }
    
    private func resolveParticipantIdentities(in share: CKShare) async {
        let participants = share.participants
        guard !participants.isEmpty else { return }
        for participant in participants {
            if let recordID = participant.userIdentity.userRecordID {
                participantIdentityCache[recordID] = participant.userIdentity
                let displayName = participant.userIdentity.nameComponents?.formatted()
                ?? participant.userIdentity.lookupInfo?.emailAddress
                ?? "Unknown"
                printD("Resolved participant identity: \(displayName) for \(recordID.recordName)")
            }
        }
    }

    private func shouldBeSharedBasedOnZone(_ source: Source) -> Bool {
        let zoneID = source.id.zoneID
        if zoneID.zoneName != personalZoneID.zoneName { return true }
        if zoneID.ownerName != CKCurrentUserDefaultName { return true }
        return false
    }
    
    func removeSharedSourceLocally(_ source: Source) async {
        // Allow removal even if flagged personal; skip only if owner
        if isSharedOwner(source) && source.isPersonal {
            return
        }
        let wasCurrent = currentSource?.id == source.id
        // Attempt to delete the shared zone for this user so it disappears on all devices for this account
        do {
            try await sharedDatabase.deleteRecordZone(withID: source.id.zoneID)
            printD("Deleted shared zone for removed source: \(source.name)")
        } catch {
            printD("Delete shared zone (ignored if already gone) failed for \(source.name): \(error.localizedDescription)")
        }
        sources = sources.filter { $0.id != source.id }
        sourceCache.removeValue(forKey: source.id)
        unmarkSharedSource(id: source.id)
        let key = cacheIdentifier(for: source.id)
        recentlyUnsharedIDs.insert(key)
        printD("Removed shared source locally: \(source.name) key=\(key)")
        saveSourcesLocalCache()
        saveCurrentSourceID()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .sourcesRefreshed, object: nil)
        }
        if wasCurrent {
            currentSource = sources.first
            saveCurrentSourceID()
        }
        printD("Removed shared source locally: \(source.name)")
        
        if wasCurrent {
            categories.removeAll()
            recipes.removeAll()
            recipeCounts.removeAll()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .recipesRefreshed, object: nil)
            }
        }
    }
    
#if os(macOS)
    /// Participant leaves a shared source (removes themselves from the share).
    func leaveSharedSource(_ source: Source) async -> Bool {
        guard !isSharedOwner(source) else {
            printD("leaveSharedSource called for owner; ignoring.")
            return false
        }
        
        printD("Attempting to leave shared source: \(source.name) (\(source.id.recordName))")
        
        // Try to fetch the root record in the shared DB and use its share reference
        do {
            let rootRecord = try await sharedDatabase.record(for: source.id)
            if let shareRef = rootRecord.share {
                do {
                    try await sharedDatabase.deleteRecord(withID: shareRef.recordID)
                    printD("Deleted share record \(shareRef.recordID.recordName) for source \(source.name) to leave share.")
                } catch {
                    printD("Failed to delete share record for \(source.name): \(error.localizedDescription)")
                    self.error = "Failed to leave share"
                    return false
                }
            } else {
                printD("Root record has no share ref when leaving source: \(source.name)")
                self.error = "No share record found to leave"
                return false
            }
        } catch {
            printD("Failed to fetch root record in shared DB for \(source.name): \(error.localizedDescription)")
            self.error = "Failed to leave share"
            return false
        }
        
        printD("Proceeding to remove shared source locally after leaving: \(source.name)")
        await removeSharedSourceLocally(source)
        return true
    }
#endif

    private func fetchSharedSourcesViaZones() async -> [Source] {
        var sharedSources: [Source] = []
        do {
            let zones = try await sharedDatabase.allRecordZones()
            for zone in zones {
                let predicate = NSPredicate(value: true)
                let query = CKQuery(recordType: "Source", predicate: predicate)
                do {
                    let results = try await fetchAllQueryMatchResults(matching: query, in: sharedDatabase, zoneID: zone.zoneID)
                    let sourcesInZone = results.compactMap { _, result -> Source? in
                        guard case .success(let record) = result,
                              var source = Source.from(record) else {
                            return nil
                        }
                        source.isPersonal = false
                        return source
                    }
                    sharedSources.append(contentsOf: sourcesInZone)
                } catch {
                    printD("Failed to query shared zone \(zone.zoneID.zoneName): \(error.localizedDescription)")
                }
            }
        } catch {
            printD("Failed to list shared zones: \(error.localizedDescription)")
        }
        return sharedSources
    }
    
    // MARK: - Category Management
    func loadCategories(for source: Source) async {
        let sourceID = source.id
        isLoading = true
        defer { isLoading = false }
        let isOwner = isSharedOwner(source)
        printD("loadCategories: source=\(source.name), isPersonal=\(source.isPersonal), isOwner=\(isOwner), zoneOwner=\(source.id.zoneID.ownerName), zoneName=\(source.id.zoneID.zoneName)")
        
        if let cachedCategories = loadCategoriesLocalCache(for: source) {
            self.categories = cachedCategories
        }
        let cachedCounts = loadRecipeCountsLocalCache(for: source)
        if !cachedCounts.isEmpty {
            self.recipeCounts = cachedCounts
        }
        
        guard isCloudKitAvailable else {
            return
        }
        
        do {
            let predicate = NSPredicate(format: "sourceID == %@", CKRecord.Reference(recordID: sourceID, action: .none))
            let query = CKQuery(recordType: "Category", predicate: predicate)
            query.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
            
            var allCategories: [Category] = []
            
            // Try loading from the appropriate database
            let database = isOwner || source.isPersonal ? privateDatabase : sharedDatabase
            let zoneID = isOwner || source.isPersonal ? personalZoneID : source.id.zoneID
            do {
                let results = try await fetchAllQueryMatchResults(matching: query, in: database, zoneID: zoneID)
                let categories = results.compactMap { _, result -> Category? in
                    guard case .success(let record) = result,
                          let category = Category.from(record) else {
                        return nil
                    }
                    categoryCache[category.id] = category
                    return category
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                allCategories.append(contentsOf: categories)
            } catch {
                let errorDesc = error.localizedDescription
                // SharedDB doesn't support zone-wide queries, so this is expected
                if !errorDesc.contains("SharedDB does not support Zone Wide queries") {
                    throw error
                }
            }
            
            self.categories = allCategories
            saveCategoriesLocalCache(allCategories, for: source)
            await loadRecipeCounts(for: source)
            markOnlineIfNeeded()
        } catch {
            if isSharedSource(source), isShareRevokedError(error) {
                printD("Share revoked or inaccessible for \(source.name); removing locally")
                await removeSharedSourceLocally(source)
                return
            }
            if handleOfflineFallback(for: error) {
                if let cachedCategories = loadCategoriesLocalCache(for: source) {
                    self.categories = cachedCategories
                } else {
                    self.categories = []
                }
                let cachedCounts = loadRecipeCountsLocalCache(for: source)
                self.recipeCounts = cachedCounts
            } else {
                let errorDesc = error.localizedDescription
                // Silently handle "record type not found" errors - schema is still being created
                if !errorDesc.contains("Did not find record type") {
                    printD("Error loading categories: \(errorDesc)")
                    self.error = "Failed to load categories"
                }
                if let cachedCategories = loadCategoriesLocalCache(for: source) {
                    self.categories = cachedCategories
                } else {
                    self.categories = []
                }
                let cachedCounts = loadRecipeCountsLocalCache(for: source)
                self.recipeCounts = cachedCounts
            }
        }

        await loadTags(for: source)
    }

    func loadTags(for source: Source) async {
        let sourceID = source.id
        let isOwner = isSharedOwner(source)

        if let cachedTags = loadTagsLocalCache(for: source) {
            self.tags = cachedTags
        }

        guard isCloudKitAvailable else {
            return
        }

        do {
            let predicate = NSPredicate(format: "sourceID == %@", CKRecord.Reference(recordID: sourceID, action: .none))
            let query = CKQuery(recordType: "Tag", predicate: predicate)
            query.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]

            let database = isOwner || source.isPersonal ? privateDatabase : sharedDatabase
            let zoneID = isOwner || source.isPersonal ? personalZoneID : source.id.zoneID

            let results = try await fetchAllQueryMatchResults(matching: query, in: database, zoneID: zoneID)
            let fetchedTags = results.compactMap { _, result -> Tag? in
                guard case .success(let record) = result,
                      let tag = Tag.from(record) else {
                    return nil
                }
                tagCache[tag.id] = tag
                return tag
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            self.tags = fetchedTags
            saveTagsLocalCache(fetchedTags, for: source)
            markOnlineIfNeeded()
        } catch {
            if isSharedSource(source), isShareRevokedError(error) {
                printD("Share revoked or inaccessible while loading tags for \(source.name); removing locally")
                await removeSharedSourceLocally(source)
                return
            }
            if handleOfflineFallback(for: error) {
                if let cachedTags = loadTagsLocalCache(for: source) {
                    self.tags = cachedTags
                } else {
                    self.tags = []
                }
            } else {
                let errorDesc = error.localizedDescription
                // Silently handle schema bootstrapping
                if !errorDesc.contains("Did not find record type") {
                    printD("Error loading tags: \(errorDesc)")
                }
                if let cachedTags = loadTagsLocalCache(for: source) {
                    self.tags = cachedTags
                } else {
                    self.tags = []
                }
            }
        }
    }
    
    private func isShareRevokedError(_ error: Error) -> Bool {
        if let ck = error as? CKError {
            return ck.code == .zoneNotFound || ck.code == .unknownItem || ck.code == .permissionFailure
        }
        return false
    }
    
    func loadRecipeCounts(for source: Source) async {
        guard isCloudKitAvailable else {
            recipeCounts = loadRecipeCountsLocalCache(for: source)
            return
        }
        
        let predicate = NSPredicate(
            format: "sourceID == %@",
            CKRecord.Reference(recordID: source.id, action: .none)
        )
        let query = CKQuery(recordType: "Recipe", predicate: predicate)
        query.sortDescriptors = nil
        
        let isOwner = isSharedOwner(source)
        let database = isOwner || source.isPersonal ? privateDatabase : sharedDatabase
        let zoneID = isOwner || source.isPersonal ? personalZoneID : source.id.zoneID
        
        do {
            let results = try await fetchAllQueryMatchResults(matching: query, in: database, zoneID: zoneID)
            var counts: [CKRecord.ID: Int] = [:]
            
            for (_, result) in results {
                if case .success(let record) = result,
                   let categoryRef = record["categoryID"] as? CKRecord.Reference {
                    counts[categoryRef.recordID, default: 0] += 1
                }
            }
            
            recipeCounts = counts
            saveRecipeCountsLocalCache(counts, for: source)
            markOnlineIfNeeded()
        } catch {
            if handleOfflineFallback(for: error) {
                recipeCounts = loadRecipeCountsLocalCache(for: source)
            } else {
                let errorDesc = error.localizedDescription
                if !errorDesc.contains("Did not find record type") {
                    printD("Error loading recipe counts: \(errorDesc)")
                }
                recipeCounts = loadRecipeCountsLocalCache(for: source)
            }
        }
    }

    /// Returns total recipe count for a source without mutating the currently selected source state.
    /// Also refreshes the source's recipe-count local cache when online.
    func cachedTotalRecipeCount(for source: Source) -> Int {
        loadRecipeCountsLocalCache(for: source).values.reduce(0, +)
    }

    /// Returns total recipe count for a source without mutating the currently selected source state.
    /// Also refreshes the source's recipe-count local cache when online.
    func totalRecipeCount(for source: Source) async -> Int {
        let cachedTotal = cachedTotalRecipeCount(for: source)

        guard isCloudKitAvailable else {
            return cachedTotal
        }

        let predicate = NSPredicate(
            format: "sourceID == %@",
            CKRecord.Reference(recordID: source.id, action: .none)
        )
        let query = CKQuery(recordType: "Recipe", predicate: predicate)
        query.sortDescriptors = nil

        let isOwner = isSharedOwner(source)
        let database = isOwner || source.isPersonal ? privateDatabase : sharedDatabase
        let zoneID = isOwner || source.isPersonal ? personalZoneID : source.id.zoneID

        do {
            let results = try await fetchAllQueryMatchResults(matching: query, in: database, zoneID: zoneID)
            var counts: [CKRecord.ID: Int] = [:]
            var total = 0

            for (_, result) in results {
                guard case .success(let record) = result else { continue }
                total += 1
                if let categoryRef = record["categoryID"] as? CKRecord.Reference {
                    counts[categoryRef.recordID, default: 0] += 1
                }
            }

            saveRecipeCountsLocalCache(counts, for: source)
            markOnlineIfNeeded()
            return total
        } catch {
            if isSharedSource(source), isShareRevokedError(error) {
                printD("Share revoked or inaccessible while loading totals for \(source.name); removing locally")
                await removeSharedSourceLocally(source)
                return 0
            }
            if handleOfflineFallback(for: error) {
                return cachedTotal
            }
            let errorDesc = error.localizedDescription
            if !errorDesc.contains("Did not find record type") {
                printD("Error loading total recipe count for \(source.name): \(errorDesc)")
            }
            return cachedTotal
        }
    }
    
    func createCategory(name: String, icon: String, in source: Source) async {
        do {
            if source.isPersonal {
                await ensurePersonalZoneExists()
            }
            let recordID = makeRecordID(for: source)
            let category = Category(id: recordID, sourceID: source.id, name: name, icon: icon)
            
            let owner = isSharedOwner(source)
            let shared = isSharedSource(source)
            let database = owner || !shared ? privateDatabase : sharedDatabase
            let record = category.toCKRecord()
            if shared, record.parent == nil {
                record.parent = CKRecord.Reference(recordID: source.id, action: .none)
            }
            let savedRecord = try await database.save(record)
            
            if let savedCategory = Category.from(savedRecord) {
                categoryCache[savedCategory.id] = savedCategory
                // Add to UI immediately without re-querying CloudKit
                self.categories = (categories + [savedCategory]).sorted { $0.name < $1.name }
                self.recipeCounts[savedCategory.id] = self.recipeCounts[savedCategory.id] ?? 0
                saveCategoriesLocalCache(self.categories, for: source)
                saveRecipeCountsLocalCache(recipeCounts, for: source)
                printD("Category created: \(savedCategory.name)")
            }
        } catch {
            printD("Error creating category: \(error.localizedDescription)")
            self.error = "Failed to create category"
        }
    }
    
    func updateCategory(_ category: Category, in source: Source) async {
        do {
            let owner = isSharedOwner(source)
            let shared = isSharedSource(source)
            let database = owner || !shared ? privateDatabase : sharedDatabase
            
            // Fetch the server record first to preserve metadata
            let serverRecord = try await database.record(for: category.id)
            serverRecord["name"] = category.name
            serverRecord["icon"] = category.icon
            serverRecord["lastModified"] = Date()
            
            let savedRecord = try await database.save(serverRecord)
            
            if let savedCategory = Category.from(savedRecord) {
                categoryCache[savedCategory.id] = savedCategory
                // Update in local array without re-querying CloudKit
                self.categories = categories.map { $0.id == savedCategory.id ? savedCategory : $0 }
                saveCategoriesLocalCache(self.categories, for: source)
                printD("Category updated: \(savedCategory.name)")
            }
        } catch {
            printD("Error updating category: \(error.localizedDescription)")
            self.error = "Failed to update category"
        }
    }
    
    func deleteCategory(_ category: Category, in source: Source) async {
        do {
            let database = source.isPersonal ? privateDatabase : sharedDatabase
            try await database.deleteRecord(withID: category.id)
            categoryCache.removeValue(forKey: category.id)
            // Remove from local array without re-querying CloudKit
            self.categories = categories.filter { $0.id != category.id }
            self.recipeCounts.removeValue(forKey: category.id)
            saveCategoriesLocalCache(self.categories, for: source)
            saveRecipeCountsLocalCache(recipeCounts, for: source)
            printD("Category deleted: \(category.name)")
        } catch {
            printD("Error deleting category: \(error.localizedDescription)")
            self.error = "Failed to delete category"
        }
    }

    // MARK: - Tag Management
    func createTag(name: String, in source: Source) async {
        do {
            if source.isPersonal {
                await ensurePersonalZoneExists()
            }
            let recordID = makeRecordID(for: source)
            let tag = Tag(id: recordID, sourceID: source.id, name: name)

            let owner = isSharedOwner(source)
            let shared = isSharedSource(source)
            let database = owner || !shared ? privateDatabase : sharedDatabase
            let record = tag.toCKRecord()
            if shared, record.parent == nil {
                record.parent = CKRecord.Reference(recordID: source.id, action: .none)
            }
            let savedRecord = try await database.save(record)

            if let savedTag = Tag.from(savedRecord) {
                tagCache[savedTag.id] = savedTag
                self.tags = (tags + [savedTag]).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                saveTagsLocalCache(self.tags, for: source)
                printD("Tag created: \(savedTag.name)")
            }
        } catch {
            printD("Error creating tag: \(error.localizedDescription)")
            self.error = "Failed to create tag"
        }
    }

    func updateTag(_ tag: Tag, in source: Source) async {
        do {
            let owner = isSharedOwner(source)
            let shared = isSharedSource(source)
            let database = owner || !shared ? privateDatabase : sharedDatabase

            let serverRecord = try await database.record(for: tag.id)
            serverRecord["name"] = tag.name
            serverRecord["lastModified"] = Date()

            let savedRecord = try await database.save(serverRecord)

            if let savedTag = Tag.from(savedRecord) {
                tagCache[savedTag.id] = savedTag
                self.tags = tags.map { $0.id == savedTag.id ? savedTag : $0 }
                saveTagsLocalCache(self.tags, for: source)
                printD("Tag updated: \(savedTag.name)")
            }
        } catch {
            printD("Error updating tag: \(error.localizedDescription)")
            self.error = "Failed to update tag"
        }
    }

    func deleteTag(_ tag: Tag, in source: Source) async {
        do {
            let owner = isSharedOwner(source)
            let shared = isSharedSource(source)
            let database = owner || !shared ? privateDatabase : sharedDatabase
            try await database.deleteRecord(withID: tag.id)
            tagCache.removeValue(forKey: tag.id)
            self.tags = tags.filter { $0.id != tag.id }
            saveTagsLocalCache(self.tags, for: source)
            printD("Tag deleted: \(tag.name)")
        } catch {
            printD("Error deleting tag: \(error.localizedDescription)")
            self.error = "Failed to delete tag"
        }
    }
    
    // MARK: - Recipe Management
    func loadRecipes(for source: Source, category: Category? = nil, skipCache: Bool = false) async {
        isLoading = true
        defer { isLoading = false }
        
        // Serve cache immediately and refresh in background for a snappier UI
        if !skipCache,
           let cachedRecipes = loadRecipesLocalCache(for: source, categoryID: category?.id),
           !cachedRecipes.isEmpty {
            self.recipes = cachedRecipes
            guard isCloudKitAvailable else { return }
            
            Task { [weak self] in
                guard let self else { return }
                await self.fetchRecipesFromCloud(for: source, category: category)
            }
            return
        }
        
        guard isCloudKitAvailable else {
            return
        }
        
        await fetchRecipesFromCloud(for: source, category: category)
    }
    
    private func fetchRecipesFromCloud(for source: Source, category: Category? = nil) async {
        do {
            var predicate: NSPredicate
            if let category = category {
                predicate = NSPredicate(
                    format: "sourceID == %@ AND categoryID == %@",
                    CKRecord.Reference(recordID: source.id, action: .none),
                    CKRecord.Reference(recordID: category.id, action: .none)
                )
            } else {
                predicate = NSPredicate(
                    format: "sourceID == %@",
                    CKRecord.Reference(recordID: source.id, action: .none)
                )
            }
            
            let query = CKQuery(recordType: "Recipe", predicate: predicate)
            query.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
            
            var allRecipes: [Recipe] = []
            
            let isOwner = isSharedOwner(source)
            let database = isOwner || source.isPersonal ? privateDatabase : sharedDatabase
            let zoneID = isOwner || source.isPersonal ? personalZoneID : source.id.zoneID
            do {
                let results = try await fetchAllQueryMatchResults(matching: query, in: database, zoneID: zoneID)
                let recipes = results.compactMap { _, result -> Recipe? in
                    guard case .success(let record) = result,
                          let recipe = Recipe.from(record) else {
                        return nil
                    }
                    let recipeWithImage = recipeWithCachedImage(recipe)
                    recipeCache[recipeWithImage.id] = recipeWithImage
                    return recipeWithImage
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                allRecipes.append(contentsOf: recipes)
            } catch {
                let errorDesc = error.localizedDescription
                if !errorDesc.contains("SharedDB does not support Zone Wide queries") {
                    throw error
                }
            }
            
            self.recipes = allRecipes
            saveRecipesLocalCache(allRecipes, for: source, categoryID: category?.id)
            markOnlineIfNeeded()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .recipesRefreshed, object: nil)
            }
        } catch {
            if isSharedSource(source), isShareRevokedError(error) {
                printD("Share revoked or inaccessible for \(source.name); removing locally")
                await removeSharedSourceLocally(source)
                return
            }
            if handleOfflineFallback(for: error) {
                if let cachedRecipes = loadRecipesLocalCache(for: source, categoryID: category?.id) {
                    self.recipes = cachedRecipes
                } else {
                    self.recipes = []
                }
            } else {
                let errorDesc = error.localizedDescription
                if !errorDesc.contains("Did not find record type") {
                    printD("Error loading recipes: \(errorDesc)")
                    self.error = "Failed to load recipes"
                }
                if let cachedRecipes = loadRecipesLocalCache(for: source, categoryID: category?.id) {
                    self.recipes = cachedRecipes
                } else {
                    self.recipes = []
                }
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .recipesRefreshed, object: nil)
            }
        }
    }
    
    func loadRandomRecipes(for source: Source, skipCache: Bool = false) async {
        isLoading = true
        defer { isLoading = false }
        
        if !skipCache,
           let cachedAllRecipes = loadRecipesLocalCache(for: source, categoryID: nil),
                  !cachedAllRecipes.isEmpty {
            // Seed from cache to avoid empty UI while loading
            self.recipes = cachedAllRecipes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        
        guard isCloudKitAvailable else {
            return
        }
        
        do {
            let predicate = NSPredicate(
                format: "sourceID == %@",
                CKRecord.Reference(recordID: source.id, action: .none)
            )
            let query = CKQuery(recordType: "Recipe", predicate: predicate)
            query.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
            
            var allRecipes: [Recipe] = []
            
            // Try loading from the appropriate database
            let isOwner = isSharedOwner(source)
            let database = isOwner || source.isPersonal ? privateDatabase : sharedDatabase
            let zoneID = isOwner || source.isPersonal ? personalZoneID : source.id.zoneID
            do {
                let results = try await fetchAllQueryMatchResults(matching: query, in: database, zoneID: zoneID)
                let recipes = results.compactMap { _, result -> Recipe? in
                    guard case .success(let record) = result,
                          let recipe = Recipe.from(record) else {
                        return nil
                    }
                    let recipeWithImage = recipeWithCachedImage(recipe)
                    recipeCache[recipeWithImage.id] = recipeWithImage
                    return recipeWithImage
                }
                allRecipes.append(contentsOf: recipes)
            } catch {
                let errorDesc = error.localizedDescription
                // SharedDB doesn't support zone-wide queries, so this is expected
                if !errorDesc.contains("SharedDB does not support Zone Wide queries") {
                    throw error
                }
            }
            
            // Keep a consistent alphabetical order for the list
            let alphabetical = allRecipes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            saveRecipesLocalCache(alphabetical, for: source, categoryID: nil)
            self.recipes = alphabetical
            // Refresh per-category caches so names stay in sync across views
            let sourceCategories = categories.filter { $0.sourceID == source.id }
            for cat in sourceCategories {
                let filtered = alphabetical.filter { $0.categoryID == cat.id }
                saveRecipesLocalCache(filtered, for: source, categoryID: cat.id)
            }
            markOnlineIfNeeded()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .recipesRefreshed, object: nil)
            }
        } catch {
            if handleOfflineFallback(for: error) {
                if let cachedAllRecipes = loadRecipesLocalCache(for: source, categoryID: nil) {
                    self.recipes = cachedAllRecipes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                } else {
                    self.recipes = []
                }
            } else {
                if isSharedSource(source), isShareRevokedError(error) {
                    printD("Share revoked or inaccessible for \(source.name); removing locally (random load)")
                    await removeSharedSourceLocally(source)
                    return
                }
                let errorDesc = error.localizedDescription
                // Silently handle "record type not found" errors - schema is still being created
                if !errorDesc.contains("Did not find record type") {
                    printD("Error loading random recipes: \(errorDesc)")
                    self.error = "Failed to load recipes"
                }
                if let cachedAllRecipes = loadRecipesLocalCache(for: source, categoryID: nil) {
                    self.recipes = cachedAllRecipes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                } else {
                    self.recipes = []
                }
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .recipesRefreshed, object: nil)
            }
        }
    }
    
    func createRecipe(_ recipe: Recipe, in source: Source) async {
        do {
            let owner = isSharedOwner(source)
            let shared = isSharedSource(source)
            let database = owner || !shared ? privateDatabase : sharedDatabase
            let record = recipe.toCKRecord()
            if shared, record.parent == nil {
                record.parent = CKRecord.Reference(recordID: source.id, action: .none)
            }
            let savedRecord = try await database.save(record)
            
            if let savedRecipe = Recipe.from(savedRecord) {
                let recipeWithImage = recipeWithCachedImage(savedRecipe)
                recipeCache[recipeWithImage.id] = recipeWithImage
                printD("Recipe created: \(recipeWithImage.name)")
            }
            await loadRecipeCounts(for: source)
        } catch {
            printD("Error creating recipe: \(error.localizedDescription)")
            self.error = "Failed to create recipe"
        }
    }
    
    func updateRecipe(_ recipe: Recipe, in source: Source, removeImage: Bool = false) async {
        do {
            let database = isSharedOwner(source) || source.isPersonal ? privateDatabase : sharedDatabase
            
            // Fetch the existing record first to properly update it
            let existingRecord = try await database.record(for: recipe.id)
            
            // Update the fields from the recipe
            existingRecord["name"] = recipe.name
            existingRecord["recipeTime"] = recipe.recipeTime
            existingRecord["details"] = recipe.details
            existingRecord["sourceID"] = CKRecord.Reference(recordID: recipe.sourceID, action: .deleteSelf)
            existingRecord["categoryID"] = CKRecord.Reference(recordID: recipe.categoryID, action: .none)
            existingRecord["tagIDs"] = recipe.tagIDs.map(\.recordName)
            existingRecord["linkedRecipeIDs"] = recipe.linkedRecipeIDs.map(\.recordName)
            existingRecord["lastModified"] = recipe.lastModified
            
            if removeImage {
                existingRecord["imageAsset"] = nil
                removeCachedImage(for: recipe.id)
            } else if let imageAsset = recipe.imageAsset {
                if let imageURL = imageAsset.fileURL,
                   FileManager.default.fileExists(atPath: imageURL.path) {
                    existingRecord["imageAsset"] = imageAsset
                } else {
                    printD("Skipping recipe imageAsset update; local file is unavailable.")
                }
            }
            
            // Handle recipe steps
            do {
                let stepsData = try JSONEncoder().encode(recipe.recipeSteps)
                if let stepsJSON = String(data: stepsData, encoding: .utf8) {
                    existingRecord["recipeSteps"] = stepsJSON
                }
            } catch {
                printD("Error encoding recipe steps: \(error.localizedDescription)")
            }
            
            // Save the updated record
            let savedRecord = try await database.save(existingRecord)
            
            if let savedRecipe = Recipe.from(savedRecord) {
                let recipeWithImage = recipeWithCachedImage(savedRecipe)
                recipeCache[recipeWithImage.id] = recipeWithImage
                printD("Recipe updated: \(recipeWithImage.name)")
            }
            await loadRecipeCounts(for: source)
        } catch {
            printD("Error updating recipe: \(error.localizedDescription)")
            self.error = "Failed to update recipe"
        }
    }
    
    func deleteRecipe(_ recipe: Recipe, in source: Source) async -> Bool {
        do {
            let database = source.isPersonal ? privateDatabase : sharedDatabase
            try await database.deleteRecord(withID: recipe.id)
            recipeCache.removeValue(forKey: recipe.id)
            removeCachedImage(for: recipe.id)
            printD("Recipe deleted: \(recipe.name)")
            await loadRecipeCounts(for: source)
            return true
        } catch {
            printD("Error deleting recipe: \(error.localizedDescription)")
            self.error = "Failed to delete recipe"
            return false
        }
    }
    
    // MARK: - Image Handling
    func saveImage(_ imageData: Data, for recipe: Recipe) async -> ImageSaveResult? {
        do {
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
            try imageData.write(to: tempURL)
            
            let asset = CKAsset(fileURL: tempURL)
            printD("Image asset created: \(tempURL)")
            let token = versionToken(for: recipe.lastModified)
            let cachedPath = cacheImageData(imageData, for: recipe.id, versionToken: token)
            return ImageSaveResult(asset: asset, cachedPath: cachedPath, tempURL: tempURL)
        } catch {
            printD("Error saving image: \(error.localizedDescription)")
            self.error = "Failed to save image"
            return nil
        }
    }
    
    // MARK: - Sharing
    
#if os(macOS)
    /// Get or create a share URL for a source
    /// - Parameter source: The source to share (must be personal)
    /// - Returns: The share URL, or nil on error
    func getShareURL(for source: Source) async -> URL? {
        guard source.isPersonal else {
            self.error = "Cannot share sources that are already shared"
            printD("Error: Cannot share non-personal source")
            return nil
        }
        
        do {
            // Fetch the source record from the PRIVATE database
            let rootRecord = try await privateDatabase.record(for: source.id)
            printD("Fetched source record from private database: \(rootRecord.recordID.recordName)")
            
            if rootRecord.recordID.zoneID == CKRecordZone.default().zoneID {
                printD("Cannot share record in default zone")
                self.error = "Sharing requires the source to be stored in the iCook zone. Please recreate this source to share it."
                return nil
            }
            
            // Check if already shared
            if let existingShare = rootRecord.share {
                printD("Record is already shared, fetching existing share...")
                let shareRecordID = existingShare.recordID
                
                do {
                    let share = try await privateDatabase.record(for: shareRecordID) as? CKShare
                    if let share, let url = share.url {
                        printD("Using existing share URL: \(url.absoluteString)")
                        await resolveParticipantIdentities(in: share)
                        await attachChildRecordsToShare(share, rootRecord: rootRecord)
                        return url
                    }
                } catch {
                    printD("Error fetching existing share: \(error.localizedDescription)")
                }
            }
            
            // Create new share if not already shared
            printD("Record not yet shared, creating share...")
            let share = CKShare(rootRecord: rootRecord)
            share[CKShare.SystemFieldKey.title] = source.name as CKRecordValue
            share.publicPermission = .none  // Private invites only
            if let iconData = appIconThumbnailData() {
                share[CKShare.SystemFieldKey.thumbnailImageData] = iconData as CKRecordValue
            }
            
            printD("Share instance created with ID: \(share.recordID.recordName)")
            
            // Save the share and root record together
            printD("Saving share and root record together...")
            let (saveResults, _) = try await privateDatabase.modifyRecords(
                saving: [share, rootRecord],
                deleting: []
            )
            
            // Find the saved share's ID by extracting successful results
            let savedRecords = saveResults.compactMap { _, result -> CKShare? in
                if case .success(let record) = result,
                   let shareRecord = record as? CKShare {
                    return shareRecord
                }
                return nil
            }
            
            if let savedShare = savedRecords.first {
                printD("Share saved successfully with ID: \(savedShare.recordID.recordName)")
                
                // CloudKit needs a moment to generate the URL after saving
                // Fetch the share again to get the populated URL
                printD("Fetching share to get URL...")
                do {
                    if let fetchedShare = try await privateDatabase.record(for: savedShare.recordID) as? CKShare,
                       let url = fetchedShare.url {
                        printD("Share URL obtained: \(url.absoluteString)")
                        markSharedSource(id: rootRecord.recordID)
                        saveSourcesLocalCache()
                        await resolveParticipantIdentities(in: fetchedShare)
                        await attachChildRecordsToShare(fetchedShare, rootRecord: rootRecord)
                        return url
                    } else {
                        printD("Warning: Fetched share doesn't have URL yet")
                        // Try one more time after a brief delay
                        try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                        if let retryShare = try await privateDatabase.record(for: savedShare.recordID) as? CKShare,
                           let url = retryShare.url {
                            printD("Share URL obtained on retry: \(url.absoluteString)")
                            markSharedSource(id: rootRecord.recordID)
                            saveSourcesLocalCache()
                            await resolveParticipantIdentities(in: retryShare)
                            await attachChildRecordsToShare(retryShare, rootRecord: rootRecord)
                            return url
                        }
                        return nil
                    }
                } catch {
                    printD("Error fetching share for URL: \(error.localizedDescription)")
                    return nil
                }
            } else {
                printD("Error: Share not found in saved records")
                return nil
            }
            
        } catch {
            printD("Error getting share URL: \(error.localizedDescription)")
            if let ckError = error as? CKError {
                printD("CKError code: \(ckError.code)")
                printD("CKError: \(ckError.localizedDescription)")
            }
            self.error = "Failed to get share URL: \(error.localizedDescription)"
            return nil
        }
    }
#endif
#if os(iOS) || os(macOS)
    func preparedShareForActivitySheet(sourceID: CKRecord.ID, sourceName: String) async throws -> CKShare {
        let rootRecord = try await privateDatabase.record(for: sourceID)
        
        if rootRecord.recordID.zoneID == CKRecordZone.default().zoneID {
            throw NSError(
                domain: "iCook.CloudKit",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Sharing requires the source to be stored in the iCook zone. Please recreate this source to share it."]
            )
        }
        
        if let existingShareRef = rootRecord.share,
           let existingShare = try await privateDatabase.record(for: existingShareRef.recordID) as? CKShare {
            await resolveParticipantIdentities(in: existingShare)
            await attachChildRecordsToShare(existingShare, rootRecord: rootRecord)
            markSharedSource(id: rootRecord.recordID)
            saveSourcesLocalCache()
            return existingShare
        }
        
        let share = CKShare(rootRecord: rootRecord)
        share[CKShare.SystemFieldKey.title] = sourceName as CKRecordValue
        share.publicPermission = .none
        if let iconData = appIconThumbnailData() {
            share[CKShare.SystemFieldKey.thumbnailImageData] = iconData as CKRecordValue
        }
        
        let savedShare = try await saveShare(for: rootRecord, share: share)
        await attachChildRecordsToShare(savedShare, rootRecord: rootRecord)
        await resolveParticipantIdentities(in: savedShare)
        markSharedSource(id: rootRecord.recordID)
        saveSourcesLocalCache()
        return savedShare
    }
#endif

#if os(iOS)
    private func ownerIdentityLooksRedacted(_ share: CKShare) -> Bool {
        let ownerIdentity = share.owner.userIdentity
        let displayName = ownerIdentity.nameComponents?.formatted() ?? ""
        let ownerRecord = ownerIdentity.userRecordID?.recordName ?? ""
        return displayName.isEmpty && ownerRecord == "__defaultOwner__"
    }

    private func refreshedShareForDisplay(_ share: CKShare, in database: CKDatabase) async -> CKShare {
        var latest = share
        guard ownerIdentityLooksRedacted(latest) else { return latest }
        for attempt in 1...2 {
            if attempt > 1 {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            do {
                if let fetched = try await database.record(for: latest.recordID) as? CKShare {
                    latest = fetched
                    if !ownerIdentityLooksRedacted(latest) {
                        break
                    }
                }
            } catch {
                break
            }
        }
        return latest
    }

    /// Prepare a UICloudSharingController for sharing a source
    /// Creates/saves (or fetches existing) share first, then presents
    /// UICloudSharingController with a concrete CKShare instance.
    /// - Parameters:
    ///   - source: The source to share (must be personal)
    ///   - completionHandler: Called with the controller when ready, or nil on error
    func prepareSharingController(for source: Source, completionHandler: @escaping (UICloudSharingController?) -> Void) {
        guard source.isPersonal else {
            self.error = "Cannot share sources that are already shared"
            printD("Error: Cannot share non-personal source")
            completionHandler(nil)
            return
        }

        Task {
            do {
                let rootRecord = try await privateDatabase.record(for: source.id)
                printD("Preparing share for source record: \(rootRecord.recordID.recordName)")
                
                if rootRecord.recordID.zoneID == CKRecordZone.default().zoneID {
                    await MainActor.run {
                        self.error = "Sharing requires the source to be stored in the iCook zone. Please recreate this source to share it."
                        completionHandler(nil)
                    }
                    return
                }
                
                let shareToPresent: CKShare
                if let existingShareRef = rootRecord.share,
                   let existingShare = try await privateDatabase.record(for: existingShareRef.recordID) as? CKShare {
                    printD("Using existing share: \(existingShare.recordID.recordName)")
                    shareToPresent = existingShare
                } else {
                    let share = CKShare(rootRecord: rootRecord)
                    share[CKShare.SystemFieldKey.title] = source.name as CKRecordValue
                    share.publicPermission = .none
                    if let iconData = appIconThumbnailData() {
                        share[CKShare.SystemFieldKey.thumbnailImageData] = iconData as CKRecordValue
                    }
                    
                    let savedShare = try await saveShare(for: rootRecord, share: share)
                    printD("Created new share: \(savedShare.recordID.recordName)")
                    await attachChildRecordsToShare(savedShare, rootRecord: rootRecord)
                    shareToPresent = savedShare
                }
                
                await resolveParticipantIdentities(in: shareToPresent)
                let displayShare = await refreshedShareForDisplay(shareToPresent, in: privateDatabase)
                let controller = UICloudSharingController(share: displayShare, container: self.container)
                controller.availablePermissions = [.allowReadOnly, .allowReadWrite, .allowPrivate]
                
                await MainActor.run {
                    completionHandler(controller)
                }
            } catch {
                printD("Error preparing sharing controller: \(error.localizedDescription)")
                await MainActor.run {
                    self.error = "Failed to prepare share: \(error.localizedDescription)"
                    completionHandler(nil)
                }
            }
        }
    }
    
    /// Return a UICloudSharingController for an existing shared source (owner only)
    func existingSharingController(for source: Source) async -> UICloudSharingController? {
        guard isSharedOwner(source) else { return nil }
        
        do {
            let rootRecord = try await privateDatabase.record(for: source.id)
            guard let shareRef = rootRecord.share else { return nil }
            
            let shareRecord = try await privateDatabase.record(for: shareRef.recordID)
            guard let share = shareRecord as? CKShare else { return nil }
            
            await attachChildRecordsToShare(share, rootRecord: rootRecord)
            let displayShare = await refreshedShareForDisplay(share, in: privateDatabase)
            let controller = UICloudSharingController(share: displayShare, container: self.container)
            controller.availablePermissions = [.allowReadOnly, .allowReadWrite, .allowPrivate]
            return controller
        } catch {
            printD("existingSharingController error: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Return a UICloudSharingController for an existing shared source (participant)
    func participantSharingController(for source: Source) async -> UICloudSharingController? {
        guard isSharedSource(source) else { return nil }
        
        do {
            let rootRecord = try await sharedDatabase.record(for: source.id)
            guard let shareRef = rootRecord.share else {
                printD("participantSharingController: no share ref on root")
                return nil
            }
            let shareRecord = try await sharedDatabase.record(for: shareRef.recordID)
            guard let share = shareRecord as? CKShare else {
                printD("participantSharingController: share record not CKShare")
                return nil
            }
            await attachChildRecordsToShare(share, rootRecord: rootRecord)
            let controller = UICloudSharingController(share: share, container: self.container)
            controller.availablePermissions = [.allowReadOnly, .allowReadWrite]
            return controller
        } catch {
            printD("participantSharingController error: \(error.localizedDescription)")
            return nil
        }
    }
#endif
    
    private func ensurePersonalZoneExists() async {
        if hasEnsuredPersonalZone { return }
        if let inFlight = ensurePersonalZoneTask {
            await inFlight.value
            return
        }
        
        let task = Task { @MainActor in
            do {
                let database = privateDatabase
                let existingZones = try await withTimeout(seconds: cloudRequestTimeoutSeconds, operationName: "personal zone") {
                    try await database.allRecordZones()
                }
                if existingZones.contains(where: { $0.zoneID == personalZoneID }) {
                    hasEnsuredPersonalZone = true
                    printD("Personal zone already exists: \(personalZoneID.zoneName)")
                    return
                }
            } catch {
                printD("Failed to fetch record zones: \(error.localizedDescription)")
            }
            
            do {
                let database = privateDatabase
                let zone = personalZone
                _ = try await withTimeout(seconds: cloudRequestTimeoutSeconds, operationName: "personal zone") {
                    try await database.modifyRecordZones(saving: [zone], deleting: [])
                }
                hasEnsuredPersonalZone = true
                printD("Created personal zone: \(personalZoneID.zoneName)")
            } catch {
                printD("Failed to ensure personal zone: \(error.localizedDescription)")
                // A parallel create may have succeeded; verify before leaving.
                let database = privateDatabase
                let zones = try? await withTimeout(seconds: cloudRequestTimeoutSeconds, operationName: "personal zone") {
                    try await database.allRecordZones()
                }
                if let zones, zones.contains(where: { $0.zoneID == personalZoneID }) {
                    hasEnsuredPersonalZone = true
                    printD("Personal zone exists after retry check: \(personalZoneID.zoneName)")
                }
            }
        }
        
        ensurePersonalZoneTask = task
        await task.value
        ensurePersonalZoneTask = nil
    }
#if os(iOS) || os(macOS)
    /// Save a share to CloudKit after user confirms via UICloudSharingController
    func saveShare(for record: CKRecord, share: CKShare) async throws -> CKShare {
        try await withCheckedThrowingContinuation { continuation in
            var savedShare = share
            
            let operation = CKModifyRecordsOperation(recordsToSave: [share, record], recordIDsToDelete: nil)
            operation.savePolicy = .ifServerRecordUnchanged
            operation.perRecordSaveBlock = { recordID, result in
                switch result {
                case .success(let savedRecord):
                    printD("Saved record during modify: \(savedRecord.recordType) - \(savedRecord.recordID.recordName)")
                    if let shareRecord = savedRecord as? CKShare {
                        savedShare = shareRecord
                    }
                case .failure(let error):
                    printD("Error saving record \(recordID.recordName) during modify: \(error.localizedDescription)")
                }
            }
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    printD("Share and root record saved successfully")
                    continuation.resume(returning: savedShare)
                case .failure(let error):
                    if let ckError = error as? CKError,
                       let serverShare = ckError.serverRecord as? CKShare {
                        printD("Received server version of share: \(serverShare.recordID.recordName)")
                        continuation.resume(returning: serverShare)
                    } else {
                        continuation.resume(throwing: error)
                    }
                }
            }
            
            self.privateDatabase.add(operation)
        }
    }
#endif
    
    /// Accept a CloudKit share link directly (useful for debug flows where the system does not handle it)
    /// - Returns: `true` on success, `false` otherwise and sets `error`
    func acceptShare(from url: URL) async -> Bool {
        printD("Attempting to accept share from URL: \(url.absoluteString)")
        do {
            let metadata = try await fetchShareMetadata(for: url)
            return await acceptShare(metadata: metadata)
        } catch {
            let message = error.localizedDescription
            printD("Failed to accept share: \(message)")
            await MainActor.run {
                self.error = "Failed to accept share: \(message)"
            }
            return false
        }
    }
    
    /// Accept a CloudKit share via metadata (used by system share handoff)
    func acceptShare(metadata: CKShare.Metadata) async -> Bool {
        do {
            try await acceptShare(with: metadata)
            let sharedSource = await fetchSharedSource(using: metadata)
            await loadSources()
            
            // Fallback: if shared sources didn't appear via loadSources, inject the fetched one
            if let sharedSource, !sources.contains(where: { $0.id == sharedSource.id }) {
                sources.append(sharedSource)
                sources.sort { $0.lastModified > $1.lastModified }
                saveSourcesLocalCache()
                printD("Injected shared source manually after accept: \(sharedSource.name)")
                recentlyUnsharedIDs.remove(cacheIdentifier(for: sharedSource.id))
                saveSharedSourceIDs()
            }
            if let sharedSource {
                currentSource = sharedSource
                saveCurrentSourceID()
                markSharedSource(id: sharedSource.id)
            }
            updateSharedEditabilityFlag()
            
            printD("Share accepted successfully via metadata flow")
            return true
        } catch {
            let message = error.localizedDescription
            printD("Failed to accept share via metadata: \(message)")
            await MainActor.run {
                self.error = "Failed to accept share: \(message)"
            }
            return false
        }
    }
    
    private func attachChildRecordsToShare(_ share: CKShare, rootRecord: CKRecord) async {
        do {
            _ = share // share object kept for clarity; parent links share the hierarchy
            var recordsToSave: [CKRecord] = []
            
            // Fetch categories in the personal zone for this source
            let catPredicate = NSPredicate(format: "sourceID == %@", CKRecord.Reference(recordID: rootRecord.recordID, action: .none))
            let catQuery = CKQuery(recordType: "Category", predicate: catPredicate)
            let catResults = try await fetchAllQueryMatchResults(matching: catQuery, in: privateDatabase, zoneID: personalZoneID)
            for (_, result) in catResults {
                if case .success(let record) = result, record.parent == nil {
                    record.parent = CKRecord.Reference(recordID: rootRecord.recordID, action: .none)
                    recordsToSave.append(record)
                }
            }
            
            // Fetch recipes in the personal zone for this source
            let recipePredicate = NSPredicate(format: "sourceID == %@", CKRecord.Reference(recordID: rootRecord.recordID, action: .none))
            let recipeQuery = CKQuery(recordType: "Recipe", predicate: recipePredicate)
            let recipeResults = try await fetchAllQueryMatchResults(matching: recipeQuery, in: privateDatabase, zoneID: personalZoneID)
            for (_, result) in recipeResults {
                if case .success(let record) = result, record.parent == nil {
                    record.parent = CKRecord.Reference(recordID: rootRecord.recordID, action: .none)
                    recordsToSave.append(record)
                }
            }

            // Fetch tags in the personal zone for this source
            let tagPredicate = NSPredicate(format: "sourceID == %@", CKRecord.Reference(recordID: rootRecord.recordID, action: .none))
            let tagQuery = CKQuery(recordType: "Tag", predicate: tagPredicate)
            let tagResults = try await fetchAllQueryMatchResults(matching: tagQuery, in: privateDatabase, zoneID: personalZoneID)
            for (_, result) in tagResults {
                if case .success(let record) = result, record.parent == nil {
                    record.parent = CKRecord.Reference(recordID: rootRecord.recordID, action: .none)
                    recordsToSave.append(record)
                }
            }
            
            guard !recordsToSave.isEmpty else {
                printD("No child records needed attaching to share")
                return
            }
            
            try await saveSharedChildren(recordsToSave, in: privateDatabase)
            printD("Attached \(recordsToSave.count) child records to share")
        } catch {
            printD("Failed to attach child records to share: \(error.localizedDescription)")
        }
    }
    
    private func saveSharedChildren(_ records: [CKRecord], in database: CKDatabase) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
            operation.savePolicy = .ifServerRecordUnchanged
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }
    
    private func refreshSharedSourceEditability(for sources: [Source]) async {
        var nextEditability: [CKRecord.ID: Bool] = [:]

        for source in sources {
            if source.isPersonal || isSharedOwner(source) {
                nextEditability[source.id] = true
                continue
            }

            nextEditability[source.id] = await fetchSharedSourceWriteAccess(for: source)
        }

        sharedSourceEditability = nextEditability
    }

    private func fetchSharedSourceWriteAccess(for source: Source) async -> Bool {
        do {
            let rootRecord = try await sharedDatabase.record(for: source.id)
            guard let shareRef = rootRecord.share,
                  let share = try await sharedDatabase.record(for: shareRef.recordID) as? CKShare,
                  let currentParticipant = share.currentUserParticipant else {
                return false
            }

            return currentParticipant.permission == .readWrite
        } catch {
            printD("Failed to resolve shared editability for \(source.name): \(error.localizedDescription)")
            return false
        }
    }

    private func updateSharedEditabilityFlag() {
        let currentSourceIDs = Set(sources.map(\.id))
        sharedSourceEditability = sharedSourceEditability.filter { currentSourceIDs.contains($0.key) }
        canEditSharedSources = sources.contains { canEditSharedSource($0) && !$0.isPersonal }
    }
    
    private func fetchShareMetadata(for url: URL) async throws -> CKShare.Metadata {
        try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            let operation = CKFetchShareMetadataOperation(shareURLs: [url])
            
            operation.perShareMetadataResultBlock = { _, result in
                switch result {
                case .success(let metadata):
                    if !resumed {
                        resumed = true
                        continuation.resume(returning: metadata)
                    }
                case .failure(let error):
                    if !resumed {
                        resumed = true
                        continuation.resume(throwing: error)
                    }
                }
            }
            
            operation.fetchShareMetadataResultBlock = { result in
                if case .failure(let error) = result, !resumed {
                    resumed = true
                    continuation.resume(throwing: error)
                }
            }
            
            self.container.add(operation)
        }
    }
    
    private func acceptShare(with metadata: CKShare.Metadata) async throws {
        try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            let operation = CKAcceptSharesOperation(shareMetadatas: [metadata])
            
            operation.perShareResultBlock = { _, result in
                switch result {
                case .success:
                    if !resumed {
                        resumed = true
                        continuation.resume()
                    }
                case .failure(let error):
                    if !resumed {
                        resumed = true
                        continuation.resume(throwing: error)
                    }
                }
            }
            
            operation.acceptSharesResultBlock = { result in
                if case .failure(let error) = result, !resumed {
                    resumed = true
                    continuation.resume(throwing: error)
                }
            }
            
            self.container.add(operation)
        }
    }
    
    private func fetchSharedSource(using metadata: CKShare.Metadata) async -> Source? {
        do {
            // rootRecordID is deprecated but still necessary on some shares; use KVC to avoid warnings
            let rootRecordID = metadata.rootRecord?.recordID
            ?? (metadata.value(forKey: "rootRecordID") as? CKRecord.ID)
            
            guard let rootRecordID else {
                printD("Share metadata missing rootRecord; cannot fetch shared source")
                return nil
            }
            let record = try await sharedDatabase.record(for: rootRecordID)
            if var source = Source.from(record) {
                // Ensure shared sources are marked correctly
                source.isPersonal = false
                // If the owner is missing or incorrect, stamp from share metadata
                if source.owner.isEmpty {
                    let ownerName = metadata.ownerIdentity.lookupInfo?.emailAddress
                    ?? metadata.ownerIdentity.nameComponents?.formatted()
                    ?? "Shared"
                    source.owner = ownerName
                }
                printD("Fetched shared source after accept: \(source.name)")
                return source
            } else {
                printD("Fetched root record but could not decode Source")
                return nil
            }
        } catch {
            printD("Could not fetch shared source after accept: \(error.localizedDescription)")
            return nil
        }
    }
    
#if os(macOS)
    /// Generate a new CKRecord.ID for the appropriate zone based on the source.
#endif
    func makeRecordID(for source: Source) -> CKRecord.ID {
        let owner = isSharedOwner(source)
        let shared = isSharedSource(source)
        let zone: CKRecordZone.ID = owner || !shared ? personalZoneID : source.id.zoneID
        return CKRecord.ID(recordName: UUID().uuidString, zoneID: zone)
    }
    
}

#if os(macOS)
private extension NSImage {
    func pngDataUsingTIFF() -> Data? {
        guard let tiffData = self.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
#endif

// MARK: - Helper Functions
func printD(_ message: String) {
#if DEBUG
    print("[CloudKit] \(message)")
#endif
}
