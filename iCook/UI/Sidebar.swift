//
//  Sidebar.swift
//  iCook
//
//  Created by George Babichev on 9/16/25.
//

import SwiftUI
import CloudKit

// MARK: - List Column (Landmarks: *List)

struct CategoryList: View {
    @EnvironmentObject private var model: AppViewModel
    @Binding var selection: CKRecord.ID?
    @Binding var editingCategory: Category?
    @Binding var isShowingHome: Bool
    @Binding var showingAddCategory: Bool
    @State private var showSourcesOverlay = false

    init(selection: Binding<CKRecord.ID?>, editingCategory: Binding<Category?>, isShowingHome: Binding<Bool>, showingAddCategory: Binding<Bool>) {
        self._selection = selection
        self._editingCategory = editingCategory
        self._isShowingHome = isShowingHome
        self._showingAddCategory = showingAddCategory
    }

    var body: some View {
        List {
            // Home/Featured section
            NavigationLink(destination: RecipeCollectionView()) {
                HStack {
                    Image(systemName: "house.fill")
                        .foregroundStyle(.blue)
                        .frame(width: 24)
                    Text("Home")
                    Spacer()
                    if isShowingHome {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.blue)
                    }
                }
            }

            if !model.categories.isEmpty {
                Section("Categories") {
                    ForEach(model.categories) { category in
                        NavigationLink(destination: RecipeCollectionView(category: category)) {
                            HStack {
                                Image(systemName: category.icon)
                                    .frame(width: 24)
                                Text(category.name)
                                Spacer()
                                if selection == category.id && !isShowingHome {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showSourcesOverlay = true
                } label: {
                    Image(systemName: "cloud")
                }
                .accessibilityLabel("Sources")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddCategory = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add Category")
            }
        }
        .sheet(isPresented: $showSourcesOverlay) {
            SourceSelector()
                .environmentObject(model)
#if os(macOS)
                .frame(minWidth: 400, minHeight: 300)
#endif
        }
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
