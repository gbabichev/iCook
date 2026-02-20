@preconcurrency import Foundation
import Combine
import CloudKit
import UniformTypeIdentifiers

@MainActor
final class AppViewModel: ObservableObject {
    @Published var categories: [Category] = []
    @Published var tags: [Tag] = []
    @Published var recipes: [Recipe] = []
    @Published var randomRecipes: [Recipe] = []
    @Published var recipeCounts: [CKRecord.ID: Int] = [:]
    @Published var isLoadingCategories = false
    @Published var isLoadingRecipes = false
    @Published var recipesRefreshTrigger = 0
    @Published var isImporting = false
    @Published var isAcceptingShare = false
    struct ImportPreview: Identifiable {
        var id: URL { url }
        let url: URL
        let package: RecipeExportPackage
        let images: [String: Data]
    }
    @Published var error: String?
    @Published var isOfflineMode = false
    private let lastViewedRecipeKey = "LastViewedRecipe"
    private let appLocationKey = "AppLocation"

    // CloudKit manager
    let cloudKitManager = CloudKitManager.shared

    // Source management
    @Published var currentSource: Source?
    @Published var sources: [Source] = []
    @Published var sourceSelectionStamp = UUID()
    private var notificationCancellables = Set<AnyCancellable>()

    // App location tracking
    enum AppLocation {
        case allRecipes
        case category(categoryID: CKRecord.ID)
        case tag(tagID: CKRecord.ID)
        case recipe(recipeID: CKRecord.ID, categoryID: CKRecord.ID?)
    }

    init() {
        // Prime from cached manager state so UI doesn't start empty when offline/online
        sources = cloudKitManager.sources
        currentSource = cloudKitManager.currentSource
        if let source = currentSource {
            cloudKitManager.loadCachedData(for: source)
            categories = cloudKitManager.categories
            tags = cloudKitManager.tags
            recipeCounts = cloudKitManager.recipeCounts
            recipes = cloudKitManager.recipes
            randomRecipes = recipes
        }
        
        NotificationCenter.default.publisher(for: .recipesRefreshed)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // Keep the current visible recipe list in sync, but avoid no-op churn
                // that resets view state (e.g., featured recipe flicker in categories).
                let incoming = self.cloudKitManager.recipes
                if !self.recipesEqual(self.recipes, incoming) {
                    self.recipes = incoming
                }
            }
            .store(in: &notificationCancellables)
        
        NotificationCenter.default.publisher(for: .sourcesRefreshed)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.sources = self.cloudKitManager.sources
                if let current = self.cloudKitManager.currentSource {
                    self.currentSource = current
                } else if !self.sources.isEmpty {
                    self.currentSource = self.sources.first
                } else {
                    self.currentSource = nil
                }
                
                if let current = self.currentSource {
                    self.cloudKitManager.loadCachedData(for: current)
                    self.categories = self.cloudKitManager.categories
                    self.tags = self.cloudKitManager.tags
                    self.recipeCounts = self.cloudKitManager.recipeCounts
                    self.recipes = self.cloudKitManager.recipes
                    self.randomRecipes = self.cloudKitManager.recipes
                } else {
                    self.categories.removeAll()
                    self.tags.removeAll()
                    self.recipes.removeAll()
                    self.randomRecipes.removeAll()
                    self.recipeCounts.removeAll()
                }
            }
            .store(in: &notificationCancellables)
    }
    
    private func refreshOfflineState() {
        isOfflineMode = !cloudKitManager.isCloudKitAvailable || cloudKitManager.isOfflineMode
    }
    
    // MARK: - Source Management
    func loadSources() async {
        await cloudKitManager.loadSources()
        sources = cloudKitManager.sources
        currentSource = cloudKitManager.currentSource
        tags = currentSource == nil ? [] : cloudKitManager.tags
        refreshOfflineState()
    }
    
    func selectSource(_ source: Source, skipCacheOnLoad: Bool = true) async {
        printD("[LaunchTrace] selectSource start source=\(source.name) skipCacheOnLoad=\(skipCacheOnLoad)")
        cloudKitManager.currentSource = source
        cloudKitManager.saveCurrentSourceID()
        currentSource = source
        sourceSelectionStamp = UUID()
        await loadCategories()
        printD("[LaunchTrace] selectSource after loadCategories source=\(source.name) categories=\(categories.count) tags=\(tags.count)")
        await loadRandomRecipes(skipCache: skipCacheOnLoad)
        printD("[LaunchTrace] selectSource after loadRandomRecipes source=\(source.name) recipes=\(recipes.count)")
        refreshOfflineState()
        printD("[LaunchTrace] selectSource end source=\(source.name) offline=\(isOfflineMode)")
    }
    
    func createSource(name: String) async -> Bool {
        let success = await cloudKitManager.createSource(name: name, isPersonal: true)
        // Copy sources directly from CloudKitManager without re-querying
        // (the new source might not be indexed in CloudKit yet)
        sources = cloudKitManager.sources
        currentSource = cloudKitManager.currentSource
        tags = cloudKitManager.tags
        cloudKitManager.saveCurrentSourceID()
        error = cloudKitManager.error
        refreshOfflineState()
        return success
    }
    
    func deleteSource(_ source: Source) async -> Bool {
        error = nil
        cloudKitManager.error = nil
        await cloudKitManager.deleteSource(source)
        error = cloudKitManager.error
        // Copy sources directly from CloudKitManager without re-querying
        sources = cloudKitManager.sources
        currentSource = cloudKitManager.currentSource
        categories = cloudKitManager.categories
        tags = cloudKitManager.tags
        recipes = cloudKitManager.recipes
        recipeCounts = cloudKitManager.recipeCounts
        cloudKitManager.saveCurrentSourceID()
        refreshOfflineState()
        return cloudKitManager.error == nil
    }
    
    func renameSource(_ source: Source, newName: String) async -> Bool {
        error = nil
        cloudKitManager.error = nil
        refreshOfflineState()
        guard canRenameSource(source) else {
            error = isOfflineMode
                ? "You're offline. Renaming collections is disabled."
                : "Only collection owners can rename it."
            return false
        }

        await cloudKitManager.updateSource(source, newName: newName)
        error = cloudKitManager.error
        sources = cloudKitManager.sources
        if let updated = sources.first(where: { $0.id == source.id }) {
            currentSource = updated
            cloudKitManager.currentSource = updated
        } else {
            currentSource = cloudKitManager.currentSource
        }
        tags = cloudKitManager.tags
        cloudKitManager.saveCurrentSourceID()
        refreshOfflineState()
        return cloudKitManager.error == nil
    }
