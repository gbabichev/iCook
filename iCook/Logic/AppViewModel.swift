import Foundation
import Combine
import CloudKit

@MainActor
final class AppViewModel: ObservableObject {
    @Published var categories: [Category] = []
    @Published var recipes: [Recipe] = []
    @Published var randomRecipes: [Recipe] = []
    @Published var isLoadingCategories = false
    @Published var isLoadingRecipes = false
    @Published var error: String?

    // CloudKit manager
    private let cloudKitManager = CloudKitManager.shared

    // Source management
    @Published var currentSource: Source?
    @Published var sources: [Source] = []

    var isLoading: Bool {
        isLoadingCategories || isLoadingRecipes
    }

    // MARK: - Source Management
    func loadSources() async {
        await cloudKitManager.loadSources()
        sources = cloudKitManager.sources
        currentSource = cloudKitManager.currentSource
    }

    func selectSource(_ source: Source) async {
        cloudKitManager.currentSource = source
        currentSource = source
        await loadCategories()
        await loadRandomRecipes()
    }

    func createSource(name: String) async -> Bool {
        await cloudKitManager.createSource(name: name, isPersonal: true)
        // Copy sources directly from CloudKitManager without re-querying
        // (the new source might not be indexed in CloudKit yet)
        sources = cloudKitManager.sources
        currentSource = cloudKitManager.currentSource
        return true
    }

    func deleteSource(_ source: Source) async -> Bool {
        await cloudKitManager.deleteSource(source)
        // Copy sources directly from CloudKitManager without re-querying
        sources = cloudKitManager.sources
        currentSource = cloudKitManager.currentSource
        return true
    }

    // MARK: - Category Management
    func loadCategories(search: String? = nil) async {
        guard let source = currentSource else { return }
        isLoadingCategories = true
        defer { isLoadingCategories = false }

        await cloudKitManager.loadCategories(for: source)
        categories = cloudKitManager.categories
        error = cloudKitManager.error
    }

    func createCategory(name: String, icon: String) async -> Bool {
        guard let source = currentSource else { return false }
        error = nil

        await cloudKitManager.createCategory(name: name, icon: icon, in: source)
        // Copy directly from CloudKitManager without re-querying
        categories = cloudKitManager.categories
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
        return error == nil
    }

    func deleteCategory(id: CKRecord.ID) async {
        guard let source = currentSource else { return }
        guard let category = categories.first(where: { $0.id == id }) else { return }

        await cloudKitManager.deleteCategory(category, in: source)
        // Copy directly from CloudKitManager without re-querying
        categories = cloudKitManager.categories
    }

    // MARK: - Recipe Management
    func loadRecipesForCategory(_ categoryID: CKRecord.ID) async {
        guard let source = currentSource else { return }
        guard let category = categories.first(where: { $0.id == categoryID }) else { return }

        isLoadingRecipes = true
        defer { isLoadingRecipes = false }

        await cloudKitManager.loadRecipes(for: source, category: category)
        recipes = cloudKitManager.recipes
        error = cloudKitManager.error
    }

    func loadRandomRecipes(count: Int = 20) async {
        guard let source = currentSource else { return }
        guard !isLoadingRecipes else { return }

        isLoadingRecipes = true
        defer { isLoadingRecipes = false }

        await cloudKitManager.loadRandomRecipes(for: source, count: count)
        randomRecipes = cloudKitManager.recipes
        error = cloudKitManager.error
    }

    func searchRecipes(query: String) async {
        guard let source = currentSource else { return }

        isLoadingRecipes = true
        defer { isLoadingRecipes = false }

        await cloudKitManager.searchRecipes(in: source, query: query)
        recipes = cloudKitManager.recipes
        error = cloudKitManager.error
    }

    func deleteRecipe(id: CKRecord.ID) async -> Bool {
        guard let source = currentSource else { return false }
        guard let recipe = recipes.first(where: { $0.id == id }) else { return false }

        await cloudKitManager.deleteRecipe(recipe, in: source)

        recipes.removeAll { $0.id == id }
        randomRecipes.removeAll { $0.id == id }

        NotificationCenter.default.post(name: .recipeDeleted, object: id as CKRecord.ID)
        return true
    }

    func deleteRecipeWithUIFeedback(id: CKRecord.ID) async -> Bool {
        let success = await deleteRecipe(id: id)
        return success
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

        let recipe = Recipe(
            id: CKRecord.ID(),
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
            if let asset = await cloudKitManager.saveImage(imageData, for: recipe, in: source) {
                recipeWithImage.imageAsset = asset
            }
        }

        await cloudKitManager.createRecipe(recipeWithImage, in: source)
        recipes.insert(recipeWithImage, at: 0)
        error = cloudKitManager.error
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
        guard let source = currentSource else { return false }
        guard let recipe = recipes.first(where: { $0.id == id }) else { return false }

        isLoadingRecipes = true
        defer { isLoadingRecipes = false }

        var updatedRecipe = recipe
        if let name = name { updatedRecipe.name = name }
        if let recipeTime = recipeTime { updatedRecipe.recipeTime = recipeTime }
        if let details = details { updatedRecipe.details = details }
        if let categoryId = categoryId { updatedRecipe.categoryID = categoryId }
        if let recipeSteps = recipeSteps { updatedRecipe.recipeSteps = recipeSteps }

        // Handle image if provided
        if let imageData = image {
            if let asset = await cloudKitManager.saveImage(imageData, for: updatedRecipe, in: source) {
                updatedRecipe.imageAsset = asset
            }
        }

        await cloudKitManager.updateRecipe(updatedRecipe, in: source)

        if let index = recipes.firstIndex(where: { $0.id == id }) {
            recipes[index] = updatedRecipe
        }
        if let index = randomRecipes.firstIndex(where: { $0.id == id }) {
            randomRecipes[index] = updatedRecipe
        }

        error = cloudKitManager.error
        return error == nil
    }

    // MARK: - Sharing
    func prepareShareForSource(_ source: Source) async -> CKShare? {
        return await cloudKitManager.prepareShareForSource(source)
    }

    // MARK: - Debug
    func debugDeleteAllSourcesAndReset() async {
        await cloudKitManager.debugDeleteAllSourcesAndReset()
    }
}
