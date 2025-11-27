import Foundation
#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers
#endif

struct ExportedCategory: Codable {
    let name: String
    let icon: String
}

struct ExportedRecipe: Codable {
    let name: String
    let recipeTime: Int
    let details: String?
    let categoryName: String
    let recipeSteps: [RecipeStep]
    let lastModified: Date
}

struct RecipeExportPackage: Codable {
    let sourceName: String
    let exportedAt: Date
    let categories: [ExportedCategory]
    let recipes: [ExportedRecipe]
}

#if os(macOS)
struct RecipeExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
#endif
