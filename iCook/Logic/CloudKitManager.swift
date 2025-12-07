import Foundation
import Combine
import CloudKit
import ObjectiveC
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct ImageSaveResult {
    let asset: CKAsset
    let cachedPath: String?
}

@MainActor
class CloudKitManager: ObservableObject {
    static let shared = CloudKitManager()
    
    // MARK: - Published Properties
    @Published var currentSource: Source?
    @Published var sources: [Source] = []
    @Published var categories: [Category] = []
    @Published var recipes: [Recipe] = []
    @Published var recipeCounts: [CKRecord.ID: Int] = [:]
    @Published var isLoading = false
    @Published var error: String?
    @Published var isCloudKitAvailable = true // Assume available until proven otherwise
    @Published var isOfflineMode = false
    @Published var canEditSharedSources = false
    
    // MARK: - Private Properties
    let container: CKContainer
    private var privateDatabase: CKDatabase { container.privateCloudDatabase }
    private var sharedDatabase: CKDatabase { container.sharedCloudDatabase }
    private var userIdentifier: String? = UserDefaults.standard.string(forKey: "iCloudUserID")
    private let personalZoneID = CKRecordZone.ID(zoneName: "PersonalSources", ownerName: CKCurrentUserDefaultName)
    private lazy var personalZone: CKRecordZone = CKRecordZone(zoneID: personalZoneID)
    
    // Caches
    private var sourceCache: [CKRecord.ID: Source] = [:]
    private var categoryCache: [CKRecord.ID: Category] = [:]
    private var recipeCache: [CKRecord.ID: Recipe] = [:]
    private enum CacheFileType: String {
        case categories
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
    
    init() {
        self.container = CKContainer(identifier: "iCloud.com.georgebabichev.iCook")
        loadSharedSourceIDs()
        // Load from local cache immediately
        loadSourcesLocalCache()
        Task {
            await ensurePersonalZoneExists()
            await setupiCloudUser()
            await loadSources()
        }
    }
    
    // MARK: - Setup
    private func setupiCloudUser() async {
        do {
            let userRecord = try await container.userRecordID()
            userIdentifier = userRecord.recordName
            UserDefaults.standard.set(userRecord.recordName, forKey: "iCloudUserID")
            isCloudKitAvailable = true
            printD("iCloud user authenticated successfully")
        } catch {
            let errorDesc = error.localizedDescription
            printD("Error setting up iCloud user: \(errorDesc)")
            
            // Check if this is an auth error (not signed in)
            if errorDesc.contains("authenticated account") ||
                errorDesc.contains("iCloud account") ||
                errorDesc.contains("No iCloud") {
                isCloudKitAvailable = false
                printD("CloudKit unavailable: User not signed into iCloud. Using local-only mode.")
                self.error = "iCloud not available. Using local storage only."
            } else {
                self.error = "Failed to connect to iCloud"
            }
        }
    }
    
