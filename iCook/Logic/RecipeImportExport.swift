import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum RecipeExportConstants {
    nonisolated static let contentType: UTType = UTType(exportedAs: "com.georgebabichev.icook.export")
    nonisolated static let recipesFileName = "Recipes.json"
    nonisolated static let imagesFolderName = "Images"
}

struct ExportedCategory: Codable {
    let name: String
    let icon: String
    let lastModified: Date?
}

struct ExportedTag: Codable {
    let name: String
    let lastModified: Date?
}

struct ExportedSourceMetadata: Codable {
    let name: String
}

struct ExportedRecipe: Codable {
    let exportID: String?
    let name: String
    let recipeTime: Int
    let details: String?
    let categoryName: String
    let recipeSteps: [RecipeStep]
    let imageFilename: String?
    let tagNames: [String]?
    let isFavorite: Bool?
    let linkedRecipeExportIDs: [String]?
    let linkedRecipeNames: [String]?
    let lastModified: Date?
}

struct RecipeExportPackage: Codable {
    let source: ExportedSourceMetadata?
    let categories: [ExportedCategory]
    let tags: [ExportedTag]
    let recipes: [ExportedRecipe]
    
    enum CodingKeys: String, CodingKey {
        case source
        case categories
        case tags
        case recipes
    }
    
    init(source: ExportedSourceMetadata? = nil, categories: [ExportedCategory], tags: [ExportedTag], recipes: [ExportedRecipe]) {
        self.source = source
        self.categories = categories
        self.tags = tags
        self.recipes = recipes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.source = try container.decodeIfPresent(ExportedSourceMetadata.self, forKey: .source)
        self.categories = try container.decode([ExportedCategory].self, forKey: .categories)
        self.tags = try container.decodeIfPresent([ExportedTag].self, forKey: .tags) ?? []
        self.recipes = try container.decode([ExportedRecipe].self, forKey: .recipes)
    }
}

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
