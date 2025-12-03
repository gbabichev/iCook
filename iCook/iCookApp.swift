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
    @State private var showAbout = false
#endif
    
    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environmentObject(model)
                    .onOpenURL { url in
                        // Handle CloudKit share links
                        handleCloudKitShareLink(url)
                    }
                
#if os(macOS)
                if model.isImporting {
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Importing recipes…")
                            .font(.headline)
                    }
                    .padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
#endif
            }
#if os(macOS)
            .fileExporter(
                isPresented: $isExporting,
                document: exportDocument,
                contentType: RecipeExportConstants.contentType,
                defaultFilename: "RecipesExport.icookexport"
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
                allowedContentTypes: [RecipeExportConstants.contentType, .json],
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
#if os(macOS)
            .sheet(isPresented: $showAbout) {
                AboutView()
            }
#endif
        }
#if os(macOS)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button {
                    showAbout = true
                } label: {
                    Label("About iCook", systemImage: "info.circle")
                }
            }
            
            CommandGroup(replacing: .newItem) {
                Button {
                    NSApp.sendAction(#selector(NSApplication.newWindowForTab(_:)), to: nil, from: nil)
                } label: {
                    Label("New Window", systemImage: "plus.square.on.square")
                }
                .keyboardShortcut("n", modifiers: .command)
                
                Button {
                    Task {
                        await refreshCurrentView()
                    }
                }
                label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                
                Divider()
                
                Button {
                    importRecipes()
                } label: {
                    Label("Import Recipes…", systemImage: "square.and.arrow.down")
                }
                
                Button {
                    exportRecipes()
                } label: {
                    Label("Export Recipes…", systemImage: "square.and.arrow.up")
                }
            }
        }
#endif
    }
    
    private func handleCloudKitShareLink(_ url: URL) {
        Task {
            printD("Processing CloudKit share link: \(url)")
            let success = await model.acceptShareURL(url)
            if success {
                printD("Share link processed successfully via manual accept flow")
            } else if let message = await MainActor.run(body: { model.cloudKitManager.error }) {
                printD("Failed to process share link: \(message)")
            }
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
            if let document = await model.exportCurrentSourceDocument() {
                await MainActor.run {
                    exportDocument = document
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
