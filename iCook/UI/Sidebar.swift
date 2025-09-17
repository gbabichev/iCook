//
//  Sidebar.swift
//  iCook
//
//  Created by George Babichev on 9/16/25.
//

import SwiftUI
// MARK: - List Column (Landmarks: *List)

import SwiftUI

struct CategoryList: View {
    @EnvironmentObject private var model: AppViewModel
    @Binding var selection: Category.ID?
    @Binding var editingCategory: Category?
    
    init(selection: Binding<Category.ID?>, editingCategory: Binding<Category?>) {
        self._selection = selection
        self._editingCategory = editingCategory
    }
    
    var body: some View {
        List(selection: $selection) {
            // Home/Featured section
            NavigationLink(value: -1) {
                HStack {
                    Image(systemName: "house.fill")
                        .foregroundStyle(.blue)
                        .frame(width: 24)
                    Text("Home")
                }
            }
            .tag(-1)
            
            if !model.categories.isEmpty {
                Section("Categories") {
                    ForEach(model.categories) { category in
                        NavigationLink(value: category.id) {
                            HStack {
                                Image(systemName: category.icon)
                                    .frame(width: 24)
                                Text(category.name)
                            }
                        }
                        .tag(category.id)
                        .contextMenu {
                            Button {
                                editingCategory = category
                            } label: {
                                Label("Edit Category", systemImage: "pencil")
                            }
                            
                            Button(role: .destructive) {
                                Task {
                                    await model.deleteCategory(id: category.id)
                                }
                            } label: {
                                Label("Delete Category", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            
            if model.isLoadingCategories {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading categories...")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
        }
        .navigationTitle("iCook")
        .listStyle(.sidebar)
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
