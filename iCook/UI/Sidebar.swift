//
//  Sidebar.swift
//  iCook
//
//  Created by George Babichev on 9/16/25.
//

import SwiftUI
// MARK: - List Column (Landmarks: *List)

struct CategoryList: View {
    @EnvironmentObject private var model: AppViewModel
    @Binding var selection: Category.ID?
    @Binding var editingCategory: Category?

    var body: some View {
        List(selection: $selection) {
            // Home section at the top
            Section {
                NavigationLink(value: -1) {
                    HStack(spacing: 12) {
                        Image(systemName: "house.fill")
                            .font(.title2)
                            .foregroundStyle(.primary)
                            .frame(width: 24, height: 24)
                        
                        Text("Home")
                            .font(.body)
                    }
                }
                .tag(-1 as Category.ID?)
            }
            
            // Categories section
            Section("Categories") {
                ForEach(model.categories) { category in
                    NavigationLink(value: category.id) {
                        CategoryRow(category: category)
                    }
                    .tag(category.id)
                    .contextMenu {
                        Button {
                            editingCategory = category
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        
                        Divider()
                        
                        Button(role: .destructive) {
                            Task {
                                // If we're deleting the currently selected category, reset to home
                                if selection == category.id {
                                    selection = -1
                                }
                                await model.deleteCategory(id: category.id)
                            }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle("iCook")
    }
}

// MARK: - Row (Landmarks: *Row)

struct CategoryRow: View {
    let category: Category
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: category.icon)
                .font(.title2)
                .foregroundStyle(.primary)
                .frame(width: 24, height: 24)
            
            Text(category.name)
                .font(.body)
        }
    }
}