#if os(macOS)
    func leaveSharedSource(_ source: Source) async {
        _ = await cloudKitManager.leaveSharedSource(source)
        sources = cloudKitManager.sources
        if currentSource?.id == source.id {
            currentSource = sources.first
            cloudKitManager.saveCurrentSourceID()
            if let newSource = currentSource {
                await selectSource(newSource)
                return
            } else {
                categories.removeAll()
                tags.removeAll()
                recipes.removeAll()
                recipeCounts.removeAll()
            }
        }
        refreshOfflineState()
    }
#endif
    
    func acceptShareURL(_ url: URL) async -> Bool {
        isAcceptingShare = true
        defer { isAcceptingShare = false }
        let success = await cloudKitManager.acceptShare(from: url)
        sources = cloudKitManager.sources
        currentSource = cloudKitManager.currentSource
        refreshOfflineState()
        if success, let source = currentSource {
            await selectSource(source)
            printD("DEBUG: Loaded categories and random recipes for shared source \(source.name)")
        } else {
            error = cloudKitManager.error
        }
        return success
    }
    
    func acceptShareMetadata(_ metadata: CKShare.Metadata) async -> Bool {
        isAcceptingShare = true
        defer { isAcceptingShare = false }
        let success = await cloudKitManager.acceptShare(metadata: metadata)
        sources = cloudKitManager.sources
        currentSource = cloudKitManager.currentSource
        refreshOfflineState()
        if success, let source = currentSource {
            await selectSource(source)
            printD("DEBUG: Loaded categories and random recipes for shared source \(source.name)")
        } else {
            error = cloudKitManager.error
        }
        return success
    }
    
    // MARK: - Category Management
    func loadCategories() async {
        guard let source = currentSource else { return }
        isLoadingCategories = true
        
        // Keep cached categories visible; just fetch latest and then swap in
        await cloudKitManager.loadCategories(for: source)
        categories = cloudKitManager.categories
        tags = cloudKitManager.tags
        await cloudKitManager.loadRecipeCounts(for: source)
        recipeCounts = cloudKitManager.recipeCounts
        error = cloudKitManager.error
        refreshOfflineState()
        isLoadingCategories = false
    }
    
    func createCategory(name: String, icon: String) async -> Bool {
        guard let source = currentSource else { return false }
        error = nil
        cloudKitManager.error = nil
        
        await cloudKitManager.createCategory(name: name, icon: icon, in: source)
        error = cloudKitManager.error
        // Copy directly from CloudKitManager without re-querying
        categories = cloudKitManager.categories
        recipeCounts = cloudKitManager.recipeCounts
        refreshOfflineState()
        return error == nil
    }
    
    func updateCategory(id: CKRecord.ID, name: String, icon: String) async -> Bool {
        guard let source = currentSource else { return false }
        guard let category = categories.first(where: { $0.id == id }) else { return false }
        error = nil
        cloudKitManager.error = nil
        
        var updatedCategory = category
        updatedCategory.name = name
        updatedCategory.icon = icon
        
        await cloudKitManager.updateCategory(updatedCategory, in: source)
        error = cloudKitManager.error
        // Copy directly from CloudKitManager without re-querying
        categories = cloudKitManager.categories
        recipeCounts = cloudKitManager.recipeCounts
        refreshOfflineState()
        return error == nil
    }
    
    func deleteCategory(id: CKRecord.ID) async {
        guard let source = currentSource else { return }
        guard let category = categories.first(where: { $0.id == id }) else { return }
        error = nil
        cloudKitManager.error = nil
        
        await cloudKitManager.deleteCategory(category, in: source)
        error = cloudKitManager.error
        // Copy directly from CloudKitManager without re-querying
        categories = cloudKitManager.categories
        recipeCounts = cloudKitManager.recipeCounts
        refreshOfflineState()
    }

    // MARK: - Tag Management
    func createTag(name: String) async -> Bool {
        guard let source = currentSource else { return false }
        error = nil
        cloudKitManager.error = nil

        await cloudKitManager.createTag(name: name, in: source)
        error = cloudKitManager.error
        tags = cloudKitManager.tags
        refreshOfflineState()
        return error == nil
    }

    func updateTag(id: CKRecord.ID, name: String) async -> Bool {
        guard let source = currentSource else { return false }
        guard let tag = tags.first(where: { $0.id == id }) else { return false }
        error = nil
        cloudKitManager.error = nil

        var updatedTag = tag
        updatedTag.name = name
        updatedTag.lastModified = Date()

        await cloudKitManager.updateTag(updatedTag, in: source)
        error = cloudKitManager.error
        tags = cloudKitManager.tags
        refreshOfflineState()
        return error == nil
    }

    func deleteTag(id: CKRecord.ID) async -> Bool {
        guard let source = currentSource else { return false }
        guard let tag = tags.first(where: { $0.id == id }) else { return false }
        error = nil
        cloudKitManager.error = nil

        await cloudKitManager.deleteTag(tag, in: source)
        error = cloudKitManager.error
        tags = cloudKitManager.tags
        refreshOfflineState()
        return error == nil
    }
    
    // MARK: - Recipe Management
    func loadRecipesForCategory(skipCache: Bool = false) async {
        // Unified path: load all recipes and filter at the view layer.
        await loadRandomRecipes(skipCache: skipCache)
    }
    
    func loadRandomRecipes(skipCache: Bool = false) async {
        guard let source = currentSource else { return }
        guard !isLoadingRecipes else { return }
        
        printD("[LaunchTrace] loadRandomRecipes start source=\(source.name) skipCache=\(skipCache) currentRecipes=\(recipes.count)")
        isLoadingRecipes = true
        
        // Serve cached all-recipes immediately for snappier home load
        if !skipCache, let cached = cloudKitManager.cachedRecipes(for: source, categoryID: nil) {
            printD("[LaunchTrace] loadRandomRecipes using cached all-recipes count=\(cached.count) source=\(source.name)")
            randomRecipes = cached
            recipes = cached
        } else if !skipCache {
            printD("[LaunchTrace] loadRandomRecipes no cached all-recipes found source=\(source.name)")
        }
        
        await cloudKitManager.loadRandomRecipes(for: source, skipCache: skipCache)
        let fetched = cloudKitManager.recipes
        printD("[LaunchTrace] loadRandomRecipes cloud returned count=\(fetched.count) source=\(source.name)")
        
        // Only bump the refresh trigger if the fetched data is meaningfully different
        let unchanged = recipesEqual(randomRecipes, fetched)
        printD("[LaunchTrace] loadRandomRecipes compare unchanged=\(unchanged) oldRandom=\(randomRecipes.count) fetched=\(fetched.count)")
        
        if !unchanged {
            randomRecipes = fetched
            // Keep the main recipes array in sync so category views pick up latest names
            recipes = fetched
            // Increment trigger to force SwiftUI to detect the change
            recipesRefreshTrigger += 1
            printD("[LaunchTrace] loadRandomRecipes applied fetched recipes count=\(recipes.count) refreshTrigger=\(recipesRefreshTrigger)")
        }
        
        error = cloudKitManager.error
        refreshOfflineState()
        isLoadingRecipes = false
        printD("[LaunchTrace] loadRandomRecipes end source=\(source.name) error=\(error ?? "nil")")
    }
    
    func deleteRecipe(id: CKRecord.ID) async -> Bool {
        printD("deleteRecipe: Called with recipe ID: \(id.recordName)")
        error = nil
        cloudKitManager.error = nil
        
        refreshOfflineState()
        if isOfflineMode {
            error = "You're offline. Deleting recipes is disabled."
            printD("deleteRecipe: FAILED - Offline mode")
            return false
        }
        
        guard let source = currentSource else {
            printD("deleteRecipe: FAILED - No currentSource available")
            return false
        }
        printD("deleteRecipe: Found source: \(source.name)")
        
        // Try to find recipe in recipes array first, then in randomRecipes
        var recipe = recipes.first(where: { $0.id == id })
        if recipe == nil {
            printD("deleteRecipe: Recipe not in recipes array, checking randomRecipes...")
            recipe = randomRecipes.first(where: { $0.id == id })
        }
        
        guard let recipe = recipe else {
            printD("deleteRecipe: FAILED - Recipe not found in either recipes or randomRecipes array")
            printD("deleteRecipe: Looking for ID: \(id.recordName)")
            printD("deleteRecipe: Available recipe IDs in recipes: \(recipes.map { $0.id.recordName })")
            printD("deleteRecipe: Available recipe IDs in randomRecipes: \(randomRecipes.map { $0.id.recordName })")
            return false
        }
        printD("deleteRecipe: Found recipe: \(recipe.name)")
        
        printD("deleteRecipe: Calling cloudKitManager.deleteRecipe...")
        let deleted = await cloudKitManager.deleteRecipe(recipe, in: source)
        printD("deleteRecipe: CloudKit deletion completed")
        if !deleted {
            error = cloudKitManager.error
            refreshOfflineState()
            return false
        }
        
        // Remove from the local recipes array immediately
        printD("deleteRecipe: Removing recipe from local arrays. Before: recipes=\(self.recipes.count), randomRecipes=\(self.randomRecipes.count)")
        self.recipes = recipes.filter { $0.id != id }
        randomRecipes.removeAll { $0.id == id }
        let oldCount = recipeCounts[recipe.categoryID, default: 1]
        recipeCounts[recipe.categoryID] = max(oldCount - 1, 0)
        
        // Persist updated caches so deleted recipes don't reappear offline
        cloudKitManager.recipes = recipes
        cloudKitManager.cacheRecipesSnapshot(recipes, for: source)
        let categoryRecipes = recipes.filter { $0.categoryID == recipe.categoryID }
        cloudKitManager.cacheRecipes(categoryRecipes, for: source, categoryID: recipe.categoryID)
        printD("deleteRecipe: After removal: recipes=\(self.recipes.count), randomRecipes=\(self.randomRecipes.count)")
        
        refreshOfflineState()
        
        printD("deleteRecipe: Posting recipeDeleted notification")
        NotificationCenter.default.post(name: .recipeDeleted, object: id as CKRecord.ID)
        printD("deleteRecipe: Successfully deleted recipe")
        return true
    }
    
    func deleteRecipeWithUIFeedback(id: CKRecord.ID) async -> Bool {
        printD("deleteRecipeWithUIFeedback: Called with recipe ID: \(id.recordName)")
        let success = await deleteRecipe(id: id)
        printD("deleteRecipeWithUIFeedback: Result - Success: \(success)")
        return success
    }

    // MARK: - Helpers
    private func recipesEqual(_ lhs: [Recipe], _ rhs: [Recipe]) -> Bool {
        lhs.count == rhs.count &&
        zip(lhs, rhs).allSatisfy { first, second in
            first.id == second.id &&
            first.lastModified == second.lastModified &&
            first.name == second.name &&
            first.recipeTime == second.recipeTime
        }
    }
    
    // MARK: - Last Viewed Recipe Persistence
    func saveLastViewedRecipe(_ recipe: Recipe) {
        let dict: [String: String] = [
            "recipeRecordName": recipe.id.recordName,
            "recipeZoneName": recipe.id.zoneID.zoneName,
            "recipeZoneOwner": recipe.id.zoneID.ownerName,
            "sourceRecordName": recipe.sourceID.recordName,
            "sourceZoneName": recipe.sourceID.zoneID.zoneName,
            "sourceZoneOwner": recipe.sourceID.zoneID.ownerName,
            "categoryRecordName": recipe.categoryID.recordName,
            "categoryZoneName": recipe.categoryID.zoneID.zoneName,
            "categoryZoneOwner": recipe.categoryID.zoneID.ownerName
        ]
        UserDefaults.standard.set(dict, forKey: lastViewedRecipeKey)
    }

    // MARK: - App Location Persistence
    func saveAppLocation(_ location: AppLocation) {
        guard let source = currentSource else { return }

        var dict: [String: String] = [
            "sourceRecordName": source.id.recordName,
            "sourceZoneName": source.id.zoneID.zoneName,
            "sourceZoneOwner": source.id.zoneID.ownerName
        ]

        switch location {
        case .allRecipes:
            dict["locationType"] = "allRecipes"

        case .category(let categoryID):
            dict["locationType"] = "category"
            dict["categoryRecordName"] = categoryID.recordName
            dict["categoryZoneName"] = categoryID.zoneID.zoneName
            dict["categoryZoneOwner"] = categoryID.zoneID.ownerName

        case .tag(let tagID):
            dict["locationType"] = "tag"
            dict["tagRecordName"] = tagID.recordName
            dict["tagZoneName"] = tagID.zoneID.zoneName
            dict["tagZoneOwner"] = tagID.zoneID.ownerName

        case .recipe(let recipeID, let categoryID):
            dict["locationType"] = "recipe"
            dict["recipeRecordName"] = recipeID.recordName
            dict["recipeZoneName"] = recipeID.zoneID.zoneName
            dict["recipeZoneOwner"] = recipeID.zoneID.ownerName
            if let categoryID = categoryID {
                dict["categoryRecordName"] = categoryID.recordName
                dict["categoryZoneName"] = categoryID.zoneID.zoneName
                dict["categoryZoneOwner"] = categoryID.zoneID.ownerName
            }
        }

        UserDefaults.standard.set(dict, forKey: appLocationKey)
    }

    func loadAppLocation() -> (location: AppLocation, sourceID: CKRecord.ID)? {
        guard let dict = UserDefaults.standard.dictionary(forKey: appLocationKey) as? [String: String],
              let locationType = dict["locationType"],
              let sourceRecord = dict["sourceRecordName"],
              let sourceZone = dict["sourceZoneName"],
              let sourceOwner = dict["sourceZoneOwner"] else {
            return nil
        }

        let sourceZoneID = CKRecordZone.ID(zoneName: sourceZone, ownerName: sourceOwner)
        let sourceID = CKRecord.ID(recordName: sourceRecord, zoneID: sourceZoneID)

        switch locationType {
        case "allRecipes":
            return (.allRecipes, sourceID)

        case "category":
            guard let catRecord = dict["categoryRecordName"],
                  let catZone = dict["categoryZoneName"],
                  let catOwner = dict["categoryZoneOwner"] else {
                return nil
            }
            let catZoneID = CKRecordZone.ID(zoneName: catZone, ownerName: catOwner)
            let catID = CKRecord.ID(recordName: catRecord, zoneID: catZoneID)
            return (.category(categoryID: catID), sourceID)

        case "tag":
            guard let tagRecord = dict["tagRecordName"],
                  let tagZone = dict["tagZoneName"],
                  let tagOwner = dict["tagZoneOwner"] else {
                return nil
            }
            let tagZoneID = CKRecordZone.ID(zoneName: tagZone, ownerName: tagOwner)
            let tagID = CKRecord.ID(recordName: tagRecord, zoneID: tagZoneID)
            return (.tag(tagID: tagID), sourceID)

        case "recipe":
            guard let recipeRecord = dict["recipeRecordName"],
                  let recipeZone = dict["recipeZoneName"],
                  let recipeOwner = dict["recipeZoneOwner"] else {
                return nil
            }
            let recipeZoneID = CKRecordZone.ID(zoneName: recipeZone, ownerName: recipeOwner)
            let recipeID = CKRecord.ID(recordName: recipeRecord, zoneID: recipeZoneID)

            var categoryID: CKRecord.ID? = nil
            if let catRecord = dict["categoryRecordName"],
               let catZone = dict["categoryZoneName"],
               let catOwner = dict["categoryZoneOwner"] {
                let catZoneID = CKRecordZone.ID(zoneName: catZone, ownerName: catOwner)
                categoryID = CKRecord.ID(recordName: catRecord, zoneID: catZoneID)
            }
            return (.recipe(recipeID: recipeID, categoryID: categoryID), sourceID)

        default:
            return nil
        }
    }

    func clearAppLocation() {
        UserDefaults.standard.removeObject(forKey: appLocationKey)
    }

    func createRecipeWithSteps(
        categoryId: CKRecord.ID,
        name: String,
        recipeTime: Int?,
        details: String?,
        image: Data?,
        recipeSteps: [RecipeStep]?,
        tagIDs: [CKRecord.ID] = []
    ) async -> Bool {
        guard let source = currentSource else { return false }
        error = nil
        cloudKitManager.error = nil
        
        isLoadingRecipes = true
        defer { isLoadingRecipes = false }
        
        let recordID = cloudKitManager.makeRecordID(for: source)
        let recipe = Recipe(
            id: recordID,
            sourceID: source.id,
            categoryID: categoryId,
            name: name,
            recipeTime: recipeTime ?? 0,
            details: details,
            imageAsset: nil,
            recipeSteps: recipeSteps ?? [],
            tagIDs: tagIDs
        )
        
        // Handle image if provided
        var tempImageURL: URL?
        var recipeWithImage = recipe
        if let imageData = image {
            if let result = await cloudKitManager.saveImage(imageData, for: recipe) {
                recipeWithImage.imageAsset = result.asset
                recipeWithImage.cachedImagePath = result.cachedPath
                tempImageURL = result.tempURL
            }
        }
        defer {
            if let tempImageURL {
                try? FileManager.default.removeItem(at: tempImageURL)
            }
        }
        
        await cloudKitManager.createRecipe(recipeWithImage, in: source)
        error = cloudKitManager.error
        
        // Add recipe directly to local array without re-querying CloudKit
        // (newly created recipe won't be indexed in CloudKit immediately)
        if error == nil {
            printD("Recipe created successfully, adding to local list")
            let newRecipes = (recipes + [recipeWithImage]).sorted { $0.lastModified > $1.lastModified }
            printD("Before: recipes.count = \(recipes.count)")
            printD("Adding: \(recipeWithImage.name)")
            self.recipes = newRecipes
            printD("After: recipes.count = \(self.recipes.count)")
            printD("recipes array: \(recipes.map { $0.name })")
            // Also add to random recipes
            self.randomRecipes = (randomRecipes + [recipeWithImage]).sorted { $0.lastModified > $1.lastModified }
            recipeCounts[categoryId, default: 0] += 1
            // Persist caches immediately so cold launch/offline reflects the new recipe.
            cloudKitManager.recipes = newRecipes
            cloudKitManager.cacheRecipesSnapshot(newRecipes, for: source)
            let categoryRecipes = newRecipes.filter { $0.categoryID == categoryId }
            cloudKitManager.cacheRecipes(categoryRecipes, for: source, categoryID: categoryId)
            
            // Small delay to ensure UI updates before sheet dismisses
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
        }
        
        refreshOfflineState()
        return error == nil
    }
    
    func updateRecipeWithSteps(
        id: CKRecord.ID,
        categoryId: CKRecord.ID?,
        name: String?,
        recipeTime: Int?,
        details: String?,
        image: Data?,
        recipeSteps: [RecipeStep]?,
        tagIDs: [CKRecord.ID]? = nil
    ) async -> Bool {
        guard let source = currentSource else {
            printD("DEBUG: updateRecipeWithSteps failed - no currentSource")
            return false
        }
        error = nil
        cloudKitManager.error = nil
        
        // If recipes array is empty, reload them
        if recipes.isEmpty {
            printD("DEBUG: Recipes array is empty, reloading for source: \(source.name)")
            await cloudKitManager.loadRecipes(for: source, category: nil)
            recipes = cloudKitManager.recipes
        }
        
        guard let recipe = recipes.first(where: { $0.id == id }) else {
            printD("DEBUG: updateRecipeWithSteps failed - recipe not found. ID: \(id.recordName), recipes count: \(recipes.count)")
            printD("DEBUG: Available recipe IDs: \(recipes.map { $0.id.recordName })")
            printD("DEBUG: currentSource: \(source.name), isPersonal: \(source.isPersonal)")
            return false
        }
        
        isLoadingRecipes = true
        defer { isLoadingRecipes = false }
        
        var updatedRecipe = recipe
        // Only attach image assets when the user selected a new image in this edit session.
        // This avoids reusing stale CKAsset file URLs from previously fetched records.
        updatedRecipe.imageAsset = nil
        updatedRecipe.lastModified = Date()
        if let name = name { updatedRecipe.name = name }
        if let recipeTime = recipeTime { updatedRecipe.recipeTime = recipeTime }
        if let details = details { updatedRecipe.details = details }
        if let categoryId = categoryId { updatedRecipe.categoryID = categoryId }
        if let recipeSteps = recipeSteps { updatedRecipe.recipeSteps = recipeSteps }
        if let tagIDs = tagIDs { updatedRecipe.tagIDs = tagIDs }
        
        // Handle image if provided
        var tempImageURL: URL?
        if let imageData = image {
            if let result = await cloudKitManager.saveImage(imageData, for: updatedRecipe) {
                updatedRecipe.imageAsset = result.asset
                updatedRecipe.cachedImagePath = result.cachedPath
                tempImageURL = result.tempURL
            }
        }
        defer {
            if let tempImageURL {
                try? FileManager.default.removeItem(at: tempImageURL)
            }
        }
        
        await cloudKitManager.updateRecipe(updatedRecipe, in: source)
        error = cloudKitManager.error
        
        // Update the recipe in the local array immediately
        if error == nil {
            if let categoryId = categoryId, categoryId != recipe.categoryID {
                let oldID = recipe.categoryID
                let newID = categoryId
                let oldCount = recipeCounts[oldID, default: 1]
                recipeCounts[oldID] = max(oldCount - 1, 0)
                recipeCounts[newID, default: 0] += 1
            }
            if let index = recipes.firstIndex(where: { $0.id == id }) {
                recipes[index] = updatedRecipe
            }
            if let index = randomRecipes.firstIndex(where: { $0.id == id }) {
                randomRecipes[index] = updatedRecipe
            }
            // Persist updated recipes to cache immediately to avoid stale data after relaunch
            cloudKitManager.recipes = recipes
            cloudKitManager.cacheRecipesSnapshot(recipes, for: source)
            // Also refresh the per-category cache so thumbnails stay in sync when revisiting the list
            let newCategoryRecipes = recipes.filter { $0.categoryID == updatedRecipe.categoryID }
            cloudKitManager.cacheRecipes(newCategoryRecipes, for: source, categoryID: updatedRecipe.categoryID)
            // If the category changed, refresh the old category cache as well
            if let categoryId = categoryId, categoryId != recipe.categoryID {
                let oldCategoryRecipes = recipes.filter { $0.categoryID == recipe.categoryID }
                cloudKitManager.cacheRecipes(oldCategoryRecipes, for: source, categoryID: recipe.categoryID)
            }
            // Nudge the UI to rebuild lists (including search views) with the latest recipe metadata
            recipesRefreshTrigger += 1
            // Refresh from CloudKit without purging local cache first.
            await loadCategories()
            await loadRecipesForCategory()
        }
        
        refreshOfflineState()
        return error == nil
    }
    
