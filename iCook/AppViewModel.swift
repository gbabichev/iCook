import Foundation
import Combine

@MainActor
final class AppViewModel: ObservableObject {
    @Published var categories: [Category] = []
    @Published var selectedCategoryID: Category.ID?
    @Published var isLoading = false
    @Published var error: String?
    @Published var randomRecipes: [Recipe] = []

    func loadCategories(search: String? = nil) async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let cats = try await APIClient.fetchCategories(q: search)
            categories = cats
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            print("Categories error: \(error)")
        }
    }

    func selectCategory(_ id: Category.ID?) {
        selectedCategoryID = id
    }

    func loadRandomRecipes(count: Int = 6) async {
        isLoading = true
        defer { isLoading = false } // Fix: Uncomment this line
        
        do {
            print("Fetching recipes...")
            let all = try await APIClient.fetchRecipes(page: 1, limit: 100)
            print("Received \(all.count) recipes")
            self.randomRecipes = Array(all.shuffled().prefix(count))
            print("Set \(randomRecipes.count) random recipes")
        } catch {
            let errorMsg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            self.error = errorMsg
            print("Random recipes error: \(error)")
            print("Error details: \(errorMsg)")
        }
    }
}
