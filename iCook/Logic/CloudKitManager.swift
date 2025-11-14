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
    @Published var sharedSourceInvitations: [SharedSourceInvitation] = []
    @Published var isCloudKitAvailable = true // Assume available until proven otherwise
    @Published var isOfflineMode = false

    // MARK: - Private Properties
    let container: CKContainer
    private var privateDatabase: CKDatabase { container.privateCloudDatabase }
    private var sharedDatabase: CKDatabase { container.sharedCloudDatabase }
    private let userIdentifier: String? = UserDefaults.standard.string(forKey: "iCloudUserID")
    private let personalZoneID = CKRecordZone.ID(zoneName: "PersonalSources", ownerName: CKCurrentUserDefaultName)
    private lazy var personalZone: CKRecordZone = CKRecordZone(zoneID: personalZoneID)
    private var currentAppVersion: String {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, !version.isEmpty {
            return version
        }
        if let build = Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String, !build.isEmpty {
            return build
        }
        return "0"
    }

    // Caches
    private var sourceCache: [CKRecord.ID: Source] = [:]
    private var categoryCache: [CKRecord.ID: Category] = [:]
    private var recipeCache: [CKRecord.ID: Recipe] = [:]
    private var isCreatingDefaultSource = false
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

    init() {
        self.container = CKContainer(identifier: "iCloud.com.georgebabichev.iCook")
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

    private func loadRecipesLocalCache(for source: Source, categoryID: CKRecord.ID?) -> [Recipe]? {
        let url = cacheFileURL(for: .recipes, sourceID: source.id, categoryID: categoryID)
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                let decoded = try JSONDecoder().decode([Recipe].self, from: data)
                return decoded.map { recipe in
                    var updated = recipe
                    if let path = recipe.cachedImagePath,
                       !FileManager.default.fileExists(atPath: path) {
                        updated.cachedImagePath = nil
                        if let fallback = cachedImagePath(for: recipe.id) {
                            updated.cachedImagePath = fallback
                        }
                    } else if recipe.cachedImagePath == nil,
                              let fallback = cachedImagePath(for: recipe.id) {
                        updated.cachedImagePath = fallback
                    }
                    return updated
                }
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
                return filtered.map { recipe in
                    var updated = recipe
                    if let path = recipe.cachedImagePath,
                       !FileManager.default.fileExists(atPath: path) {
                        updated.cachedImagePath = nil
                        if let fallback = cachedImagePath(for: recipe.id) {
                            updated.cachedImagePath = fallback
                        }
                    } else if recipe.cachedImagePath == nil,
                              let fallback = cachedImagePath(for: recipe.id) {
                        updated.cachedImagePath = fallback
                    }
                    return updated
                }
            } catch {
                printD("Error loading fallback recipes cache: \(error.localizedDescription)")
            }
        }

        return nil
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

    private func imageCacheURL(for recipeID: CKRecord.ID) -> URL {
        let filename = cacheIdentifier(for: recipeID) + ".asset"
        return imageCacheDirectory.appendingPathComponent(filename)
    }

    private func cacheImageData(_ data: Data, for recipeID: CKRecord.ID) -> String? {
        let destination = imageCacheURL(for: recipeID)
        do {
            try data.write(to: destination, options: .atomic)
            return destination.path
        } catch {
            printD("Error caching image data: \(error.localizedDescription)")
            return nil
        }
    }

    private func cacheImageAsset(_ asset: CKAsset, for recipeID: CKRecord.ID) -> String? {
        guard let sourceURL = asset.fileURL else { return nil }
        let destination = imageCacheURL(for: recipeID)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            return destination.path
        } catch {
            printD("Error caching image asset: \(error.localizedDescription)")
            return nil
        }
    }

    private func cachedImagePath(for recipeID: CKRecord.ID) -> String? {
        let destination = imageCacheURL(for: recipeID)
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination.path
        }
        return nil
    }

    private func removeCachedImage(for recipeID: CKRecord.ID) {
        let destination = imageCacheURL(for: recipeID)
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
    }

    private func recipeWithCachedImage(_ recipe: Recipe) -> Recipe {
        var updatedRecipe = recipe
        if let asset = recipe.imageAsset,
           let localPath = cacheImageAsset(asset, for: recipe.id) {
            updatedRecipe.cachedImagePath = localPath
        } else if let currentPath = recipe.cachedImagePath,
                  FileManager.default.fileExists(atPath: currentPath) {
            updatedRecipe.cachedImagePath = currentPath
        } else if let cachedPath = cachedImagePath(for: recipe.id) {
            updatedRecipe.cachedImagePath = cachedPath
        } else {
            updatedRecipe.cachedImagePath = nil
        }
        return updatedRecipe
    }

    // MARK: - Source Management
    func loadSources() async {
        isLoading = true
        defer { isLoading = false }

        // If CloudKit is not available, use local cache only
        guard isCloudKitAvailable else {
            printD("CloudKit not available, using cached sources only")
            if sources.isEmpty && !isCreatingDefaultSource {
                isCreatingDefaultSource = true
                await createDefaultSource()
                isCreatingDefaultSource = false
            }
            return
        }

        do {
            // Load personal sources from private database
            let personalSources = try await fetchSourcesFromDatabase(privateDatabase, isPersonal: true)

            var allSources = personalSources

            // Try to load shared sources from shared database (it may not support zone-wide queries)
            do {
                let sharedSources = try await fetchSourcesFromDatabase(sharedDatabase, isPersonal: false)
                allSources.append(contentsOf: sharedSources)
            } catch {
                let errorDesc = error.localizedDescription
                // SharedDB doesn't support zone-wide queries, so this is expected
                if !errorDesc.contains("SharedDB does not support Zone Wide queries") {
                    printD("Note: Could not load shared sources: \(errorDesc)")
                }
            }

            allSources.sort { $0.lastModified > $1.lastModified }

            self.sources = allSources
            saveSourcesLocalCache()

            // Set default source if none selected
            if currentSource == nil, !allSources.isEmpty {
                currentSource = allSources.first(where: { $0.isPersonal }) ?? allSources.first
            }
        } catch {
            let errorDesc = error.localizedDescription
            // Silently handle schema/indexing errors - CloudKit is still setting up
            if !errorDesc.contains("Did not find record type") && !errorDesc.contains("not marked queryable") {
                printD("Error loading sources: \(errorDesc)")
            }
            // If no sources exist yet, initialize with a default personal source
            if sources.isEmpty && !isCreatingDefaultSource {
                isCreatingDefaultSource = true
                await createDefaultSource()
                isCreatingDefaultSource = false
            }
        }
    }

    private func fetchSourcesFromDatabase(_ database: CKDatabase, isPersonal: Bool) async throws -> [Source] {
        // Use a queryable field (lastModified) instead of TRUEPREDICATE to avoid "recordName is not marked queryable" error
        // This predicate matches all records where lastModified is after the distant past (i.e., all records)
        let predicate = NSPredicate(format: "lastModified >= %@", Date.distantPast as NSDate)
        let query = CKQuery(recordType: "Source", predicate: predicate)
        let (results, _) = try await database.records(matching: query)

        return results.compactMap { _, result in
            guard case .success(let record) = result,
                  let source = Source.from(record) else {
                return nil
            }
            return source
        }
    }

    private func createDefaultSource() async {
        printD("Creating default personal source for new user")
        do {
            await ensurePersonalZoneExists()
            let recordID = CKRecord.ID(recordName: UUID().uuidString, zoneID: personalZoneID)
            let source = Source(
                id: recordID,
                name: "My Recipes",
                isPersonal: true,
                owner: userIdentifier ?? "Unknown",
                lastModified: Date()
            )

            let record = source.toCKRecord()
            let savedRecord = try await privateDatabase.save(record)

            if let savedSource = Source.from(savedRecord) {
                sourceCache[savedSource.id] = savedSource
                sources = [savedSource]
                currentSource = savedSource
                saveSourcesLocalCache()
                printD("Default source created: \(savedSource.name)")
            }
        } catch {
            printD("Error creating default source: \(error.localizedDescription)")
            self.error = "Failed to create default source"
        }
    }

    func createSource(name: String, isPersonal: Bool = true) async {
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
            owner: userIdentifier ?? "Unknown",
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

    func updateSource(_ source: Source) async {
        do {
            let database = source.isPersonal ? privateDatabase : sharedDatabase
            let record = source.toCKRecord()
            let savedRecord = try await database.save(record)

            if let savedSource = Source.from(savedRecord) {
                sourceCache[savedSource.id] = savedSource
                // Update in local array - reassign to ensure SwiftUI detects change
                self.sources = sources.map { $0.id == savedSource.id ? savedSource : $0 }
                if currentSource?.id == savedSource.id {
                    currentSource = savedSource
                }
                saveSourcesLocalCache()
            }
        } catch {
            printD("Error updating source: \(error.localizedDescription)")
            self.error = "Failed to update source"
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

    // MARK: - Debug Functions
    func debugDeleteAllSourcesAndReset() async {
        printD("Debug: Starting delete all sources (count: \(sources.count))")

        // Delete all sources from CloudKit
        let sourcesToDelete = sources // Copy the array since we'll be modifying it
        for (index, source) in sourcesToDelete.enumerated() {
            printD("Debug: Deleting source \(index + 1)/\(sourcesToDelete.count): \(source.name)")
            do {
                let database = source.isPersonal ? privateDatabase : sharedDatabase
                try await database.deleteRecord(withID: source.id)
                sourceCache.removeValue(forKey: source.id)
                printD("Debug: Successfully deleted \(source.name)")
            } catch {
                printD("Debug: Error deleting source \(source.name): \(error.localizedDescription)")
            }
        }

        // Clear local state
        printD("Debug: Clearing all local state")
        sources.removeAll()
        categories.removeAll()
        recipes.removeAll()
        currentSource = nil
        sourceCache.removeAll()
        categoryCache.removeAll()
        recipeCache.removeAll()
        saveSourcesLocalCache()
        printD("Debug: Local state cleared, sources now: \(sources.count)")

        // Recreate default source
        printD("Debug: Recreating default source")
        await createDefaultSource()
        printD("Debug: Done! Current sources: \(sources.count)")
    }

    // MARK: - Category Management
    func loadCategories(for source: Source) async {
        let sourceID = source.id
        isLoading = true
        defer { isLoading = false }

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
            let database = source.isPersonal ? privateDatabase : sharedDatabase
            do {
                let (results, _) = try await database.records(matching: query)
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

    private func loadRecipeCounts(for source: Source) async {
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

        let database = source.isPersonal ? privateDatabase : sharedDatabase

        do {
            let (results, _) = try await database.records(matching: query)
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
            let recordID = source.isPersonal
                ? CKRecord.ID(recordName: UUID().uuidString, zoneID: personalZoneID)
                : CKRecord.ID()
            let category = Category(id: recordID, sourceID: source.id, name: name, icon: icon)

            let database = source.isPersonal ? privateDatabase : sharedDatabase
            let record = category.toCKRecord()
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
            let database = source.isPersonal ? privateDatabase : sharedDatabase

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
    func loadRecipes(for source: Source, category: Category? = nil) async {
        isLoading = true
        defer { isLoading = false }

        if let cachedRecipes = loadRecipesLocalCache(for: source, categoryID: category?.id),
           !cachedRecipes.isEmpty {
            self.recipes = cachedRecipes
        }

        guard isCloudKitAvailable else {
            return
        }

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

            // Try loading from the appropriate database
            let database = source.isPersonal ? privateDatabase : sharedDatabase
            do {
                let (results, _) = try await database.records(matching: query)
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

            self.recipes = allRecipes
            saveRecipesLocalCache(allRecipes, for: source, categoryID: category?.id)
            markOnlineIfNeeded()
        } catch {
            if handleOfflineFallback(for: error) {
                if let cachedRecipes = loadRecipesLocalCache(for: source, categoryID: category?.id) {
                    self.recipes = cachedRecipes
                } else {
                    self.recipes = []
                }
            } else {
                let errorDesc = error.localizedDescription
                // Silently handle "record type not found" errors - schema is still being created
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
        }
    }

    func loadRandomRecipes(for source: Source, count: Int = 20) async {
        isLoading = true
        defer { isLoading = false }

        if let cachedAllRecipes = loadRecipesLocalCache(for: source, categoryID: nil),
           !cachedAllRecipes.isEmpty {
            let shuffled = cachedAllRecipes.shuffled()
            self.recipes = Array(shuffled.prefix(count))
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

            var allRecipes: [Recipe] = []

            // Try loading from the appropriate database
            let database = source.isPersonal ? privateDatabase : sharedDatabase
            do {
                let (results, _) = try await database.records(matching: query)
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

            allRecipes.shuffle()
            saveRecipesLocalCache(allRecipes, for: source, categoryID: nil)
            self.recipes = Array(allRecipes.prefix(count))
            markOnlineIfNeeded()
        } catch {
            if handleOfflineFallback(for: error) {
                if let cachedAllRecipes = loadRecipesLocalCache(for: source, categoryID: nil) {
                    let shuffled = cachedAllRecipes.shuffled()
                    self.recipes = Array(shuffled.prefix(count))
                } else {
                    self.recipes = []
                }
            } else {
                let errorDesc = error.localizedDescription
                // Silently handle "record type not found" errors - schema is still being created
                if !errorDesc.contains("Did not find record type") {
                    printD("Error loading random recipes: \(errorDesc)")
                    self.error = "Failed to load recipes"
                }
                if let cachedAllRecipes = loadRecipesLocalCache(for: source, categoryID: nil) {
                    let shuffled = cachedAllRecipes.shuffled()
                    self.recipes = Array(shuffled.prefix(count))
                } else {
                    self.recipes = []
                }
            }
        }
    }

    func searchRecipes(in source: Source, query: String) async {
        isLoading = true
        defer { isLoading = false }

        if let cachedAllRecipes = loadRecipesLocalCache(for: source, categoryID: nil) {
            let filtered = cachedAllRecipes.filter { recipe in
                recipe.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
            self.recipes = filtered
        }

        guard isCloudKitAvailable else {
            return
        }

        do {
            let predicate = NSPredicate(
                format: "sourceID == %@ AND name CONTAINS[cd] %@",
                CKRecord.Reference(recordID: source.id, action: .none),
                query
            )

            let cloudQuery = CKQuery(recordType: "Recipe", predicate: predicate)
            cloudQuery.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]

            var allRecipes: [Recipe] = []

            // Try loading from the appropriate database
            let database = source.isPersonal ? privateDatabase : sharedDatabase
            do {
                let (results, _) = try await database.records(matching: cloudQuery)

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

            self.recipes = allRecipes
            markOnlineIfNeeded()
        } catch {
            if handleOfflineFallback(for: error) {
                if let cachedAllRecipes = loadRecipesLocalCache(for: source, categoryID: nil) {
                    let filtered = cachedAllRecipes.filter { recipe in
                        recipe.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                    }
                    self.recipes = filtered
                } else {
                    self.recipes = []
                }
            } else {
                let errorDesc = error.localizedDescription
                // Silently handle "record type not found" errors - schema is still being created
                if !errorDesc.contains("Did not find record type") {
                    printD("Error searching recipes: \(errorDesc)")
                    self.error = "Failed to search recipes"
                }
                if let cachedAllRecipes = loadRecipesLocalCache(for: source, categoryID: nil) {
                    let filtered = cachedAllRecipes.filter { recipe in
                        recipe.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                    }
                    self.recipes = filtered
                } else {
                    self.recipes = []
                }
            }
        }
    }

    func createRecipe(_ recipe: Recipe, in source: Source) async {
        do {
            let database = source.isPersonal ? privateDatabase : sharedDatabase
            let record = recipe.toCKRecord()
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
            let database = source.isPersonal ? privateDatabase : sharedDatabase
            let record = recipe.toCKRecord()
            let savedRecord = try await database.save(record)

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
    func saveImage(_ imageData: Data, for recipe: Recipe, in source: Source) async -> ImageSaveResult? {
        do {
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
            try imageData.write(to: tempURL)

            let asset = CKAsset(fileURL: tempURL)
            printD("Image asset created: \(tempURL)")
            let cachedPath = cacheImageData(imageData, for: recipe.id)
            return ImageSaveResult(asset: asset, cachedPath: cachedPath)
        } catch {
            printD("Error saving image: \(error.localizedDescription)")
            self.error = "Failed to save image"
            return nil
        }
    }

    func getImageData(from asset: CKAsset) async -> Data? {
        do {
            guard let fileURL = asset.fileURL else { return nil }
            return try Data(contentsOf: fileURL)
        } catch {
            printD("Error reading image: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Sharing
    @Published var shareControllerPresented = false
    @Published var pendingShare: CKShare?
    @Published var pendingRecord: CKRecord?

    /// Get or create a share URL for a source (cross-platform)
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
                    if let url = share?.url {
                        printD("Using existing share URL: \(url.absoluteString)")
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
            share.publicPermission = .readWrite  // Allow read-write for collaboration

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
                        return url
                    } else {
                        printD("Warning: Fetched share doesn't have URL yet")
                        // Try one more time after a brief delay
                        try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                        if let retryShare = try await privateDatabase.record(for: savedShare.recordID) as? CKShare,
                           let url = retryShare.url {
                            printD("Share URL obtained on retry: \(url.absoluteString)")
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

#if os(iOS)
    /// Prepare a UICloudSharingController for sharing a source
    /// Creates and saves the share first, then creates the controller
    /// - Parameters:
    ///   - source: The source to share (must be personal)
    ///   - completionHandler: Called with the controller when ready, or nil on error
    @available(iOS 17.0, *)
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
                                DispatchQueue.main.async {
                                    let controller = UICloudSharingController(share: share, container: self.container)
                                    printD("UICloudSharingController created for existing share with URL: \(share.url?.absoluteString ?? "pending")")
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
                    var share = CKShare(rootRecord: rootRecord, shareID: shareID)
                    share[CKShare.SystemFieldKey.title] = source.name as CKRecordValue
                    share.publicPermission = .readOnly

                    printD("Share instance created with ID: \(shareID.recordName)")

                    do {
                        let savedShare = try await self.saveShare(for: rootRecord, share: share)
                        printD("Share saved successfully prior to presenting controller with ID: \(savedShare.recordID.recordName)")

                        let controller = UICloudSharingController(share: savedShare, container: self.container)
                        printD("UICloudSharingController created with saved share")

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
#endif

    /// Prepare a source for sharing - legacy method, kept for compatibility
    /// - Parameters:
    ///   - source: The source to share (must be personal)
    /// - Returns: A tuple of (share, record) if successful, nil otherwise
    func prepareShareForSource(_ source: Source) async -> (CKShare, CKRecord)? {
        guard source.isPersonal else {
            self.error = "Cannot share sources that are already shared"
            return nil
        }

        do {
            // Fetch the source record from the PRIVATE database
            let privateRecord = try await privateDatabase.record(for: source.id)
            printD("Fetched source record from private database: \(privateRecord.recordID.recordName)")

            if privateRecord.recordID.zoneID == CKRecordZone.default().zoneID {
                printD("Cannot prepare share for record in default zone")
                self.error = "Sharing requires the source to be stored in the iCook zone. Please recreate this source to share it."
                return nil
            }

            // If already shared, fetch and return the existing share
            if let shareID = privateRecord.share?.recordID {
                // Fetch the actual share record
                let share = try await privateDatabase.record(for: shareID) as? CKShare
                return share.map { (share: $0, record: privateRecord) }
            }

            // Create the share object with the private record as root
            let share = CKShare(rootRecord: privateRecord)
            share.publicPermission = .readOnly
            share[CKShare.SystemFieldKey.title] = source.name

            printD("Share created with ID: \(share.recordID.recordName)")

            // Save the share and root record together (the correct way)
            printD("Saving share and root record together...")
            let (saveResults, _) = try await privateDatabase.modifyRecords(
                saving: [share, privateRecord],
                deleting: []
            )

            // Find the share in saved records by extracting successful results
            let savedShares = saveResults.compactMap { _, result -> CKShare? in
                if case .success(let record) = result,
                   let shareRecord = record as? CKShare {
                    return shareRecord
                }
                return nil
            }

            if let savedShare = savedShares.first {
                printD("Share saved successfully with ID: \(savedShare.recordID.recordName)")
                return (savedShare, privateRecord)
            } else {
                printD("Share was not returned in saved records")
                return (share, privateRecord)
            }
        } catch {
            printD("Error preparing share: \(error.localizedDescription)")
            self.error = "Failed to prepare share: \(error.localizedDescription)"
            return nil
        }
    }

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

    /// Accept a shared source invitation
    /// This is called when the user taps a shared source link
    func acceptSharedSource(_ metadata: CKShare.Metadata) async {
        printD("Accepting shared source with container: \(metadata.containerIdentifier)")

        // The CloudKit framework automatically handles accepting shares
        // We just need to reload sources to show the newly accepted shared source
        await loadSources()

        printD("Shared source accepted and loaded")
    }

    /// Check for incoming share invitations
    /// Note: On iOS 15+, share invitations are handled automatically by the system
    /// This method is provided for reference and future use with custom share handling
    func checkForIncomingShareInvitations() async {
        printD("Checking for incoming share invitations")

        // In a production app, you would handle this in the SceneDelegate or
        // WindowGroup's .onOpenURL modifier to process cloudkit:// links
        // For now, shares are automatically synced when the user taps the link

        // Reload sources to ensure we have the latest shares
        await loadSources()
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
        guard !source.isPersonal else {
            self.error = "Cannot stop sharing a personal source"
            return false
        }

        do {
            let database = sharedDatabase
            let record = source.toCKRecord()

            // Delete the share by removing it from the shared database
            try await database.deleteRecord(withID: record.recordID)

            printD("Stopped sharing source: \(source.name)")
            return true
        } catch {
            printD("Error stopping share: \(error.localizedDescription)")
            self.error = "Failed to stop sharing"
            return false
        }
    }

    /// Copy a share URL to the pasteboard
    /// - Parameter share: The CKShare object to copy the URL from
    /// - Returns: true if successful, false otherwise
    func copyShareURLToPasteboard(_ share: CKShare) -> Bool {
        guard let shareURL = share.url else {
            printD("Error: Share URL is not available")
            self.error = "Share URL not available"
            return false
        }

        #if os(iOS)
        UIPasteboard.general.url = shareURL
        printD("Share URL copied to pasteboard: \(shareURL.absoluteString)")
        return true
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shareURL.absoluteString, forType: .string)
        printD("Share URL copied to pasteboard (macOS): \(shareURL.absoluteString)")
        return true
        #endif
    }

    /// Generate a new CKRecord.ID for content in the personal zone.
    func makePersonalRecordID() -> CKRecord.ID {
        CKRecord.ID(recordName: UUID().uuidString, zoneID: personalZoneID)
    }

}

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
