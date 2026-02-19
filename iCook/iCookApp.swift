//
//  iCookApp.swift
//  iCook
//
//  Created by George Babichev on 9/16/25.
//

import SwiftUI
import CloudKit
import Combine
import UniformTypeIdentifiers
#if os(macOS)
import AppKit

private extension Notification.Name {
    static let macRouteImportToWindow = Notification.Name("iCook.macRouteImportToWindow")
}
#endif

#if os(macOS)
final class MacAppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    struct ImportRequest: Equatable {
        let id: UUID
        let url: URL
    }

    @Published private(set) var importRequest: ImportRequest?
    private var consumedImportRequestIDs: Set<UUID> = []

    var onOpenShare: ((URL) -> Void)?
    var onAcceptShare: ((CKShare.Metadata) -> Void)?
    var onShowAbout: (() -> Void)?
    var onImportCommand: (() -> Void)?
    var onExportCommand: (() -> Void)?
    
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if shouldHandle(url: url) {
            deliver(url)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onOpenShare?(url)
            }
        }
    }

    func application(_ application: NSApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        DispatchQueue.main.async { [weak self] in
            self?.onAcceptShare?(metadata)
        }
    }
    
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        if shouldHandle(url: url) {
            deliver(url)
            return true
        }
        DispatchQueue.main.async { [weak self] in
            self?.onOpenShare?(url)
        }
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
            printD("macOS open file delivered: \(url.lastPathComponent)")
            self.importRequest = ImportRequest(id: UUID(), url: url)
        }
    }

    func consumeImportRequest(_ request: ImportRequest) -> URL? {
        guard !consumedImportRequestIDs.contains(request.id) else { return nil }
        consumedImportRequestIDs.insert(request.id)
        if importRequest?.id == request.id {
            importRequest = nil
        }
        printD("macOS import request consumed: \(request.url.lastPathComponent)")
        return request.url
    }
}

private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            onResolve(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onResolve(nsView.window)
        }
    }
}

private enum ImportRouteUserInfoKey {
    static let targetWindowNumber = "targetWindowNumber"
    static let importURL = "importURL"
}
#endif

#if os(iOS)
final class IOSAppDelegate: NSObject, UIApplicationDelegate, ObservableObject {
    var onAcceptShare: ((CKShare.Metadata) -> Void)?
    
    func application(_ application: UIApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        DispatchQueue.main.async { [weak self] in
            self?.onAcceptShare?(metadata)
        }
    }
    
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        config.delegateClass = IOSSceneDelegate.self
        return config
    }
}

final class IOSSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        NotificationCenter.default.post(name: .cloudKitShareAccepted, object: metadata)
    }
    
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        NotificationCenter.default.post(name: .cloudKitShareURLReceived, object: url)
    }
    
    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        if userActivity.activityType == NSUserActivityTypeBrowsingWeb,
           let url = userActivity.webpageURL {
            NotificationCenter.default.post(name: .cloudKitShareURLReceived, object: url)
        }
    }
}
#endif

@main
struct iCookApp: App {
    
    @StateObject private var model = AppViewModel()
#if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
#endif
#if os(iOS)
    @UIApplicationDelegateAdaptor(IOSAppDelegate.self) private var iosAppDelegate
#endif
    
    var body: some Scene {
#if os(macOS)
        Window("iCook", id: "main") {
            AppWindowContent(appDelegate: appDelegate)
                .environmentObject(model)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button {
                    appDelegate.onShowAbout?()
                } label: {
                    Label("About iCook", systemImage: "info.circle")
                }
            }
            
            CommandGroup(replacing: .newItem) {
                Button {
                    openWindow(id: "secondary")
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
                    appDelegate.onImportCommand?()
                } label: {
                    Label("Import Recipes…", systemImage: "square.and.arrow.down")
                }
                
                Button {
                    appDelegate.onExportCommand?()
                } label: {
                    Label("Export Recipes…", systemImage: "square.and.arrow.up")
                }
            }
        }

        WindowGroup("iCook", id: "secondary") {
            AppWindowContent(appDelegate: appDelegate)
                .environmentObject(model)
        }
        .handlesExternalEvents(matching: Set(["secondary"]))
#endif
#if os(iOS)
        WindowGroup {
            AppWindowContent(iosAppDelegate: iosAppDelegate)
                .environmentObject(model)
        }
#endif
    }
    
#if os(macOS)
    @MainActor
    private func refreshCurrentView() async {
        NotificationCenter.default.post(name: .refreshRequested, object: nil)
    }
#endif
}

