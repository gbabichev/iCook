//
//  iCookApp.swift
//  iCook
//
//  Created by George Babichev on 9/16/25.
//

import SwiftUI

@main
struct iCookApp: App {
    
    @StateObject private var model = AppViewModel()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
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
