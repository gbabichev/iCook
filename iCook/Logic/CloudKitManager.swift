import Foundation
import Combine
import CloudKit
import ObjectiveC
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
class CloudKitManager: ObservableObject {
    static let shared = CloudKitManager()

    // MARK: - Published Properties
    @Published var currentSource: Source?
    @Published var sources: [Source] = []
    @Published var categories: [Category] = []
    @Published var recipes: [Recipe] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var sharedSourceInvitations: [SharedSourceInvitation] = []
    @Published var isCloudKitAvailable = true // Assume available until proven otherwise

    // MARK: - Private Properties
    let container: CKContainer
    private var privateDatabase: CKDatabase { container.privateCloudDatabase }
    private var sharedDatabase: CKDatabase { container.sharedCloudDatabase }
    private let userIdentifier: String? = UserDefaults.standard.string(forKey: "iCloudUserID")

    // Caches
    private var sourceCache: [CKRecord.ID: Source] = [:]
    private var categoryCache: [CKRecord.ID: Category] = [:]
    private var recipeCache: [CKRecord.ID: Recipe] = [:]
    private var isCreatingDefaultSource = false

    init() {
        self.container = CKContainer(identifier: "iCloud.com.georgebabichev.iCook")
        // Load from local cache immediately
        loadSourcesLocalCache()
        Task {
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
                let savedRecordID = CKRecord.ID(recordName: savedSourceID)
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
            let recordID = CKRecord.ID()
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
        let recordID = CKRecord.ID()
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
        guard let sourceID = currentSource?.id else { return }

        isLoading = true
        defer { isLoading = false }

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
        } catch {
            let errorDesc = error.localizedDescription
            // Silently handle "record type not found" errors - schema is still being created
            if !errorDesc.contains("Did not find record type") {
                printD("Error loading categories: \(errorDesc)")
                self.error = "Failed to load categories"
            }
            self.categories = []
        }
    }

    func createCategory(name: String, icon: String, in source: Source) async {
        do {
            let recordID = CKRecord.ID()
            let category = Category(id: recordID, sourceID: source.id, name: name, icon: icon)

            let database = source.isPersonal ? privateDatabase : sharedDatabase
            let record = category.toCKRecord()
            let savedRecord = try await database.save(record)

            if let savedCategory = Category.from(savedRecord) {
                categoryCache[savedCategory.id] = savedCategory
                // Add to UI immediately without re-querying CloudKit
                self.categories = (categories + [savedCategory]).sorted { $0.name < $1.name }
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
            let record = category.toCKRecord()
            let savedRecord = try await database.save(record)

            if let savedCategory = Category.from(savedRecord) {
                categoryCache[savedCategory.id] = savedCategory
                // Update in local array without re-querying CloudKit
                self.categories = categories.map { $0.id == savedCategory.id ? savedCategory : $0 }
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
                    recipeCache[recipe.id] = recipe
                    return recipe
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
        } catch {
            let errorDesc = error.localizedDescription
            // Silently handle "record type not found" errors - schema is still being created
            if !errorDesc.contains("Did not find record type") {
                printD("Error loading recipes: \(errorDesc)")
                self.error = "Failed to load recipes"
            }
            self.recipes = []
        }
    }

    func loadRandomRecipes(for source: Source, count: Int = 20) async {
        isLoading = true
        defer { isLoading = false }

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
                    return recipe
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
            self.recipes = Array(allRecipes.prefix(count))
        } catch {
            let errorDesc = error.localizedDescription
            // Silently handle "record type not found" errors - schema is still being created
            if !errorDesc.contains("Did not find record type") {
                printD("Error loading random recipes: \(errorDesc)")
                self.error = "Failed to load recipes"
            }
            self.recipes = []
        }
    }

    func searchRecipes(in source: Source, query: String) async {
        isLoading = true
        defer { isLoading = false }

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
                    recipeCache[recipe.id] = recipe
                    return recipe
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
        } catch {
            let errorDesc = error.localizedDescription
            // Silently handle "record type not found" errors - schema is still being created
            if !errorDesc.contains("Did not find record type") {
                printD("Error searching recipes: \(errorDesc)")
                self.error = "Failed to search recipes"
            }
            self.recipes = []
        }
    }