#if os(macOS)
    // MARK: - Export (macOS)
    func exportCurrentSourceDocument() async -> RecipeExportDocument? {
        error = nil
        guard let source = currentSource else {
            error = "Select a source before exporting."
            return nil
        }
        
        await loadCategories()
        await cloudKitManager.loadRecipes(for: source, category: nil)
        recipes = cloudKitManager.recipes
        
        let categoryLookup = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.name) })
        
        let exportedCategories = categories
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { ExportedCategory(name: $0.name, icon: $0.icon) }
        
        let exportedRecipes = cloudKitManager.recipes
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .compactMap { recipe -> (ExportedRecipe, String?, Data?)? in
                let imageInfo = loadImageData(for: recipe)
                let imageFilename = imageInfo?.filename
                let imageData = imageInfo?.data
                
                let categoryName = categoryLookup[recipe.categoryID] ?? "Uncategorized"
                let exported = ExportedRecipe(
                    name: recipe.name,
                    recipeTime: recipe.recipeTime,
                    details: recipe.details,
                    categoryName: categoryName,
                    recipeSteps: recipe.recipeSteps,
                    imageFilename: imageFilename
                )
                return (exported, imageFilename, imageData)
            }
        
        var images: [String: Data] = [:]
        let recipes = exportedRecipes.map { tuple in
            if let filename = tuple.1, let data = tuple.2 {
                images[filename] = data
            }
            return tuple.0
        }
        
        let package = RecipeExportPackage(
            categories: exportedCategories,
            recipes: recipes,
        )
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        
        do {
            let data = try encoder.encode(package)
            return RecipeExportDocument(data: data, images: images)
        } catch {
            self.error = "Failed to export recipes: \(error.localizedDescription)"
            return nil
        }
    }