    private func ensureUserIdentifier() async {
        if let userIdentifier, !userIdentifier.isEmpty { return }
        do {
            let userRecord = try await container.userRecordID()
            userIdentifier = userRecord.recordName
            UserDefaults.standard.set(userRecord.recordName, forKey: "iCloudUserID")
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
    
#if os(iOS)
    /// Remove local shared markers for a source (used when an owner stops sharing).
    func markSourceUnshared(_ source: Source) {
        let key = cacheIdentifier(for: source.id)
        printD("Marking source as unshared: \(source.name) (key=\(key)) before=\(sharedSourceIDs.count)")
        sharedSourceIDs.remove(key)
        if isSharedOwner(source) {
            recentlyUnsharedIDs.remove(key)
        } else {
            recentlyUnsharedIDs.insert(key)
        }
        saveSharedSourceIDs()
        printD("After unmark: sharedSourceIDs count=\(sharedSourceIDs.count)")
        
        // Flip local source objects to personal so UI/state stay consistent
        sources = sources.map { src in
            if src.id == source.id {
                var updated = src
                updated.isPersonal = true
                return updated
            }
            return src
        }
        sourceCache[source.id]?.isPersonal = true
        if let current = currentSource, current.id == source.id {
            currentSource?.isPersonal = true
        }
        saveSourcesLocalCache()
        saveCurrentSourceID()
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
    
#endif
    
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
                return decoded.map { recipeWithCachedImage($0) }
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
                return filtered.map { recipeWithCachedImage($0) }
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
        if isOfflineMode {
            isOfflineMode = false
        }
    }
    
    private func isNetworkRelatedError(_ error: Error) -> Bool {
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
    
    private func handleOfflineFallback(for error: Error) -> Bool {
        if isNetworkRelatedError(error) {
            isOfflineMode = true
            printD("Network unavailable, falling back to cache: \(error.localizedDescription)")
            return true
        }
        return false
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
                printD("Image cache write (data) OK for \(recipeID.recordName) -> \(destination.lastPathComponent) (\(size.intValue) bytes)")
                return destination.path
            } else {
                try? FileManager.default.removeItem(at: destination)
                printD("Image cache write (data) empty for \(recipeID.recordName)")
                return cachedImagePath(for: recipeID)
            }
        } catch {
            printD("Error caching image data: \(error.localizedDescription)")
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
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            // Validate non-empty file; otherwise keep existing
            let attrs = try FileManager.default.attributesOfItem(atPath: destination.path)
            if let size = attrs[.size] as? NSNumber, size.intValue > 0 {
                printD("Image cache write OK for \(recipeID.recordName) -> \(destination.lastPathComponent) (\(size.intValue) bytes)")
                return destination.path
            } else {
                try? FileManager.default.removeItem(at: destination)
                printD("Image cache write empty for \(recipeID.recordName); keeping existing")
                return existingPath ?? cachedImagePath(for: recipeID)
            }
        } catch {
            printD("Error caching image asset: \(error.localizedDescription)")
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

    /// Public helper to clear all cached image files for a recipe.
    func purgeCachedImages(for recipeID: CKRecord.ID) {
        removeCachedImages(for: recipeID)
    }

    /// Public helper to cache recipes for a specific scope (all or per-category).
    func cacheRecipes(_ recipes: [Recipe], for source: Source, categoryID: CKRecord.ID?) {
        saveRecipesLocalCache(recipes, for: source, categoryID: categoryID)
    }
    
    private func removeCachedImage(for recipeID: CKRecord.ID) {
        removeCachedImages(for: recipeID)
    }
    
    private func recipeWithCachedImage(_ recipe: Recipe) -> Recipe {
        var updatedRecipe = recipe
        let fm = FileManager.default
        let token = versionToken(for: recipe.lastModified)
        
        // If we already have a cached image path, ensure it matches the current version token; otherwise purge it.
        if let current = recipe.cachedImagePath,
           fm.fileExists(atPath: current) {
            if current.contains("_\(token).asset") {
                printD("Image cache reuse current for \(recipe.id.recordName): \(current)")
                updatedRecipe.cachedImagePath = current
                return updatedRecipe
            } else {
                printD("Image cache outdated for \(recipe.id.recordName); purging cached images")
                removeCachedImages(for: recipe.id)
            }
        }
        
        // Cache from CloudKit asset if available
        if let asset = recipe.imageAsset,
           let localPath = cacheImageAsset(asset, for: recipe.id, versionToken: token, existingPath: nil) {
            printD("Image cache wrote versioned for \(recipe.id.recordName): \(localPath)")
            updatedRecipe.cachedImagePath = localPath
        } else if let cachedPath = cachedImagePath(for: recipe.id, versionToken: token),
                  fm.fileExists(atPath: cachedPath) {
            printD("Image cache found versioned for \(recipe.id.recordName): \(cachedPath)")
            updatedRecipe.cachedImagePath = cachedPath
        } else {
            printD("Image cache missing for \(recipe.id.recordName)")
            updatedRecipe.cachedImagePath = nil
        }
        return updatedRecipe
    }
    
    // MARK: - Source Management
    func loadSources() async {
        isLoading = true
        
        // Keep any locally cached shared sources so we don't drop them if SharedDB queries fail
        let cachedSharedSources = sources.filter { !$0.isPersonal }
        
        // If CloudKit is not available, use local cache only
        guard isCloudKitAvailable else {
            printD("CloudKit not available, using cached sources only")
            return
        }
        
        do {
            // Begin collecting shared keys for this load pass
            isCollectingSharedKeys = true
            collectedSharedKeys.removeAll()
            
            // Load personal sources from private database
            let personalSources = try await fetchSourcesFromDatabase(privateDatabase, isPersonal: true)
            
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
            // If none returned (due to limitations), try via CKShare metadata
            if sharedSources.isEmpty {
                let zoneSources = await fetchSharedSourcesViaZones()
                sharedSources.append(contentsOf: zoneSources)
                if sharedSources.isEmpty {
                    let shareSources = await fetchSharedSourcesViaShares()
                    sharedSources.append(contentsOf: shareSources)
                }
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
        isLoading = false
        isCollectingSharedKeys = false
    }
    
    private func fetchSourcesFromDatabase(_ database: CKDatabase, isPersonal: Bool) async throws -> [Source] {
        // Use a queryable field (lastModified) instead of TRUEPREDICATE to avoid "recordName is not marked queryable" error
        // This predicate matches all records where lastModified is after the distant past (i.e., all records)
        let predicate = NSPredicate(format: "lastModified >= %@", Date.distantPast as NSDate)
        let query = CKQuery(recordType: "Source", predicate: predicate)
        let zoneID: CKRecordZone.ID? = isPersonal ? personalZoneID : nil
        let (results, _) = try await database.records(matching: query, inZoneWith: zoneID)
        
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
    
    func createSource(name: String, isPersonal: Bool = true) async {
        await ensureUserIdentifier()
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
                }
            } catch {
                printD("Error creating source: \(error.localizedDescription)")
                if let ckError = error as? CKError {
                    printD("CKError code: \(ckError.errorCode)")
                    printD("CKError description: \(ckError.errorUserInfo)")
                }
                self.error = "Failed to create source"
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
        }
    }
    
    func deleteSource(_ source: Source) async {
        do {
            let database = source.isPersonal ? privateDatabase : sharedDatabase
            try await database.deleteRecord(withID: source.id)
            sourceCache.removeValue(forKey: source.id)
            // Remove from local array - reassign to ensure SwiftUI detects change
            self.sources = sources.filter { $0.id != source.id }
            if currentSource?.id == source.id {
                currentSource = self.sources.first
            }
            saveSourcesLocalCache()
        } catch {
            printD("Error deleting source: \(error.localizedDescription)")
            self.error = "Failed to delete source"
        }
    }
    
    func updateSource(_ source: Source, newName: String) async {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
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
        printD("Shared check key: \(key); cached IDs count: \(sharedSourceIDs.count); recentlyUnshared count: \(recentlyUnsharedIDs.count)")
        if recentlyUnsharedIDs.contains(key) {
            printD("Shared check: \(source.name) explicitly unshared recently; treating as personal")
            // defensive: scrub any lingering shared flag
            sharedSourceIDs.remove(key)
            saveSharedSourceIDs()
            return false
        }
        if sharedSourceIDs.contains(key) {
            printD("Shared check: \(source.name) is marked shared via local cache")
            return true
        }
        // Treat anything outside the personal zone or marked non-personal as shared
        if !source.isPersonal {
            printD("Shared check: \(source.name) is marked non-personal")
            return true
        }
        let zoneID = source.id.zoneID
        if shouldBeSharedBasedOnZone(source) {
            printD("Shared check: \(source.name) has shared-like zone (\(zoneID.zoneName), owner: \(zoneID.ownerName)) vs personal (\(personalZoneID.zoneName), owner: \(CKCurrentUserDefaultName))")
            return true
        }
        if let userIdentifier, !userIdentifier.isEmpty, source.owner != userIdentifier {
            printD("Shared check: \(source.name) owner mismatch (record: \(source.owner), current: \(userIdentifier))")
            return true
        }
        let currentUserDesc = userIdentifier ?? "nil"
        printD("Shared check details: name=\(source.name), isPersonal flag=\(source.isPersonal), zoneName=\(zoneID.zoneName), zoneOwner=\(zoneID.ownerName), recordedOwner=\(source.owner), currentUser=\(currentUserDesc)")
        printD("Shared check: \(source.name) treated as personal")
        return false
    }
    
    func isSharedOwner(_ source: Source) -> Bool {
        guard let userIdentifier else { return false }
        let ownsByRecord = source.owner == userIdentifier
        let ownsByZone = source.id.zoneID.ownerName == CKCurrentUserDefaultName
        let result = ownsByRecord || ownsByZone
        printD("Shared owner check for \(source.name): ownsByRecord=\(ownsByRecord), ownsByZone=\(ownsByZone)")
        return result
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
        if currentSource?.id == source.id {
            currentSource = sources.first
            saveCurrentSourceID()
        }
        printD("Removed shared source locally: \(source.name)")
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
    /// Debug helper: completely nuke owned data (personal zone) and local caches.
    func debugNukeOwnedData() async {
        isLoading = true
        defer { isLoading = false }
        
        printD("Debug: Nuke owned data - deleting personal zone and caches")
        
        // Attempt to delete the personal zone
        do {
            try await privateDatabase.deleteRecordZone(withID: personalZoneID)
            printD("Deleted personal zone \(personalZoneID.zoneName)")
        } catch {
            printD("Debug: delete zone error (ignored if not found): \(error.localizedDescription)")
        }
        
        // Clear local caches and state
        sources.removeAll()
        categories.removeAll()
        recipes.removeAll()
        recipeCounts.removeAll()
        currentSource = nil
        sourceCache.removeAll()
        categoryCache.removeAll()
        recipeCache.removeAll()
        sharedSourceIDs.removeAll()
        recentlyUnsharedIDs.removeAll()
        saveSharedSourceIDs()
        saveCurrentSourceID()
        
        // Remove cache files on disk
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: cacheDirectoryURL.path) {
                try fm.removeItem(at: cacheDirectoryURL)
            }
        } catch {
            printD("Debug: Failed to clear cache directory: \(error.localizedDescription)")
        }
        
        // Recreate cache directories
        _ = cacheDirectoryURL
        _ = imageCacheDirectory
        
        // Do not recreate any default collections; user will add their own.
    }
    
    private func fetchSharedSourcesViaZones() async -> [Source] {
        var sharedSources: [Source] = []
        do {
            let zones = try await sharedDatabase.allRecordZones()
            for zone in zones {
                let predicate = NSPredicate(value: true)
                let query = CKQuery(recordType: "Source", predicate: predicate)
                do {
                    let (results, _) = try await sharedDatabase.records(matching: query, inZoneWith: zone.zoneID)
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
    
    private func fetchSharedSourcesViaShares() async -> [Source] {
        var sharedSources: [Source] = []
        let shares = await fetchAllShares()
        for share in shares {
            // Use KVC to access rootRecordID
            let rootID = share.value(forKey: "rootRecordID") as? CKRecord.ID
            guard let rootID else { continue }
            do {
                let record = try await sharedDatabase.record(for: rootID)
                if var source = Source.from(record) {
                    source.isPersonal = false
                    markSharedSource(id: source.id)
                    sharedSources.append(source)
                    printD("Fetched shared source via CKShare: \(source.name)")
                }
            } catch {
                printD("Failed to fetch shared source via share \(share.recordID.recordName): \(error.localizedDescription)")
            }
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
                let (results, _) = try await database.records(matching: query, inZoneWith: zoneID)
                let categories = results.compactMap { _, result -> Category? in
                    guard case .success(let record) = result,
                          let category = Category.from(record) else {
                        return nil
                    }
                    categoryCache[category.id] = category
                    return category
                }
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
            let (results, _) = try await database.records(matching: query, inZoneWith: zoneID)
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
                let (results, _) = try await database.records(matching: query, inZoneWith: zoneID)
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
    
    private func removeRecipeCache(for source: Source) {
        let fm = FileManager.default
        // Remove per-source recipe caches (all categories and per-category files)
        if let files = try? fm.contentsOfDirectory(at: cacheDirectoryURL, includingPropertiesForKeys: nil) {
            let prefix = "recipes_\(cacheIdentifier(for: source.id))"
            for url in files where url.lastPathComponent.hasPrefix(prefix) {
                try? fm.removeItem(at: url)
            }
        }
        // Clear in-memory caches
        recipeCache = recipeCache.filter { $0.key.zoneID != source.id.zoneID }
    }
    
    func loadRandomRecipes(for source: Source, skipCache: Bool = false) async {
        isLoading = true
        defer { isLoading = false }
        
        if skipCache {
            // Purge caches so we fetch fresh content/images, but keep current UI data visible.
            removeRecipeCache(for: source)
        } else if let cachedAllRecipes = loadRecipesLocalCache(for: source, categoryID: nil),
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
                let (results, _) = try await database.records(matching: query, inZoneWith: zoneID)
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
    
    func updateRecipe(_ recipe: Recipe, in source: Source) async {
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
            existingRecord["lastModified"] = recipe.lastModified
            
            // Handle image asset
            if let imageAsset = recipe.imageAsset {
                existingRecord["imageAsset"] = imageAsset
            } else {
                existingRecord["imageAsset"] = nil
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
    
    func deleteRecipe(_ recipe: Recipe, in source: Source) async {
        do {
            let database = source.isPersonal ? privateDatabase : sharedDatabase
            try await database.deleteRecord(withID: recipe.id)
            recipeCache.removeValue(forKey: recipe.id)
            removeCachedImage(for: recipe.id)
            printD("Recipe deleted: \(recipe.name)")
            await loadRecipeCounts(for: source)
        } catch {
            printD("Error deleting recipe: \(error.localizedDescription)")
            self.error = "Failed to delete recipe"
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
            return ImageSaveResult(asset: asset, cachedPath: cachedPath)
        } catch {
            printD("Error saving image: \(error.localizedDescription)")
            self.error = "Failed to save image"
            return nil
        }
    }
    
    // MARK: - Sharing
    
    /// Get or create a share URL for a source (cross-platform)
    /// - Parameter source: The source to share (must be personal)
    /// - Returns: The share URL, or nil on error
#if os(macOS)
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
            let shareID = CKRecord.ID(recordName: UUID().uuidString, zoneID: rootRecord.recordID.zoneID)
            let share = CKShare(rootRecord: rootRecord, shareID: shareID)
            share[CKShare.SystemFieldKey.title] = source.name as CKRecordValue
            share.publicPermission = .none  // Private invites only
            if let iconData = appIconThumbnailData() {
                share[CKShare.SystemFieldKey.thumbnailImageData] = iconData as CKRecordValue
            }
            
            printD("Share instance created with ID: \(shareID.recordName)")
            
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
#else
    /// Prepare a UICloudSharingController for sharing a source
    /// Creates and saves the share first, then creates the controller
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
                // Fetch the source record from the PRIVATE database
                let rootRecord = try await privateDatabase.record(for: source.id)
                printD("Fetched source record from private database: \(rootRecord.recordID.recordName)")
                printD("Root record type: \(rootRecord.recordType)")
                printD("Root record already has share: \(rootRecord.share != nil)")
                
                if rootRecord.recordID.zoneID == CKRecordZone.default().zoneID {
                    printD("Cannot share record in default zone. Prompting user to migrate.")
                    await MainActor.run {
                        self.error = "Sharing requires the source to be stored in the iCook zone. Please recreate this source to share it."
                        completionHandler(nil)
                    }
                    return
                }
                
                // Check if already shared
                if let existingShare = rootRecord.share {
                    printD("Record is already shared, fetching existing share...")
                    // Already shared, fetch and use existing share
                    let shareRecordID = existingShare.recordID
                    let fetchOp = CKFetchRecordsOperation(recordIDs: [shareRecordID])
                    
                    fetchOp.perRecordResultBlock = { recordID, result in
                        do {
                            let record = try result.get()
                            if let share = record as? CKShare {
                                Task {
                                    await self.resolveParticipantIdentities(in: share)
                                    await self.attachChildRecordsToShare(share, rootRecord: rootRecord)
                                }
                                DispatchQueue.main.async {
                                    let controller = UICloudSharingController(share: share, container: self.container)
                                    printD("UICloudSharingController created for existing share with URL: \(share.url?.absoluteString ?? "pending")")
                                    controller.availablePermissions = [.allowReadOnly, .allowReadWrite, .allowPrivate]
                                    completionHandler(controller)
                                }
                            }
                        } catch {
                            printD("Error fetching existing share: \(error.localizedDescription)")
                            completionHandler(nil)
                        }
                    }
                    privateDatabase.add(fetchOp)
                } else {
                    printD("Record not yet shared, creating and saving share before presenting controller...")
                    
                    // Create the share with a unique ID
                    // IMPORTANT: Use the same zone ID as the root record!
                    let shareID = CKRecord.ID(recordName: UUID().uuidString, zoneID: rootRecord.recordID.zoneID)
                    let share = CKShare(rootRecord: rootRecord, shareID: shareID)
                    share[CKShare.SystemFieldKey.title] = source.name as CKRecordValue
                    // Private-only sharing (invite specific people)
                    share.publicPermission = .none
                    if let iconData = appIconThumbnailData() {
                        share[CKShare.SystemFieldKey.thumbnailImageData] = iconData as CKRecordValue
                    }
                    
                    printD("Share instance created with ID: \(shareID.recordName)")
                    
                    do {
                        let savedShare = try await self.saveShare(for: rootRecord, share: share)
                        printD("Share saved successfully prior to presenting controller with ID: \(savedShare.recordID.recordName)")
                        await resolveParticipantIdentities(in: savedShare)
                        await attachChildRecordsToShare(savedShare, rootRecord: rootRecord)
                        
                        let controller = UICloudSharingController(share: savedShare, container: self.container)
                        printD("UICloudSharingController created with saved share")
                        controller.availablePermissions = [.allowReadOnly, .allowReadWrite, .allowPrivate]
                        
                        // Create a delegate that will copy the URL to pasteboard
                        let delegate = CloudKitShareDelegate()
                        controller.delegate = delegate
                        
                        // Store the delegate on the controller to keep it alive
                        objc_setAssociatedObject(controller, &CloudKitShareDelegate.associatedObjectKey, delegate, .OBJC_ASSOCIATION_RETAIN)
                        
                        printD("Delegate attached to controller")
                        
                        await MainActor.run {
                            completionHandler(controller)
                        }
                    } catch {
                        printD("Error saving share before presenting controller: \(error.localizedDescription)")
                        await MainActor.run {
                            self.error = "Failed to save share: \(error.localizedDescription)"
                            completionHandler(nil)
                        }
                    }
                }
            } catch {
                printD("Error preparing sharing controller: \(error.localizedDescription)")
                if let ckError = error as? CKError {
                    printD("CKError code: \(ckError.code)")
                    printD("CKError: \(ckError.localizedDescription)")
                }
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
            
            let controller = UICloudSharingController(share: share, container: self.container)
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
        do {
            let existingZones = try await privateDatabase.allRecordZones()
            if existingZones.contains(where: { $0.zoneID == personalZoneID }) {
                printD("Personal zone already exists: \(personalZoneID.zoneName)")
                return
            }
        } catch {
            printD("Failed to fetch record zones: \(error.localizedDescription)")
        }
        
        do {
            _ = try await privateDatabase.modifyRecordZones(saving: [personalZone], deleting: [])
            printD("Created personal zone: \(personalZoneID.zoneName)")
        } catch {
            printD("Failed to ensure personal zone: \(error.localizedDescription)")
        }
    }
#if os(iOS)
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
            
            printD("Share accepted successfully via manual flow")
            return true
        } catch {
            let message = error.localizedDescription
            printD("Failed to accept share: \(message)")
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
            let (catResults, _) = try await privateDatabase.records(matching: catQuery, inZoneWith: personalZoneID)
            for (_, result) in catResults {
                if case .success(let record) = result, record.parent == nil {
                    record.parent = CKRecord.Reference(recordID: rootRecord.recordID, action: .none)
                    recordsToSave.append(record)
                }
            }
            
            // Fetch recipes in the personal zone for this source
            let recipePredicate = NSPredicate(format: "sourceID == %@", CKRecord.Reference(recordID: rootRecord.recordID, action: .none))
            let recipeQuery = CKQuery(recordType: "Recipe", predicate: recipePredicate)
            let (recipeResults, _) = try await privateDatabase.records(matching: recipeQuery, inZoneWith: personalZoneID)
            for (_, result) in recipeResults {
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
    
    private func updateSharedEditabilityFlag() {
        // If we have any shared sources and sharing is enabled, allow editing of shared sources.
        // For now we assume shares are created as readWrite (enforced in sharing flows).
        canEditSharedSources = sources.contains { !$0.isPersonal }
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
    
    /// Fetch all shares created by or shared with this user
    func fetchAllShares() async -> [CKShare] {
        var allShares: [CKShare] = []
        
        do {
            // Query shared database for all shares
            let predicate = NSPredicate(value: true)
            let query = CKQuery(recordType: "cloudkit.share", predicate: predicate)
            
            let (results, _) = try await sharedDatabase.records(matching: query)
            
            allShares = results.compactMap { _, result in
                guard case .success(let record) = result,
                      let share = record as? CKShare else {
                    return nil
                }
                return share
            }
            
            printD("Fetched \(allShares.count) shares from shared database")
        } catch {
            printD("Error fetching shares: \(error.localizedDescription)")
        }
        
        return allShares
    }
    /// Stop sharing a source
    func stopSharingSource(_ source: Source) async -> Bool {
        // Only the owner can stop sharing; ensure we target the private DB share record
        guard isSharedOwner(source) else {
            self.error = "Only the owner can stop sharing"
            return false
        }
        
        do {
            // Fetch the source record from the private DB
            let rootRecord = try await privateDatabase.record(for: source.id)
            guard let shareRef = rootRecord.share else {
                printD("No share reference found; marking unshared locally")
                unmarkSharedSource(id: source.id)
                recentlyUnsharedIDs.insert(cacheIdentifier(for: source.id))
                saveSourcesLocalCache()
                return true
            }
            // Delete the share record in the private DB
            try await privateDatabase.deleteRecord(withID: shareRef.recordID)
            
            // Clear local markers
            unmarkSharedSource(id: source.id)
            recentlyUnsharedIDs.insert(cacheIdentifier(for: source.id))
            printD("Stopped sharing source: \(source.name)")
            return true
        } catch {
            printD("Error stopping share: \(error.localizedDescription)")
            self.error = "Failed to stop sharing"
            return false
        }
    }
    
    /// Generate a new CKRecord.ID for the appropriate zone based on the source.
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

// MARK: - Cloud Sharing Delegate
#if os(iOS)
/// Delegate for UICloudSharingController that handles share completion
class CloudKitShareDelegate: NSObject, UICloudSharingControllerDelegate {
    static var associatedObjectKey: UInt8 = 0
    
    func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
        printD("========== cloudSharingControllerDidSaveShare ==========")
        if let share = csc.share {
            printD("Share ID: \(share.recordID.recordName)")
            if let url = share.url {
                printD("Share URL: \(url.absoluteString)")
                DispatchQueue.main.async {
                    UIPasteboard.general.url = url
                    printD("Share URL copied to pasteboard!")
                }
            } else {
                printD("WARNING: Share URL is nil in delegate")
            }
        } else {
            printD("WARNING: Share object is nil")
        }
    }
    
    func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
        printD("========== cloudSharingControllerDidStopSharing ==========")
    }
    
    func cloudSharingController(
        _ csc: UICloudSharingController,
        failedToSaveShareWithError error: Error
    ) {
        printD("========== failedToSaveShareWithError ==========")
        printD("Error: \(error.localizedDescription)")
    }
    
    func itemTitle(for csc: UICloudSharingController) -> String? {
        return "Share Recipe Source"
    }
    
}
#endif

// MARK: - Helper Functions
func printD(_ message: String) {
#if DEBUG
    print("[CloudKit] \(message)")
#endif
}