private struct AppWindowContent: View {
    @EnvironmentObject private var model: AppViewModel
#if os(macOS)
    let appDelegate: MacAppDelegate
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var exportDocument = RecipeExportDocument()
    @State private var showAbout = false
    @State private var hostWindow: NSWindow?
    @State private var pendingOpenedExportURL: URL?
#endif
#if os(iOS)
    let iosAppDelegate: IOSAppDelegate
#endif
    @State private var importPreview: AppViewModel.ImportPreview?
    @State private var selectedImportIndices: Set<Int> = []
    @State private var securityScopedImportURL: URL?
    @State private var isCommittingImport = false
    @State private var showImportCompletedToast = false
    @State private var importCompletedToastMessage = ""
    
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
    
    private func presentImportPreview(for url: URL) {
        printD("Preparing import preview for: \(url.lastPathComponent)")
        Task {
            let canAccess = url.startAccessingSecurityScopedResource()
            let preview = model.loadImportPreview(from: url)
            await MainActor.run {
                if let preview {
                    printD("Import preview ready: recipes=\(preview.package.recipes.count)")
                    importPreview = preview
                    selectedImportIndices = Set(preview.package.recipes.indices)
                    securityScopedImportURL = canAccess ? url : nil
                } else {
                    printD("Import preview failed for: \(url.lastPathComponent)")
                    if canAccess { url.stopAccessingSecurityScopedResource() }
#if os(macOS)
                    if let message = model.error {
                        showAlert(title: "Import Failed", message: message)
                    }
#endif
                }
            }
        }
    }
    
