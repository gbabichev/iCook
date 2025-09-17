import Foundation
import Combine

@MainActor
final class AppViewModel: ObservableObject {
    @Published var categories: [Category] = []
    @Published var isLoadingCategories = false
    @Published var isLoadingRecipes = false
    @Published var error: String?
    @Published var randomRecipes: [Recipe] = []

    // Computed property for overall loading state if needed
    var isLoading: Bool {
        isLoadingCategories || isLoadingRecipes
    }

    func loadCategories(search: String? = nil) async {
        guard !isLoadingCategories else { return }
        isLoadingCategories = true
        error = nil
        defer { isLoadingCategories = false }

        do {
            let cats = try await APIClient.fetchCategories(q: search)
            categories = cats
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            print("Categories error: \(error)")
        }
    }

    func loadRandomRecipes(count: Int = 6) async {
        guard !isLoadingRecipes else {
            print("Already loading recipes, skipping...")
            return
        }
        
        isLoadingRecipes = true
        defer { isLoadingRecipes = false }
        
        do {
            print("Fetching recipes...")
            let all = try await APIClient.fetchRecipes(page: 1, limit: 100)
            print("Received \(all.count) recipes")
            self.randomRecipes = Array(all.shuffled().prefix(count))
            print("Set \(randomRecipes.count) random recipes")
            // Clear any previous errors on success
            if self.error != nil {
                self.error = nil
            }
        } catch {
            let errorMsg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            print("Random recipes error: \(error)")
            print("Error details: \(errorMsg)")
            
            // Only set error if it's not a cancellation error
            if !errorMsg.contains("cancelled") {
                self.error = errorMsg
            }
        }
    }
    
    func loadRecipesForCategory(_ categoryID: Int, limit: Int = 100) async throws -> [Recipe] {
        do {
            print("Fetching recipes for category ID: \(categoryID)")
            let recipes = try await APIClient.fetchRecipes(categoryID: categoryID, page: 1, limit: limit)
            print("Received \(recipes.count) recipes for category \(categoryID)")
            return recipes
        } catch {
            print("Error fetching recipes for category \(categoryID): \(error)")
            throw error
        }
    }
    
    func createCategory(name: String, icon: String) async -> Bool {
        error = nil
        
        do {
            let newCategory = try await APIClient.createCategory(name: name, icon: icon)
            
            // Add the new category to our list and sort alphabetically
            categories.append(newCategory)
            categories.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            
            return true
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            print("Create category error: \(error)")
            return false
        }
    }
    
    // Add these methods to your AppViewModel class

    @MainActor
    func updateCategory(id: Int, name: String, icon: String) async -> Bool {
        do {
            let updatedCategory = try await APIClient.updateCategory(id: id, name: name, icon: icon)
            
            // Update the category in the local array
            if let index = categories.firstIndex(where: { $0.id == id }) {
                categories[index] = updatedCategory
            }
            
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    @MainActor
    func deleteCategory(id: Int) async {
        do {
            try await APIClient.deleteCategory(id: id)
            
            // Remove the category from the local array
            categories.removeAll { $0.id == id }
            
        } catch {
            self.error = error.localizedDescription
        }
    }
    
}
