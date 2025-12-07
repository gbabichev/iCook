import Foundation
import Combine
import CloudKit
#if os(macOS)
import UniformTypeIdentifiers
#endif

@MainActor
final class AppViewModel: ObservableObject {
    @Published var categories: [Category] = []
    @Published var recipes: [Recipe] = []
    @Published var randomRecipes: [Recipe] = []
    @Published var recipeCounts: [CKRecord.ID: Int] = [:]
    @Published var isLoadingCategories = false
    @Published var isLoadingRecipes = false
#if os(macOS)
    @Published var isImporting = false
#endif
    @Published var error: String?
    @Published var isOfflineMode = false
    private let lastViewedRecipeKey = "LastViewedRecipe"
    
    // CloudKit manager
    let cloudKitManager = CloudKitManager.shared
    
    // Source management
    @Published var currentSource: Source?
    @Published var sources: [Source] = []
    @Published var sourceSelectionStamp = UUID()
    
    init() {
        // Prime from cached manager state so UI doesn't start empty when offline/online
        sources = cloudKitManager.sources
        currentSource = cloudKitManager.currentSource
        if let source = currentSource {
            cloudKitManager.loadCachedData(for: source)
            categories = cloudKitManager.categories
            recipeCounts = cloudKitManager.recipeCounts
            recipes = cloudKitManager.recipes
            randomRecipes = recipes
        }
        
        NotificationCenter.default.addObserver(
            forName: .recipesRefreshed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.recipes = self.cloudKitManager.recipes
                self.randomRecipes = self.cloudKitManager.recipes
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: .sourcesRefreshed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.sources = self.cloudKitManager.sources
                if let current = self.cloudKitManager.currentSource {
                    self.currentSource = current
                } else if !self.sources.isEmpty {
                    self.currentSource = self.sources.first
                } else {
                    self.currentSource = nil
                }
            }
        }
    }
    
    private func refreshOfflineState() {
        isOfflineMode = !cloudKitManager.isCloudKitAvailable || cloudKitManager.isOfflineMode
    }
    
    // MARK: - Source Management
    func loadSources() async {
        await cloudKitManager.loadSources()
        sources = cloudKitManager.sources
        currentSource = cloudKitManager.currentSource
        refreshOfflineState()
    }
    
    func selectSource(_ source: Source) async {
        cloudKitManager.currentSource = source
        cloudKitManager.saveCurrentSourceID()
        currentSource = source
        sourceSelectionStamp = UUID()
        await loadCategories()
        await loadRandomRecipes(skipCache: true)
        refreshOfflineState()
    }
    
    func createSource(name: String) async -> Bool {
        await cloudKitManager.createSource(name: name, isPersonal: true)
        // Copy sources directly from CloudKitManager without re-querying
        // (the new source might not be indexed in CloudKit yet)
        sources = cloudKitManager.sources
        currentSource = cloudKitManager.currentSource
        cloudKitManager.saveCurrentSourceID()
        refreshOfflineState()
        return true
    }
    
    func deleteSource(_ source: Source) async -> Bool {
        await cloudKitManager.deleteSource(source)
        // Copy sources directly from CloudKitManager without re-querying
        sources = cloudKitManager.sources
        currentSource = cloudKitManager.currentSource
        cloudKitManager.saveCurrentSourceID()
        refreshOfflineState()
        return true
    }
    
    func renameSource(_ source: Source, newName: String) async -> Bool {
        await cloudKitManager.updateSource(source, newName: newName)
        sources = cloudKitManager.sources
        if let updated = sources.first(where: { $0.id == source.id }) {
            currentSource = updated
            cloudKitManager.currentSource = updated
        } else {
            currentSource = cloudKitManager.currentSource
        }
        cloudKitManager.saveCurrentSourceID()
        refreshOfflineState()
        return cloudKitManager.error == nil
    }
#if os (iOS)
    func removeSharedSourceLocally(_ source: Source) async {
        await cloudKitManager.removeSharedSourceLocally(source)
        sources = cloudKitManager.sources
        if currentSource?.id == source.id {
            currentSource = sources.first
            cloudKitManager.saveCurrentSourceID()
            if let newSource = currentSource {
                await selectSource(newSource)
                return
            } else {
                categories.removeAll()
                recipes.removeAll()
                recipeCounts.removeAll()
            }
        }
        refreshOfflineState()
    }
#else
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
                recipes.removeAll()
                recipeCounts.removeAll()
            }
        }
        refreshOfflineState()
    }
