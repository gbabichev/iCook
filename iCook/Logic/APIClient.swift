import Foundation

// MARK: - Models

public struct Category: Identifiable, Codable, Hashable {
    public let id: Int
    public let name: String
    public let icon: String
}

public struct Recipe: Identifiable, Codable, Hashable {
    public let id: Int
    public let category_id: Int
    public let name: String
    public let recipe_time: Int
    public let details: String?
    public let image: String?
}

public struct Page<T: Codable>: Codable {
    public let data: [T]
    public let page: Int
    public let limit: Int
    public let total: Int
    public let query: String?
}

// MARK: - Errors

public enum APIError: LocalizedError {
    case badURL
    case badStatus(Int, String)
    case decoding(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .badURL: return "Invalid API URL."
        case .badStatus(let code, let body): return "HTTP \(code): \(body)"
        case .decoding(let msg): return "Decoding error: \(msg)"
        case .transport(let msg): return "Network error: \(msg)"
        }
    }
}

// MARK: - Config

public struct APIConfig {
    /// Replace with your server. Keep the full script path (api.php).
    /// Example: https://georgebabichev.com:8443/api.php
    public static var base = URL(string: "https://georgebabichev.com:8443/api.php")!
}

// MARK: - Client

public enum APIClient {
    private static func makeURL(route: String, extraQuery: [URLQueryItem] = []) throws -> URL {
        var comps = URLComponents(url: APIConfig.base, resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "route", value: route)]
        items.append(contentsOf: extraQuery)
        comps?.queryItems = items
        guard let url = comps?.url else { throw APIError.badURL }
        return url
    }

    public static func fetchCategories(q: String? = nil,
                                       page: Int = 1,
                                       limit: Int = 100) async throws -> [Category] {
        var query: [URLQueryItem] = [
            .init(name: "page", value: String(page)),
            .init(name: "limit", value: String(limit))
        ]
        if let q, !q.isEmpty { query.append(.init(name: "q", value: q)) }

        let url = try makeURL(route: "/categories", extraQuery: query)
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.transport("No HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? "<no body>"
                throw APIError.badStatus(http.statusCode, body)
            }
            do {
                let page = try JSONDecoder().decode(Page<Category>.self, from: data)
                return page.data
            } catch {
                throw APIError.decoding(error.localizedDescription)
            }
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
    }
    
    public static func createCategory(name: String, icon: String) async throws -> Category {
        let url = try makeURL(route: "/categories")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let categoryData = [
            "name": name,
            "icon": icon
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: categoryData)
        } catch {
            throw APIError.transport("Failed to encode category data: \(error.localizedDescription)")
        }
        
        print("Creating category: \(name) with icon: \(icon)")
        print("Request URL: \(url)")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.transport("No HTTP response")
            }
            
            print("Create category HTTP Status: \(http.statusCode)")
            
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? "<no body>"
                print("Create category error response body: \(body)")
                throw APIError.badStatus(http.statusCode, body)
            }
            
            // Log the raw JSON response
            if let jsonString = String(data: data, encoding: .utf8) {
                print("Create category raw JSON response: \(jsonString)")
            }
            
            do {
                let category = try JSONDecoder().decode(Category.self, from: data)
                print("Successfully created category: \(category.name)")
                return category
            } catch {
                print("JSON decoding failed: \(error)")
                throw APIError.decoding(error.localizedDescription)
            }
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
    }
    
    public static func updateCategory(id: Int, name: String, icon: String) async throws -> Category {
        let url = try makeURL(route: "/categories/\(id)")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let categoryData = [
            "name": name,
            "icon": icon
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: categoryData)
        } catch {
            throw APIError.transport("Failed to encode category data: \(error.localizedDescription)")
        }
        
        print("Updating category \(id): \(name) with icon: \(icon)")
        print("Request URL: \(url)")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.transport("No HTTP response")
            }
            
            print("Update category HTTP Status: \(http.statusCode)")
            
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? "<no body>"
                print("Update category error response body: \(body)")
                throw APIError.badStatus(http.statusCode, body)
            }
            
            // Log the raw JSON response
            if let jsonString = String(data: data, encoding: .utf8) {
                print("Update category raw JSON response: \(jsonString)")
            }
            
            do {
                let category = try JSONDecoder().decode(Category.self, from: data)
                print("Successfully updated category: \(category.name)")
                return category
            } catch {
                print("JSON decoding failed: \(error)")
                throw APIError.decoding(error.localizedDescription)
            }
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
    }
    
    public static func deleteCategory(id: Int) async throws {
        let url = try makeURL(route: "/categories/\(id)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        print("Deleting category \(id)")
        print("Request URL: \(url)")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.transport("No HTTP response")
            }
            
            print("Delete category HTTP Status: \(http.statusCode)")
            
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? "<no body>"
                print("Delete category error response body: \(body)")
                throw APIError.badStatus(http.statusCode, body)
            }
            
            print("Successfully deleted category \(id)")
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
    }

    public static func fetchRecipes(categoryID: Int? = nil,
                                    page: Int = 1,
                                    limit: Int = 12) async throws -> [Recipe] {
        var query: [URLQueryItem] = [
            .init(name: "page", value: String(page)),
            .init(name: "limit", value: String(limit))
        ]
        if let categoryID {
            query.append(.init(name: "category_id", value: String(categoryID)))
        }

        let url = try makeURL(route: "/recipes", extraQuery: query)
        print("Fetching URL: \(url)")
        
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.transport("No HTTP response")
            }
            
            print("HTTP Status: \(http.statusCode)")
            
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? "<no body>"
                print("Error response body: \(body)")
                throw APIError.badStatus(http.statusCode, body)
            }
            
            // Log the raw JSON response
            if let jsonString = String(data: data, encoding: .utf8) {
                print("Raw JSON response: \(jsonString)")
            }
            
            do {
                let page = try JSONDecoder().decode(Page<Recipe>.self, from: data)
                print("Successfully decoded \(page.data.count) recipes")
                return page.data
            } catch {
                print("JSON decoding failed: \(error)")
                
                // Try to decode as plain array (in case it's not wrapped in Page)
                do {
                    let recipes = try JSONDecoder().decode([Recipe].self, from: data)
                    print("Successfully decoded as plain array: \(recipes.count) recipes")
                    return recipes
                } catch {
                    print("Plain array decoding also failed: \(error)")
                    throw APIError.decoding(error.localizedDescription)
                }
            }
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
    }
    
    public static func searchRecipes(query: String, page: Int = 1, limit: Int = 50) async throws -> [Recipe] {
        let queryItems: [URLQueryItem] = [
            .init(name: "q", value: query),
            .init(name: "page", value: String(page)),
            .init(name: "limit", value: String(limit))
        ]

        let url = try makeURL(route: "/recipes", extraQuery: queryItems)
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.transport("No HTTP response")
            }
            
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? "<no body>"
                throw APIError.badStatus(http.statusCode, body)
            }
            
            do {
                let page = try JSONDecoder().decode(Page<Recipe>.self, from: data)
                return page.data
            } catch {
                throw APIError.decoding(error.localizedDescription)
            }
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
    }
    

    public static func createRecipe(categoryId: Int, name: String, recipeTime: Int?, details: String?, image: String?) async throws -> Recipe {
        let url = try makeURL(route: "/recipes")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        var recipeData: [String: Any] = [
            "category_id": categoryId,
            "name": name
        ]
        
        if let recipeTime = recipeTime {
            recipeData["recipe_time"] = recipeTime
        }
        if let details = details {
            recipeData["details"] = details
        }
        if let image = image {
            recipeData["image"] = image
        }
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: recipeData)
        } catch {
            throw APIError.transport("Failed to encode recipe data: \(error.localizedDescription)")
        }
        
        print("Creating recipe: \(name) in category: \(categoryId)")
        print("Request URL: \(url)")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.transport("No HTTP response")
            }
            
            print("Create recipe HTTP Status: \(http.statusCode)")
            
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? "<no body>"
                print("Create recipe error response body: \(body)")
                throw APIError.badStatus(http.statusCode, body)
            }
            
            if let jsonString = String(data: data, encoding: .utf8) {
                print("Create recipe raw JSON response: \(jsonString)")
            }
            
            do {
                let recipe = try JSONDecoder().decode(Recipe.self, from: data)
                print("Successfully created recipe: \(recipe.name)")
                return recipe
            } catch {
                print("JSON decoding failed: \(error)")
                throw APIError.decoding(error.localizedDescription)
            }
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
    }

    public static func updateRecipe(id: Int, categoryId: Int?, name: String?, recipeTime: Int?, details: String?, image: String?) async throws -> Recipe {
        let url = try makeURL(route: "/recipes/\(id)")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        var recipeData: [String: Any] = [:]
        
        if let categoryId = categoryId {
            recipeData["category_id"] = categoryId
        }
        if let name = name {
            recipeData["name"] = name
        }
        if let recipeTime = recipeTime {
            recipeData["recipe_time"] = recipeTime
        }
        if let details = details {
            recipeData["details"] = details
        }
        if let image = image {
            recipeData["image"] = image
        }
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: recipeData)
        } catch {
            throw APIError.transport("Failed to encode recipe data: \(error.localizedDescription)")
        }
        
        print("Updating recipe \(id)")
        print("Request URL: \(url)")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.transport("No HTTP response")
            }
            
            print("Update recipe HTTP Status: \(http.statusCode)")
            
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? "<no body>"
                print("Update recipe error response body: \(body)")
                throw APIError.badStatus(http.statusCode, body)
            }
            
            if let jsonString = String(data: data, encoding: .utf8) {
                print("Update recipe raw JSON response: \(jsonString)")
            }
            
            do {
                let recipe = try JSONDecoder().decode(Recipe.self, from: data)
                print("Successfully updated recipe: \(recipe.name)")
                return recipe
            } catch {
                print("JSON decoding failed: \(error)")
                throw APIError.decoding(error.localizedDescription)
            }
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
    }

    public static func deleteRecipe(id: Int) async throws {
        let url = try makeURL(route: "/recipes/\(id)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        print("Deleting recipe \(id)")
        print("Request URL: \(url)")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.transport("No HTTP response")
            }
            
            print("Delete recipe HTTP Status: \(http.statusCode)")
            
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? "<no body>"
                print("Delete recipe error response body: \(body)")
                throw APIError.badStatus(http.statusCode, body)
            }
            
            print("Successfully deleted recipe \(id)")
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
    }

    public static func uploadImage(imageData: Data, fileName: String) async throws -> String {
        let url = try makeURL(route: "/media")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        
        // Add file data
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = body
        
        print("Uploading image: \(fileName)")
        print("Request URL: \(url)")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.transport("No HTTP response")
            }
            
            print("Upload image HTTP Status: \(http.statusCode)")
            
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? "<no body>"
                print("Upload image error response body: \(body)")
                throw APIError.badStatus(http.statusCode, body)
            }
            
            if let jsonString = String(data: data, encoding: .utf8) {
                print("Upload image raw JSON response: \(jsonString)")
            }
            
            struct UploadResponse: Codable {
                let path: String
                let filename: String
                let mime: String
                let bytes: Int
                let width: Int?
                let height: Int?
            }
            
            do {
                let uploadResponse = try JSONDecoder().decode(UploadResponse.self, from: data)
                print("Successfully uploaded image: \(uploadResponse.path)")
                return uploadResponse.path
            } catch {
                print("JSON decoding failed: \(error)")
                throw APIError.decoding(error.localizedDescription)
            }
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
    }
    
    
}