#endif
    
    // MARK: - Import
    func loadImportPreview(from url: URL) -> ImportPreview? {
        do {
            let (data, images) = try loadPackageOrJSON(at: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let package = try decoder.decode(RecipeExportPackage.self, from: data)
            return ImportPreview(url: url, package: package, images: images)
        } catch {
            self.error = "Failed to read import file: \(error.localizedDescription)"
            return nil
        }
    }
    
    func importRecipes(from preview: ImportPreview, selectedRecipes: [ExportedRecipe]) async -> Bool {
        error = nil
        guard let source = currentSource else {
            error = "Select a source before importing."
            return false
        }
        
        isImporting = true
        defer { isImporting = false }
        
        let package = preview.package
        let images = preview.images
        
        await loadCategories()
        
        var categoryIDsByName: [String: CKRecord.ID] = [:]
        for category in categories {
            categoryIDsByName[category.name.lowercased()] = category.id
        }
        
        let selectedCategoryNames = Set(selectedRecipes.map { $0.categoryName.lowercased() })
        
        for exportedCategory in package.categories where selectedCategoryNames.contains(exportedCategory.name.lowercased()) {
            let key = exportedCategory.name.lowercased()
            if categoryIDsByName[key] == nil {
                let created = await createCategory(name: exportedCategory.name, icon: exportedCategory.icon)
                if created,
                   let newCategory = categories.first(where: { $0.name.caseInsensitiveCompare(exportedCategory.name) == .orderedSame }) {
                    categoryIDsByName[key] = newCategory.id
                }
            }
        }
        
        var importedCount = 0
        for recipe in selectedRecipes {
            guard let categoryID = categoryIDsByName[recipe.categoryName.lowercased()] else {
                continue
            }
            let created = await createRecipeWithSteps(
                categoryId: categoryID,
                name: recipe.name,
                recipeTime: recipe.recipeTime,
                details: recipe.details,
                image: recipe.imageFilename.flatMap { images[$0] },
                recipeSteps: recipe.recipeSteps
            )
            if created {
                importedCount += 1
            }
        }
        
        if importedCount == 0 {
            error = "No recipes were imported."
            return false
        }
        
        await cloudKitManager.loadRecipeCounts(for: source)
        recipeCounts = cloudKitManager.recipeCounts
        await loadRandomRecipes()
        refreshOfflineState()
        return true
    }
    
#if os(macOS)
    private func loadImageData(for recipe: Recipe) -> (filename: String, data: Data)? {
        let fm = FileManager.default
        
        if let cachedPath = recipe.cachedImagePath, fm.fileExists(atPath: cachedPath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: cachedPath)) {
            let ext = URL(fileURLWithPath: cachedPath).pathExtension.isEmpty ? "jpg" : URL(fileURLWithPath: cachedPath).pathExtension
            let filename = sanitizedFileComponent("\(recipe.id.recordName).\(ext)")
            return (filename, data)
        }
        
        if let assetURL = recipe.imageAsset?.fileURL,
           let data = try? Data(contentsOf: assetURL) {
            let ext = assetURL.pathExtension.isEmpty ? "jpg" : assetURL.pathExtension
            let filename = sanitizedFileComponent("\(recipe.id.recordName).\(ext)")
            return (filename, data)
        }
        
        return nil
    }
    
    private func sanitizedFileComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(scalars)
    }
