//
//  iCookApp.swift
//  iCook
//
//  Created by George Babichev on 9/16/25.
//

import SwiftUI
import CloudKit
import Combine
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

#if os(macOS)
final class MacAppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published var pendingImportURL: URL?
    var onOpenExport: ((URL) -> Void)?
    
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first, shouldHandle(url: url) else { return }
        deliver(url)
    }
    
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        guard shouldHandle(url: url) else { return false }
        deliver(url)
        return true
    }
    
    private func shouldHandle(url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
           type.conforms(to: RecipeExportConstants.contentType) {
            return true
        }
        return url.pathExtension.lowercased() == "icookexport"
    }
    
    private func deliver(_ url: URL) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingImportURL = url
            self.onOpenExport?(url)
        }
    }
}
#endif

@main
struct iCookApp: App {
    
    @StateObject private var model = AppViewModel()
#if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var exportDocument = RecipeExportDocument()
    @State private var showAbout = false
    @State private var importPreview: AppViewModel.ImportPreview?
    @State private var selectedImportIndices: Set<Int> = []
    @State private var securityScopedImportURL: URL?
#endif
    
    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environmentObject(model)
                    .onOpenURL { url in
                        // Handle export bundles or CloudKit share links
                        if isExportURL(url) {
                            handleOpenedExport(url)
                        } else {
                            handleCloudKitShareLink(url)
                        }
                    }
#if os(macOS)
                    .onAppear {
                        appDelegate.onOpenExport = { url in
                            handleOpenedExport(url)
                        }
                        if let pending = appDelegate.pendingImportURL {
                            appDelegate.pendingImportURL = nil
                            handleOpenedExport(pending)
                        }
                    }
                    .onReceive(appDelegate.$pendingImportURL.compactMap { $0 }) { url in
                        appDelegate.pendingImportURL = nil
                        handleOpenedExport(url)
                    }
#endif
                
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
            .frame(minWidth: 600, minHeight: 600)
#endif
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
                    presentImportPreview(for: url)
                case .failure(let error):
                    showAlert(title: "Import Failed", message: error.localizedDescription)
                }
            }
#endif
#if os(macOS)
            .sheet(isPresented: $showAbout) {
                AboutView()
            }
            .sheet(item: $importPreview) { preview in
                ImportPreviewSheet(
                    preview: preview,
                    selectedIndices: $selectedImportIndices,
                    onSelectAll: { selectedImportIndices = Set(preview.package.recipes.indices) },
                    onDeselectAll: { selectedImportIndices.removeAll() },
                    onCancel: { cancelImportPreview() },
                    onImport: { confirmImportSelection() }
                )
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
        // Only process real CloudKit share URLs; ignore local file/document opens
        guard !url.isFileURL else { return }
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
    private func presentImportPreview(for url: URL) {
        Task {
            let canAccess = url.startAccessingSecurityScopedResource()
            let preview = model.loadImportPreview(from: url)
            await MainActor.run {
                if let preview {
                    importPreview = preview
                    selectedImportIndices = Set(preview.package.recipes.indices)
                    securityScopedImportURL = canAccess ? url : nil
                } else {
                    if canAccess { url.stopAccessingSecurityScopedResource() }
                    if let message = model.error {
                        showAlert(title: "Import Failed", message: message)
                    }
                }
            }
        }
    }
    
    private func confirmImportSelection() {
        guard let preview = importPreview else { return }
        let selectedRecipes = selectedImportIndices.sorted().map { preview.package.recipes[$0] }
        let securedURL = securityScopedImportURL
        Task {
            let success = await model.importRecipes(from: preview, selectedRecipes: selectedRecipes)
            await MainActor.run {
                if success {
                    showAlert(title: "Import Complete", message: "Recipes were imported successfully.")
                } else if let message = model.error {
                    showAlert(title: "Import Failed", message: message)
                }
                cleanupImportPreview()
                if let securedURL {
                    securedURL.stopAccessingSecurityScopedResource()
                }
            }
        }
    }
    
    private func cancelImportPreview() {
        if let securedURL = securityScopedImportURL {
            securedURL.stopAccessingSecurityScopedResource()
        }
        cleanupImportPreview()
    }
    
    private func cleanupImportPreview() {
        importPreview = nil
        selectedImportIndices.removeAll()
        securityScopedImportURL = nil
    }
    
    @MainActor
    private func refreshCurrentView() async {
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
    
    private func handleOpenedExport(_ url: URL) {
        presentImportPreview(for: url)
    }
    
    private func isExportURL(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
           type.conforms(to: RecipeExportConstants.contentType) {
            return true
        }
        return url.isFileURL && url.pathExtension.lowercased() == "icookexport"
    }
    
    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
#endif
}