    func createRecipe(_ recipe: Recipe, in source: Source) async {
        do {
            let database = source.isPersonal ? privateDatabase : sharedDatabase
            let record = recipe.toCKRecord()
            let savedRecord = try await database.save(record)

            if let savedRecipe = Recipe.from(savedRecord) {
                recipeCache[savedRecipe.id] = savedRecipe
                printD("Recipe created: \(savedRecipe.name)")
            }
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
                recipeCache[savedRecipe.id] = savedRecipe
                printD("Recipe updated: \(savedRecipe.name)")
            }
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
            printD("Recipe deleted: \(recipe.name)")
        } catch {
            printD("Error deleting recipe: \(error.localizedDescription)")
            self.error = "Failed to delete recipe"
        }
    }

    // MARK: - Image Handling
    func saveImage(_ imageData: Data, for recipe: Recipe, in source: Source) async -> CKAsset? {
        do {
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
            try imageData.write(to: tempURL)

            let asset = CKAsset(fileURL: tempURL)
            printD("Image asset created: \(tempURL)")
            return asset
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

                // Check if already shared
                if let existingShare = rootRecord.share {
                    printD("Record is already shared, fetching existing share...")
                    // Already shared, fetch and use existing share
                    let shareRecordID = existingShare.recordID
                    let fetchOp = CKFetchRecordsOperation(recordIDs: [shareRecordID])

                    fetchOp.fetchRecordsCompletionBlock = { recordsByID, error in
                        if let error = error {
                            printD("Error fetching existing share: \(error.localizedDescription)")
                            completionHandler(nil)
                            return
                        }

                        guard let share = recordsByID?[shareRecordID] as? CKShare else {
                            printD("Could not cast fetched record to CKShare")
                            completionHandler(nil)
                            return
                        }

                        DispatchQueue.main.async {
                            let controller = UICloudSharingController(share: share, container: self.container)
                            printD("UICloudSharingController created for existing share with URL: \(share.url?.absoluteString ?? "pending")")
                            completionHandler(controller)
                        }
                    }
                    privateDatabase.add(fetchOp)
                } else {
                    printD("Record not yet shared, creating share with preparation handler...")

                    // Create the share with a unique ID
                    // IMPORTANT: Use the same zone ID as the root record!
                    let shareID = CKRecord.ID(recordName: UUID().uuidString, zoneID: rootRecord.recordID.zoneID)
                    var share = CKShare(rootRecord: rootRecord, shareID: shareID)
                    share[CKShare.SystemFieldKey.title] = source.name as CKRecordValue
                    share.publicPermission = .readOnly

                    printD("Share instance created with ID: \(shareID.recordName)")

                    // Create the controller with a preparation handler
                    // The handler is called when the user is about to confirm sharing
                    let controller = UICloudSharingController { [weak self] _, prepareCompletionHandler in
                        guard let self = self else { return }

                        printD("Preparation handler called by UICloudSharingController")

                        // DON'T save the share here - let UICloudSharingController handle it
                        // Just verify the root record is shareable and return the share
                        // The controller will save the share when the user confirms
                        printD("Returning unsaved share to UICloudSharingController for processing")
                        prepareCompletionHandler(share, self.container, nil)
                    }

                    printD("UICloudSharingController created with preparation handler")

                    // Create a delegate that will copy the URL to pasteboard
                    let delegate = CloudKitShareDelegate()
                    controller.delegate = delegate

                    // Store the delegate on the controller to keep it alive
                    objc_setAssociatedObject(controller, &CloudKitShareDelegate.associatedObjectKey, delegate, .OBJC_ASSOCIATION_RETAIN)

                    printD("Delegate attached to controller")

                    await MainActor.run {
                        completionHandler(controller)
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
            share[CKShare.SystemFieldKey.shareType] = "recipes.source"

            printD("Share created with ID: \(share.recordID.recordName)")

            // Save the share and root record together (the correct way)
            printD("Saving share and root record together...")
            let (savedRecords, _) = try await privateDatabase.modifyRecords(
                saving: [share, privateRecord],
                deleting: []
            )

            // Find the share in saved records
            if let savedShare = savedRecords.compactMap({ $0 as? CKShare }).first {
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

    /// Save a share to CloudKit after user confirms via UICloudSharingController
    func saveShare(_ share: CKShare, for record: CKRecord) async -> Bool {
        do {
            let database = sharedDatabase
            _ = try await database.save(share)
            printD("Share saved successfully for record: \(record.recordID.recordName)")
            return true
        } catch {
            printD("Error saving share: \(error.localizedDescription)")
            self.error = "Failed to save share"
            return false
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