#endif
    
    private func loadPackageOrJSON(at url: URL) throws -> (Data, [String: Data]) {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey])
        let isPackage = values?.contentType?.conforms(to: RecipeExportConstants.contentType) == true || url.pathExtension.lowercased() == "icookexport"
        
        if !isPackage {
            return (try Data(contentsOf: url), [:])
        }
        
        let recipesURL = url.appendingPathComponent(RecipeExportConstants.recipesFileName)
        let data = try Data(contentsOf: recipesURL)
        
        let imagesURL = url.appendingPathComponent(RecipeExportConstants.imagesFolderName)
        var images: [String: Data] = [:]
        if FileManager.default.fileExists(atPath: imagesURL.path),
           let fileURLs = try? FileManager.default.contentsOfDirectory(at: imagesURL, includingPropertiesForKeys: nil) {
            for fileURL in fileURLs {
                if let data = try? Data(contentsOf: fileURL) {
                    images[fileURL.lastPathComponent] = data
                }
            }
        }
        
        return (data, images)
    }
    
    // MARK: - Sharing
    func isSourceShared(_ source: Source) -> Bool {
        return cloudKitManager.isSharedSource(source)
    }
    
    func isSharedOwner(_ source: Source) -> Bool {
        return cloudKitManager.isSharedOwner(source)
    }
    
    func canRenameSource(_ source: Source) -> Bool {
        !isOfflineMode && (source.isPersonal || isSharedOwner(source))
    }
    func markSourceSharedLocally(_ source: Source) {
        cloudKitManager.markSourceShared(source)
        sources = cloudKitManager.sources
        if let current = cloudKitManager.currentSource {
            currentSource = current
        }
    }
    func canEditSource(_ source: Source) -> Bool {
        // Allow edits on shared sources once the share is read-write
        return source.isPersonal || cloudKitManager.canEditSharedSources
    }
#if os(macOS)
    func stopSharingSource(_ source: Source) async {
        let success = await cloudKitManager.stopSharingSource(source)
        if success {

            await loadSources()
        }
    }
#endif
    func debugNukeOwnedData() async {
        await cloudKitManager.debugNukeOwnedData()
        await loadSources()
    }
    
    #if os(iOS)
    func clearErrors() {
        error = nil
        cloudKitManager.error = nil
    }
    #endif
    
    func clearLastViewedRecipe() {
        UserDefaults.standard.removeObject(forKey: lastViewedRecipeKey)
        clearAppLocation()
    }
    
}
