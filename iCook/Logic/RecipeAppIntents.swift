#if os(macOS) || os(iOS)
import AppIntents
import CloudKit
import CoreSpotlight
import Foundation
import FoundationModels

// MARK: - Siri and Shortcuts recipe actions

enum RecipeSystemSearchRequest {
    nonisolated static let defaultsKey = "PendingSystemRecipeSearch"
    nonisolated static let notification = Notification.Name("PendingSystemRecipeSearchChanged")
}

@available(iOS 27.0, macOS 27.0, *)
struct RecipeIntentEntity: IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Recipe")
    static let defaultQuery = RecipeIntentEntityQuery()

    let id: String

    @Property(title: "Name")
    var name: String

    @Property(title: "Collection")
    var collectionName: String

    @Property(title: "Category")
    var categoryName: String

    @Property(title: "Cooking Time")
    var cookingTimeMinutes: Int

    @Property(title: "Ingredients")
    var ingredients: [String]

    @Property(title: "Instructions")
    var instructions: [String]

    @Property(title: "Notes")
    var notes: String

    init(
        id: String,
        name: String,
        collectionName: String,
        categoryName: String,
        cookingTimeMinutes: Int,
        ingredients: [String],
        instructions: [String],
        notes: String
    ) {
        self.id = id
        self.name = name
        self.collectionName = collectionName
        self.categoryName = categoryName
        self.cookingTimeMinutes = cookingTimeMinutes
        self.ingredients = ingredients
        self.instructions = instructions
        self.notes = notes
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(collectionName) · \(cookingTimeMinutes) min",
            image: .init(systemName: "fork.knife")
        )
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct RecipeCategoryIntentEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Recipe Category")
    static let defaultQuery = RecipeCategoryIntentEntityQuery()

    let id: String

    @Property(title: "Name")
    var name: String

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            image: .init(systemName: "folder")
        )
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct RecipeCategoryIntentEntityQuery: EntityStringQuery {
    func entities(for identifiers: [RecipeCategoryIntentEntity.ID]) async throws -> [RecipeCategoryIntentEntity] {
        let wanted = Set(identifiers)
        return await RecipeIntentStore.defaultCategoryEntities().filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [RecipeCategoryIntentEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return try await suggestedEntities() }

        return await RecipeIntentStore.defaultCategoryEntities().filter {
            $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    func suggestedEntities() async throws -> [RecipeCategoryIntentEntity] {
        await RecipeIntentStore.defaultCategoryEntities()
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct RecipeIntentEntityQuery: EntityStringQuery, IndexedEntityQuery {
    func entities(for identifiers: [RecipeIntentEntity.ID]) async throws -> [RecipeIntentEntity] {
        let wanted = Set(identifiers)
        return await RecipeIntentStore.allEntities().filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [RecipeIntentEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return try await suggestedEntities() }

        return await RecipeIntentStore.allEntities().filter { entity in
            entity.name.localizedCaseInsensitiveContains(query)
                || entity.categoryName.localizedCaseInsensitiveContains(query)
                || entity.collectionName.localizedCaseInsensitiveContains(query)
                || entity.ingredients.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    func suggestedEntities() async throws -> [RecipeIntentEntity] {
        Array(await RecipeIntentStore.allEntities().prefix(20))
    }

    func reindexEntities(
        for identifiers: [RecipeIntentEntity.ID],
        indexDescription: CSSearchableIndexDescription
    ) async throws {
        let entities = try await entities(for: identifiers)
        try await CSSearchableIndex(name: RecipeIntentIndexer.indexName).indexAppEntities(entities)
    }

    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        try await RecipeIntentIndexer.refresh()
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct ReadRecipeIntent: AppIntent {
    static let title: LocalizedStringResource = "Read Recipe"
    static let description = IntentDescription("Reads the ingredients and instructions for a recipe in iCook.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Recipe", requestValueDialog: "Which recipe would you like me to read?")
    var recipe: RecipeIntentEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Read \(\.$recipe)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<RecipeIntentEntity> {
        let ingredientText = recipe.ingredients.isEmpty
            ? "No ingredients are listed."
            : "Ingredients: " + recipe.ingredients.joined(separator: ", ") + "."
        let instructionText = recipe.instructions.isEmpty
            ? "No instructions are listed."
            : "Instructions: " + recipe.instructions.enumerated().map { index, instruction in
                "Step \(index + 1), \(instruction)"
            }.joined(separator: " ")

        return .result(
            value: recipe,
            dialog: IntentDialog("\(recipe.name). \(ingredientText) \(instructionText)")
        )
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct FindRecipesIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Recipes"
    static let description = IntentDescription("Finds recipes in iCook by name, collection, category, or ingredient.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Search", requestValueDialog: "What recipe or ingredient should I look for?")
    var search: String

    static var parameterSummary: some ParameterSummary {
        Summary("Find recipes matching \(\.$search)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[RecipeIntentEntity]> {
        let matches = try await RecipeIntentEntityQuery().entities(matching: search)
        let limitedMatches = Array(matches.prefix(10))
        let dialog: IntentDialog

        if limitedMatches.isEmpty {
            dialog = "I couldn't find any matching recipes in iCook."
        } else if limitedMatches.count == 1 {
            dialog = "I found \(limitedMatches[0].name)."
        } else {
            dialog = "I found \(limitedMatches.count) recipes: \(limitedMatches.map(\.name).joined(separator: ", "))."
        }

        return .result(value: limitedMatches, dialog: dialog)
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .system.searchInApp)
struct SearchRecipesInAppIntent: ShowInAppSearchResultsIntent {
    static let title: LocalizedStringResource = "Search iCook"
    static let description = IntentDescription("Opens iCook and searches the default collection for recipes.")

    var criteria: StringSearchCriteria

    func perform() async throws -> some IntentResult {
        let searchTerm = criteria.term
        await MainActor.run {
            UserDefaults.standard.set(searchTerm, forKey: RecipeSystemSearchRequest.defaultsKey)
            NotificationCenter.default.post(
                name: RecipeSystemSearchRequest.notification,
                object: searchTerm
            )
        }
        return .result()
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct GenerateRecipeIntent: AppIntent {
    static let title: LocalizedStringResource = "Generate Recipe"
    static let description = IntentDescription("Generates a new recipe and saves it to iCook after confirmation.")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "Request", requestValueDialog: "What kind of recipe should I create?")
    var request: String

    @Parameter(title: "Category", requestValueDialog: "Which category should I use?")
    var category: RecipeCategoryIntentEntity?

    static var parameterSummary: some ParameterSummary {
        When(\.$category, .hasAnyValue) {
            Summary("Generate \(\.$request) in \(\.$category)")
        } otherwise: {
            Summary("Generate \(\.$request)")
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<RecipeIntentEntity> {
        let destination = try await RecipeIntentStore.destination(category: category)
        let draft = try await GeneratedRecipeDraft.generate(from: request)

        try await requestConfirmation(
            conditions: [],
            actionName: .create,
            dialog: "Create \(draft.name) in the \(destination.category.name) category of \(destination.source.name)?"
        )

        let entity = try await RecipeIntentStore.create(
            draft: draft,
            source: destination.source,
            category: destination.category
        )
        try await RecipeIntentIndexer.index(entity)

        return .result(
            value: entity,
            dialog: "I created \(entity.name) in \(entity.collectionName)."
        )
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct iCookAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GenerateRecipeIntent(),
            phrases: [
                "Generate a recipe in \(.applicationName)",
                "Create a recipe with \(.applicationName)",
                "Generate a recipe in \(\.$category) with \(.applicationName)",
                "Create a recipe in \(\.$category) using \(.applicationName)"
            ],
            shortTitle: "Generate Recipe",
            systemImageName: "sparkles"
        )

        AppShortcut(
            intent: ReadRecipeIntent(),
            phrases: [
                "Read \(\.$recipe) in \(.applicationName)",
                "What is the recipe for \(\.$recipe) in \(.applicationName)"
            ],
            shortTitle: "Read Recipe",
            systemImageName: "text.book.closed"
        )

        AppShortcut(
            intent: FindRecipesIntent(),
            phrases: [
                "Find recipes in \(.applicationName)",
                "Search recipes in \(.applicationName)"
            ],
            shortTitle: "Find Recipes",
            systemImageName: "magnifyingglass"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .orange
}

@available(iOS 27.0, macOS 27.0, *)
@Generable(description: "A complete, practical cooking recipe.")
private struct GeneratedRecipeDraft {
    @Guide(description: "A concise recipe name.")
    var name: String

    @Guide(description: "The total preparation and cooking time in minutes.")
    var cookingTimeMinutes: Int

    @Guide(description: "A short description with useful serving or food-safety notes.")
    var details: String

    @Guide(description: "Ordered cooking steps. Every ingredient should appear in at least one step.")
    var steps: [GeneratedRecipeStep]

    static func generate(from request: String) async throws -> GeneratedRecipeDraft {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw RecipeIntentError.modelUnavailable
        }

        let session = LanguageModelSession(
            model: model,
            instructions: """
            You create clear, practical home-cooking recipes. Use common measurements, realistic timing, and safe minimum cooking temperatures when relevant. Return a complete recipe with ordered steps. Put the ingredients used by each step on that step. Do not claim that generated dietary or allergen information is guaranteed.
            """
        )
        let response = try await session.respond(to: request, generating: GeneratedRecipeDraft.self)
        return response.content
    }
}

@available(iOS 27.0, macOS 27.0, *)
@Generable(description: "One ordered recipe step and the ingredients used in that step.")
private struct GeneratedRecipeStep {
    @Guide(description: "A direct cooking instruction without a step number.")
    var instruction: String

    @Guide(description: "Ingredients with quantities used in this step.")
    var ingredients: [String]
}

@available(iOS 27.0, macOS 27.0, *)
@MainActor
private enum RecipeIntentStore {
    struct Destination {
        let source: Source
        let category: Category
    }

    private struct Record {
        let recipe: Recipe
        let source: Source
        let categoryName: String

        var entity: RecipeIntentEntity {
            RecipeIntentEntity(
                id: RecipeIntentStore.identifier(for: recipe.id),
                name: recipe.name,
                collectionName: source.name,
                categoryName: categoryName,
                cookingTimeMinutes: recipe.recipeTime,
                ingredients: recipe.ingredients ?? [],
                instructions: recipe.recipeSteps.sorted { $0.stepNumber < $1.stepNumber }.map(\.instruction),
                notes: recipe.details ?? ""
            )
        }
    }

    static func allEntities() async -> [RecipeIntentEntity] {
        await allRecords().map(\.entity)
    }

    static func defaultCategoryEntities() async -> [RecipeCategoryIntentEntity] {
        let manager = CloudKitManager.shared
        await manager.loadSources()

        guard let source = defaultEditableSource(using: manager) else { return [] }
        let snapshot = await manager.exportSnapshot(for: source)
        return snapshot.categories.map {
            RecipeCategoryIntentEntity(id: identifier(for: $0.id), name: $0.name)
        }
    }

    static func destination(category requestedCategory: RecipeCategoryIntentEntity?) async throws -> Destination {
        let manager = CloudKitManager.shared
        await manager.loadSources()

        guard let source = defaultEditableSource(using: manager) else {
            throw RecipeIntentError.noEditableCollection
        }

        let snapshot = await manager.exportSnapshot(for: source)
        let category: Category
        if let requestedCategory {
            guard let match = snapshot.categories.first(where: {
                identifier(for: $0.id) == requestedCategory.id
            }) else {
                throw RecipeIntentError.categoryNotFound(requestedCategory.name, source.name)
            }
            category = match
        } else if let first = snapshot.categories.first {
            category = first
        } else {
            throw RecipeIntentError.noCategory(source.name)
        }

        return Destination(source: source, category: category)
    }

    private static func defaultEditableSource(using manager: CloudKitManager) -> Source? {
        let editableSources = manager.sources.filter {
            $0.isPersonal || manager.isSharedOwner($0) || manager.canEditSharedSource($0)
        }

        if let current = manager.currentSource,
           editableSources.contains(where: { $0.id == current.id }) {
            return current
        }
        return editableSources.first
    }

    static func create(
        draft: GeneratedRecipeDraft,
        source: Source,
        category: Category
    ) async throws -> RecipeIntentEntity {
        let manager = CloudKitManager.shared
        manager.error = nil

        let steps = draft.steps.enumerated().map { index, step in
            RecipeStep(
                stepNumber: index + 1,
                instruction: step.instruction,
                ingredients: step.ingredients
            )
        }
        let recipe = Recipe(
            id: manager.makeRecordID(for: source),
            sourceID: source.id,
            categoryID: category.id,
            name: draft.name,
            recipeTime: max(0, draft.cookingTimeMinutes),
            details: draft.details,
            recipeSteps: steps
        )

        await manager.createRecipe(recipe, in: source)
        if let error = manager.error {
            throw RecipeIntentError.saveFailed(error)
        }

        return RecipeIntentEntity(
            id: identifier(for: recipe.id),
            name: recipe.name,
            collectionName: source.name,
            categoryName: category.name,
            cookingTimeMinutes: recipe.recipeTime,
            ingredients: recipe.ingredients ?? [],
            instructions: recipe.recipeSteps.map(\.instruction),
            notes: recipe.details ?? ""
        )
    }

    private static func allRecords() async -> [Record] {
        let manager = CloudKitManager.shared
        await manager.loadSources()
        let sources = manager.sources
        var records: [Record] = []

        for source in sources {
            let snapshot = await manager.exportSnapshot(for: source)
            let categoryNames = Dictionary(uniqueKeysWithValues: snapshot.categories.map { ($0.id, $0.name) })
            records.append(contentsOf: snapshot.recipes.map { recipe in
                Record(
                    recipe: recipe,
                    source: source,
                    categoryName: categoryNames[recipe.categoryID] ?? "Uncategorized"
                )
            })
        }

        return records.sorted {
            $0.recipe.name.localizedCaseInsensitiveCompare($1.recipe.name) == .orderedAscending
        }
    }

    fileprivate static func identifier(for id: CKRecord.ID) -> String {
        [id.zoneID.ownerName, id.zoneID.zoneName, id.recordName]
            .map { Data($0.utf8).base64EncodedString() }
            .joined(separator: ".")
    }
}

@available(iOS 27.0, macOS 27.0, *)
enum RecipeIntentIndexer {
    static let indexName = "iCookRecipes"

    @MainActor
    static func refresh() async throws {
        let entities = await RecipeIntentStore.allEntities()
        let index = CSSearchableIndex(name: indexName)
        try await index.deleteAllSearchableItems()
        try await index.indexAppEntities(entities)
    }

    static func index(_ entity: RecipeIntentEntity) async throws {
        try await CSSearchableIndex(name: indexName).indexAppEntities([entity])
    }

    static func index(
        _ recipe: Recipe,
        in source: Source,
        categoryName: String
    ) async throws {
        let entity = RecipeIntentEntity(
            id: RecipeIntentStore.identifier(for: recipe.id),
            name: recipe.name,
            collectionName: source.name,
            categoryName: categoryName,
            cookingTimeMinutes: recipe.recipeTime,
            ingredients: recipe.ingredients ?? [],
            instructions: recipe.recipeSteps.sorted { $0.stepNumber < $1.stepNumber }.map(\.instruction),
            notes: recipe.details ?? ""
        )
        try await index(entity)
    }

    static func remove(_ recipeID: CKRecord.ID) async throws {
        let identifier = RecipeIntentStore.identifier(for: recipeID)
        try await CSSearchableIndex(name: indexName).deleteAppEntities(
            identifiedBy: [identifier],
            ofType: RecipeIntentEntity.self
        )
    }
}

private enum RecipeIntentError: LocalizedError {
    case modelUnavailable
    case noEditableCollection
    case categoryNotFound(String, String)
    case noCategory(String)
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelUnavailable:
            "Recipe generation requires Apple Intelligence to be available on this Mac."
        case .noEditableCollection:
            "iCook could not find an editable recipe collection."
        case .categoryNotFound(let category, let collection):
            "iCook could not find the \(category) category in \(collection)."
        case .noCategory(let collection):
            "Create a category in \(collection) before generating a recipe."
        case .saveFailed(let message):
            "iCook could not save the recipe: \(message)"
        }
    }
}
#endif