#endif
    
    func acceptShareURL(_ url: URL) async -> Bool {
        let success = await cloudKitManager.acceptShare(from: url)
        sources = cloudKitManager.sources
        currentSource = cloudKitManager.currentSource
        refreshOfflineState()
        if success, let source = currentSource {
            await loadCategories()
            await loadRandomRecipes()
            printD("DEBUG: Loaded categories and random recipes for shared source \(source.name)")
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
        await cloudKitManager.loadRecipeCounts(for: source)
        recipeCounts = cloudKitManager.recipeCounts
        error = cloudKitManager.error
        refreshOfflineState()
        isLoadingCategories = false
    }
    
    func createCategory(name: String, icon: String) async -> Bool {
        guard let source = currentSource else { return false }
        error = nil
        
        await cloudKitManager.createCategory(name: name, icon: icon, in: source)
        // Copy directly from CloudKitManager without re-querying
        categories = cloudKitManager.categories
        recipeCounts = cloudKitManager.recipeCounts
        refreshOfflineState()
        return error == nil
    }
    
    func updateCategory(id: CKRecord.ID, name: String, icon: String) async -> Bool {
        guard let source = currentSource else { return false }
        guard let category = categories.first(where: { $0.id == id }) else { return false }
        
        var updatedCategory = category
        updatedCategory.name = name
        updatedCategory.icon = icon
        
        await cloudKitManager.updateCategory(updatedCategory, in: source)
        // Copy directly from CloudKitManager without re-querying
        categories = cloudKitManager.categories
        recipeCounts = cloudKitManager.recipeCounts
        refreshOfflineState()
        return error == nil
    }
    
    func deleteCategory(id: CKRecord.ID) async {
        guard let source = currentSource else { return }
        guard let category = categories.first(where: { $0.id == id }) else { return }
        
        await cloudKitManager.deleteCategory(category, in: source)
        // Copy directly from CloudKitManager without re-querying
        categories = cloudKitManager.categories
        recipeCounts = cloudKitManager.recipeCounts
        refreshOfflineState()
    }
    
    // MARK: - Recipe Management
    func loadRecipesForCategory(_ categoryID: CKRecord.ID, skipCache: Bool = false) async {
        guard let source = currentSource else {
            printD("loadRecipesForCategory: No current source")
            return
        }
        guard let category = categories.first(where: { $0.id == categoryID }) else {
            printD("loadRecipesForCategory: Category not found: \(categoryID)")
            return
        }
        
        printD("loadRecipesForCategory: Loading recipes for \(category.name)")
        isLoadingRecipes = true
        
        await cloudKitManager.loadRecipes(for: source, category: category, skipCache: skipCache)
        recipes = cloudKitManager.recipes
        // Also keep randomRecipes in sync so names stay consistent across home/category
        randomRecipes = cloudKitManager.recipes
        error = cloudKitManager.error
        printD("loadRecipesForCategory: Loaded \(recipes.count) recipes for \(category.name)")
        refreshOfflineState()
        isLoadingRecipes = false
    }
    
    func loadRandomRecipes(skipCache: Bool = false) async {
        guard let source = currentSource else { return }
        guard !isLoadingRecipes else { return }
        
        isLoadingRecipes = true
        
        await cloudKitManager.loadRandomRecipes(for: source, skipCache: skipCache)
        randomRecipes = cloudKitManager.recipes
        // Keep the main recipes array in sync so category views pick up latest names
        recipes = cloudKitManager.recipes
        error = cloudKitManager.error
        refreshOfflineState()
        isLoadingRecipes = false
    }
    
    func deleteRecipe(id: CKRecord.ID) async -> Bool {
        printD("deleteRecipe: Called with recipe ID: \(id.recordName)")
        
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
        await cloudKitManager.deleteRecipe(recipe, in: source)
        printD("deleteRecipe: CloudKit deletion completed")
        
        // Remove from the local recipes array immediately
        printD("deleteRecipe: Removing recipe from local arrays. Before: recipes=\(self.recipes.count), randomRecipes=\(self.randomRecipes.count)")
        self.recipes = recipes.filter { $0.id != id }
        randomRecipes.removeAll { $0.id == id }
        let oldCount = recipeCounts[recipe.categoryID, default: 1]
        recipeCounts[recipe.categoryID] = max(oldCount - 1, 0)
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
    
    func loadLastViewedRecipeID() -> (recipeID: CKRecord.ID, sourceID: CKRecord.ID, categoryID: CKRecord.ID?)? {
        guard let dict = UserDefaults.standard.dictionary(forKey: lastViewedRecipeKey) as? [String: String],
              let recipeRecord = dict["recipeRecordName"],
              let recipeZone = dict["recipeZoneName"],
              let recipeOwner = dict["recipeZoneOwner"],
              let sourceRecord = dict["sourceRecordName"],
              let sourceZone = dict["sourceZoneName"],
              let sourceOwner = dict["sourceZoneOwner"] else {
            return nil
        }
        let recipeZoneID = CKRecordZone.ID(zoneName: recipeZone, ownerName: recipeOwner)
        let recipeID = CKRecord.ID(recordName: recipeRecord, zoneID: recipeZoneID)
        let sourceZoneID = CKRecordZone.ID(zoneName: sourceZone, ownerName: sourceOwner)
        let sourceID = CKRecord.ID(recordName: sourceRecord, zoneID: sourceZoneID)
        if let catRecord = dict["categoryRecordName"],
           let catZone = dict["categoryZoneName"],
           let catOwner = dict["categoryZoneOwner"] {
            let catZoneID = CKRecordZone.ID(zoneName: catZone, ownerName: catOwner)
            let catID = CKRecord.ID(recordName: catRecord, zoneID: catZoneID)
            return (recipeID, sourceID, catID)
        }
        return (recipeID, sourceID, nil)
    }
    
    func createRecipeWithSteps(
        categoryId: CKRecord.ID,
        name: String,
        recipeTime: Int?,
        details: String?,
        image: Data?,
        recipeSteps: [RecipeStep]?
    ) async -> Bool {
        guard let source = currentSource else { return false }
        
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
            recipeSteps: recipeSteps ?? []
        )
        
        // Handle image if provided
        var recipeWithImage = recipe
        if let imageData = image {
            if let result = await cloudKitManager.saveImage(imageData, for: recipe) {
                recipeWithImage.imageAsset = result.asset
                recipeWithImage.cachedImagePath = result.cachedPath
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
        recipeSteps: [RecipeStep]?
    ) async -> Bool {
        guard let source = currentSource else {
            printD("DEBUG: updateRecipeWithSteps failed - no currentSource")
            return false
        }
        
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
        updatedRecipe.lastModified = Date()
        if let name = name { updatedRecipe.name = name }
        if let recipeTime = recipeTime { updatedRecipe.recipeTime = recipeTime }
        if let details = details { updatedRecipe.details = details }
        if let categoryId = categoryId { updatedRecipe.categoryID = categoryId }
        if let recipeSteps = recipeSteps { updatedRecipe.recipeSteps = recipeSteps }
        
        // Handle image if provided
        if let imageData = image {
            // Clear any old cached variants before saving a new one
            cloudKitManager.purgeCachedImages(for: recipe.id)
            if let result = await cloudKitManager.saveImage(imageData, for: updatedRecipe) {
                updatedRecipe.imageAsset = result.asset
                updatedRecipe.cachedImagePath = result.cachedPath
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
            // Force refresh from CloudKit to pull latest fields and bust stale cache
            await loadCategories()
            await loadRecipesForCategory(updatedRecipe.categoryID, skipCache: true)
        }
        
        refreshOfflineState()
        return error == nil
    }
    
#if os(macOS)
    // MARK: - Import/Export (macOS)
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
    
    func importRecipes(from url: URL) async -> Bool {
        error = nil
        guard let source = currentSource else {
            error = "Select a source before importing."
            return false
        }
        
        isImporting = true
        defer { isImporting = false }
        
        do {
            let (data, images) = try loadPackageOrJSON(at: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let package = try decoder.decode(RecipeExportPackage.self, from: data)
            
            await loadCategories()
            
            var categoryIDsByName: [String: CKRecord.ID] = [:]
            for category in categories {
                categoryIDsByName[category.name.lowercased()] = category.id
            }
            
            for exportedCategory in package.categories {
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
            for recipe in package.recipes {
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
        } catch {
            self.error = "Failed to import recipes: \(error.localizedDescription)"
            return false
        }
    }
    
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
#endif
    
    // MARK: - Sharing
    func isSourceShared(_ source: Source) -> Bool {
        return cloudKitManager.isSharedSource(source)
    }
    
    func isSharedOwner(_ source: Source) -> Bool {
        return cloudKitManager.isSharedOwner(source)
    }
    
    func canRenameSource(_ source: Source) -> Bool {
        return source.isPersonal || isSharedOwner(source)
    }
#if os(iOS)
    func markSourceSharedLocally(_ source: Source) {
        cloudKitManager.markSourceShared(source)
        sources = cloudKitManager.sources
        if let current = cloudKitManager.currentSource {
            currentSource = current
        }
    }
#endif
    func canEditSource(_ source: Source) -> Bool {
        // Allow edits on shared sources once the share is read-write
        return source.isPersonal || cloudKitManager.canEditSharedSources
    }
    func stopSharingSource(_ source: Source) async {
        let success = await cloudKitManager.stopSharingSource(source)
        if success {
#if os(iOS)
            cloudKitManager.markSourceUnshared(source)
#endif
            await loadSources()
        }
    }
    func debugNukeOwnedData() async {
        await cloudKitManager.debugNukeOwnedData()
        await loadSources()
    }
    
    func clearErrors() {
        error = nil
        cloudKitManager.error = nil
    }
    
    func clearLastViewedRecipe() {
        UserDefaults.standard.removeObject(forKey: lastViewedRecipeKey)
    }
    
}
