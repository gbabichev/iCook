#if os(macOS)

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
    let categories: [ExportedCategory]
    let recipes: [ExportedRecipe]
    
    enum CodingKeys: String, CodingKey {
        case categories
        case recipes
    }
    
    init(categories: [ExportedCategory], recipes: [ExportedRecipe]) {
        self.categories = categories
        self.recipes = recipes
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.categories = try container.decode([ExportedCategory].self, forKey: .categories)
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
#endif
