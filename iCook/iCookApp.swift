//
//  iCookApp.swift
//  iCook
//
//  Created by George Babichev on 9/16/25.
//

import SwiftUI
import CloudKit

@main
struct iCookApp: App {

    @StateObject private var model = AppViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onOpenURL { url in
                    // Handle CloudKit share links
                    handleCloudKitShareLink(url)
                }
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
}
