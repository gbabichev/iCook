import Foundation

// MARK: - Models

public struct Category: Identifiable, Codable, Hashable {
    public let id: Int
    public let name: String
}

public struct Recipe: Identifiable, Codable, Hashable {
    public let id: Int
    public let category_id: Int
    public let name: String
    public let recipe_time: Int
    public let details: String
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
