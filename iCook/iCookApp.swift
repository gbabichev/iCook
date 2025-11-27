//
//  iCookApp.swift
//  iCook
//
//  Created by George Babichev on 9/16/25.
//

import SwiftUI
import CloudKit
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

@main
struct iCookApp: App {

    @StateObject private var model = AppViewModel()
#if os(macOS)
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var exportDocument = RecipeExportDocument()
#endif

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onOpenURL { url in
                    // Handle CloudKit share links
                    handleCloudKitShareLink(url)
                }
#if os(macOS)
                .fileExporter(
                    isPresented: $isExporting,
                    document: exportDocument,
                    contentType: .json,
                    defaultFilename: "RecipesExport"
                ) { result in
                    switch result {
                    case .success(let url):
                        showAlert(title: "Export Complete", message: "Recipes saved to \(url.lastPathComponent).")
                    case .failure(let error):
                        showAlert(title: "Export Failed", message: error.localizedDescription)
                    }
                }
                .fileImporter(
                    isPresented: $isImporting,
                    allowedContentTypes: [.json],
                    allowsMultipleSelection: false
                ) { result in
                    switch result {
                    case .success(let urls):
                        guard let url = urls.first else { return }
                        Task {
                            let canAccess = url.startAccessingSecurityScopedResource()
                            defer {
                                if canAccess { url.stopAccessingSecurityScopedResource() }
                            }
                            let success = await model.importRecipes(from: url)
                            await MainActor.run {
                                if success {
                                    showAlert(title: "Import Complete", message: "Recipes were imported successfully.")
                                } else if let message = model.error {
                                    showAlert(title: "Import Failed", message: message)
                                }
                            }
                        }
                    case .failure(let error):
                        showAlert(title: "Import Failed", message: error.localizedDescription)
                    }
                }
#endif
        }
#if os(macOS)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh") {
                    Task {
                        await refreshCurrentView()
                    }
                }
                .keyboardShortcut("r", modifiers: .command)

                Divider()

                Button("Export Recipes…") {
                    exportRecipes()
                }

                Button("Import Recipes…") {
                    importRecipes()
                }
            }
        }
#endif
    }

    private func handleCloudKitShareLink(_ url: URL) {
        Task {
            printD("Processing CloudKit share link: \(url)")

            // CKShareURL can be used to create a CKShare object
            // CloudKit handles this automatically when the user accepts
            // We just need to reload sources to show any newly shared sources
            await model.loadSources()

            printD("Share link processed successfully")
        }
    }
    
#if os(macOS)
    @MainActor
    private func refreshCurrentView() async {
        // Refresh categories
        await model.loadCategories()

        // Refresh random recipes for home view
        await model.loadRandomRecipes()
        
        // Post a notification that other views can listen to for refresh
        NotificationCenter.default.post(name: .refreshRequested, object: nil)
    }
#endif

#if os(macOS)
    private func exportRecipes() {
        Task {
            await MainActor.run {
                model.error = nil
            }
            if let data = await model.exportCurrentSourceData() {
                await MainActor.run {
                    exportDocument = RecipeExportDocument(data: data)
                    isExporting = true
                }
            } else if let message = await MainActor.run(body: { model.error }) {
                await MainActor.run {
                    showAlert(title: "Export Failed", message: message)
                }
            }
        }
    }

    private func importRecipes() {
        isImporting = true
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
#endif
}
