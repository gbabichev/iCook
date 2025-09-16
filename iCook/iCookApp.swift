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
    }
}
