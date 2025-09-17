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
        var queryItems: [URLQueryItem] = [
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
}
