import Foundation
#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

enum RecipeExportConstants {
    nonisolated static let contentType: UTType = UTType(exportedAs: "com.georgebabichev.icook.export")
    nonisolated static let recipesFileName = "Recipes.json"
    nonisolated static let imagesFolderName = "Images"
}
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
    let imageFilename: String?
}

struct RecipeExportPackage: Codable {
    let sourceName: String
    let exportedAt: Date
    let categories: [ExportedCategory]
    let recipes: [ExportedRecipe]
    let formatVersion: Int

    enum CodingKeys: String, CodingKey {
        case sourceName
        case exportedAt
        case categories
        case recipes
        case formatVersion
    }

    init(sourceName: String, exportedAt: Date, categories: [ExportedCategory], recipes: [ExportedRecipe], formatVersion: Int) {
        self.sourceName = sourceName
        self.exportedAt = exportedAt
        self.categories = categories
        self.recipes = recipes
        self.formatVersion = formatVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sourceName = try container.decode(String.self, forKey: .sourceName)
        self.exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        self.categories = try container.decode([ExportedCategory].self, forKey: .categories)
        self.recipes = try container.decode([ExportedRecipe].self, forKey: .recipes)
        self.formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
    }
}

#if os(macOS)
struct RecipeExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [RecipeExportConstants.contentType, .json] }
    static var writableContentTypes: [UTType] { [RecipeExportConstants.contentType, .json] }

    var jsonData: Data
    var images: [String: Data]

    init(data: Data = Data(), images: [String: Data] = [:]) {
        self.jsonData = data
        self.images = images
    }

    init(configuration: ReadConfiguration) throws {
        if configuration.contentType.conforms(to: RecipeExportConstants.contentType),
           configuration.file.isDirectory {
            guard let wrappers = configuration.file.fileWrappers else {
                throw CocoaError(.fileReadCorruptFile)
            }

            guard let recipesWrapper = wrappers[RecipeExportConstants.recipesFileName],
                  let data = recipesWrapper.regularFileContents else {
                throw CocoaError(.fileReadCorruptFile)
            }
            self.jsonData = data

            var loadedImages: [String: Data] = [:]
            if let imagesWrapper = wrappers[RecipeExportConstants.imagesFolderName],
               let files = imagesWrapper.fileWrappers {
                for (name, wrapper) in files {
                    if let data = wrapper.regularFileContents {
                        loadedImages[name] = data
                    }
                }
            }
            self.images = loadedImages
        } else if let data = configuration.file.regularFileContents {
            self.jsonData = data
            self.images = [:]
        } else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        var wrappers: [String: FileWrapper] = [
            RecipeExportConstants.recipesFileName: FileWrapper(regularFileWithContents: jsonData)
        ]

        var imageWrappers: [String: FileWrapper] = [:]
        for (name, data) in images {
            imageWrappers[name] = FileWrapper(regularFileWithContents: data)
        }
        if !imageWrappers.isEmpty {
            let imagesFolder = FileWrapper(directoryWithFileWrappers: imageWrappers)
            wrappers[RecipeExportConstants.imagesFolderName] = imagesFolder
        } else {
            wrappers[RecipeExportConstants.imagesFolderName] = FileWrapper(directoryWithFileWrappers: [:])
        }

        return FileWrapper(directoryWithFileWrappers: wrappers)
    }
}
#endif