    private func confirmImportSelection() {
        guard let preview = importPreview else { return }
        let selectedRecipes = selectedImportIndices.sorted().map { preview.package.recipes[$0] }
        let selectedCount = selectedRecipes.count
        let securedURL = securityScopedImportURL
        isCommittingImport = true
        Task {
            let success = await model.importRecipes(from: preview, selectedRecipes: selectedRecipes)
            await MainActor.run {
                isCommittingImport = false
#if os(macOS)
                if !success, let message = model.error {
                    showAlert(title: "Import Failed", message: message)
                }
#else
                if !success {
                    printD("Import failed: \(model.error ?? "unknown error")")
                }
#endif
                if success {
                    presentImportCompletedToast(importedCount: selectedCount)
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
        isCommittingImport = false
    }

    private func presentImportCompletedToast(importedCount: Int) {
        importCompletedToastMessage = importedCount == 1
            ? "Imported 1 recipe"
            : "Imported \(importedCount) recipes"
        withAnimation {
            showImportCompletedToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation {
                showImportCompletedToast = false
            }
        }
    }
    
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

    private func forwardImportToExistingWindowIfNeeded(_ url: URL) -> Bool {
        guard let hostWindow else { return false }
        let visibleMainWindows = NSApp.windows
            .filter { $0.isVisible && $0.canBecomeMain }
        guard visibleMainWindows.count > 1 else { return false }
        guard let newestWindow = visibleMainWindows.max(by: { $0.windowNumber < $1.windowNumber }),
              newestWindow === hostWindow else { return false }

        let target = visibleMainWindows
            .filter { $0.windowNumber < hostWindow.windowNumber }
            .sorted { $0.windowNumber < $1.windowNumber }
            .first
        guard let target else { return false }

        NotificationCenter.default.post(
            name: .macRouteImportToWindow,
            object: nil,
            userInfo: [
                ImportRouteUserInfoKey.targetWindowNumber: target.windowNumber,
                ImportRouteUserInfoKey.importURL: url
            ]
        )
        printD("Forwarded import to existing window \(target.windowNumber) from window \(hostWindow.windowNumber)")
        DispatchQueue.main.async {
            hostWindow.close()
        }
        return true
    }

    private func processPendingOpenedExportIfNeeded() {
        guard let url = pendingOpenedExportURL else { return }
        guard hostWindow != nil else {
            printD("Deferring import open until window is resolved: \(url.lastPathComponent)")
            return
        }
        pendingOpenedExportURL = nil
        if forwardImportToExistingWindowIfNeeded(url) { return }
        handleOpenedExportOnce(url)
    }

    private func tryConsumePendingImportRequest() {
        guard let request = appDelegate.importRequest else { return }
        printD("Attempting to consume pending import request: \(request.url.lastPathComponent)")
        guard let url = appDelegate.consumeImportRequest(request) else { return }
        pendingOpenedExportURL = url
        processPendingOpenedExportIfNeeded()
    }
#endif
    
    private func handleOpenedExport(_ url: URL) {
        printD("Handling export open: \(url.lastPathComponent)")
        presentImportPreview(for: url)
    }

    private func handleOpenedExportOnce(_ url: URL) {
        handleOpenedExport(url)
    }
    
    private func isExportURL(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
           type.conforms(to: RecipeExportConstants.contentType) {
            return true
        }
        return url.isFileURL && url.pathExtension.lowercased() == "icookexport"
    }
    
    var body: some View {
        ZStack {
            ContentView()
                .onOpenURL { url in
                    if isExportURL(url) {
                        printD("onOpenURL received import file: \(url.lastPathComponent)")
#if os(macOS)
                        pendingOpenedExportURL = url
                        processPendingOpenedExportIfNeeded()
                        return
#else
                        handleOpenedExportOnce(url)
#endif
                    } else {
                        handleCloudKitShareLink(url)
                    }
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL {
                        handleCloudKitShareLink(url)
                    }
                }
#if os(macOS)
                .background(
                    WindowAccessor { window in
                        hostWindow = window
                        processPendingOpenedExportIfNeeded()
                    }
                )
                .onAppear {
                    appDelegate.onOpenShare = { url in
                        handleCloudKitShareLink(url)
                    }
                    appDelegate.onAcceptShare = { metadata in
                        Task {
                            _ = await model.acceptShareMetadata(metadata)
                        }
                    }
                    appDelegate.onShowAbout = {
                        showAbout = true
                    }
                    appDelegate.onImportCommand = {
                        importRecipes()
                    }
                    appDelegate.onExportCommand = {
                        exportRecipes()
                    }
                    processPendingOpenedExportIfNeeded()
                    tryConsumePendingImportRequest()
                }
                .onReceive(appDelegate.$importRequest.compactMap { $0 }) { _ in
                    tryConsumePendingImportRequest()
                }
                .onReceive(NotificationCenter.default.publisher(for: .macRouteImportToWindow)) { note in
                    guard let targetWindowNumber = note.userInfo?[ImportRouteUserInfoKey.targetWindowNumber] as? Int,
                          let url = note.userInfo?[ImportRouteUserInfoKey.importURL] as? URL,
                          hostWindow?.windowNumber == targetWindowNumber else { return }
                    printD("Received forwarded import in window \(targetWindowNumber): \(url.lastPathComponent)")
                    handleOpenedExportOnce(url)
                }
                .onChange(of: hostWindow?.windowNumber) { _, _ in
                    processPendingOpenedExportIfNeeded()
                }
#endif
#if os(iOS)
                .onAppear {
                    iosAppDelegate.onAcceptShare = { metadata in
                        Task {
                            _ = await model.acceptShareMetadata(metadata)
                        }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .cloudKitShareAccepted)) { note in
                    if let metadata = note.object as? CKShare.Metadata {
                        Task { _ = await model.acceptShareMetadata(metadata) }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .cloudKitShareURLReceived)) { note in
                    if let url = note.object as? URL {
                        handleCloudKitShareLink(url)
                    }
                }
#endif
            
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
            
            if model.isAcceptingShare {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading shared collection…")
                        .font(.headline)
                }
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }

#if os(macOS)
            if showAbout {
                AboutOverlayView(isPresented: $showAbout)
                    .zIndex(10)
            }
#endif
        }
        .overlay(alignment: .bottom) {
            if showImportCompletedToast {
                Text(importCompletedToastMessage)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .shadow(radius: 6)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
#if DEBUG
        .overlay(alignment: .bottomTrailing) {
            BetaTag()
                .padding(12)
        }
#endif
#if os(macOS)
        .frame(minWidth: 600, minHeight: 600)
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
        .sheet(item: $importPreview) { preview in
            ImportPreviewSheet(
                preview: preview,
                selectedIndices: $selectedImportIndices,
                isImporting: isCommittingImport,
                onSelectAll: { selectedImportIndices = Set(preview.package.recipes.indices) },
                onDeselectAll: { selectedImportIndices.removeAll() },
                onCancel: { cancelImportPreview() },
                onImport: { confirmImportSelection() }
            )
        }
#else
        .sheet(item: $importPreview) { preview in
            ImportPreviewSheet(
                preview: preview,
                selectedIndices: $selectedImportIndices,
                isImporting: isCommittingImport,
                onSelectAll: { selectedImportIndices = Set(preview.package.recipes.indices) },
                onDeselectAll: { selectedImportIndices.removeAll() },
                onCancel: { cancelImportPreview() },
                onImport: { confirmImportSelection() }
            )
            .presentationDetents([.medium, .large])
        }
#endif
    }
}
