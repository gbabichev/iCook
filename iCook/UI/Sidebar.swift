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
    @Binding var collectionType: RecipeCollectionType?
    @State private var showSourcesOverlay = false
    @State private var deleteAlertMessage: String?
    
    init(
        selection: Binding<CKRecord.ID?>,
        editingCategory: Binding<Category?>,
        isShowingHome: Binding<Bool>,
        showingAddCategory: Binding<Bool>,
        collectionType: Binding<RecipeCollectionType?>
    ) {
        self._selection = selection
        self._editingCategory = editingCategory
        self._isShowingHome = isShowingHome
        self._showingAddCategory = showingAddCategory
        self._collectionType = collectionType
    }
    
    private var homeRecipeCount: Int {
        model.recipeCounts.values.reduce(0, +)
    }
    
    private func recipeCount(for category: Category) -> Int {
        model.recipeCounts[category.id] ?? 0
    }
    
    private func refreshCategoriesSmooth() async {
        guard model.currentSource != nil else { return }
        let start = Date()
        await model.loadCategories()
        let elapsed = Date().timeIntervalSince(start)
        if elapsed < 1.0 {
            try? await Task.sleep(nanoseconds: UInt64((1.0 - elapsed) * 1_000_000_000))
        }
    }
    
    var body: some View {
        List(selection: $collectionType) {
            // Home/Featured section
            NavigationLink(value: RecipeCollectionType.home) {
                HStack(spacing: 6) {
                    Image(systemName: "house.fill")
                        .foregroundStyle(.blue)
                        .frame(width: 24)
                    Text("All Recipes")
                    
                    Spacer()
                    
                    Text("\(homeRecipeCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            if !model.categories.isEmpty {
                Section("Categories") {
                    ForEach(model.categories) { category in
                        NavigationLink(value: RecipeCollectionType.category(category)) {
                            HStack(spacing: 6) {
                                Text(category.icon)
                                    .frame(width: 24)
                                Text(category.name)
                                
                                Spacer()
                                
                                Text("\(recipeCount(for: category))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contextMenu {
                            Button {
                                editingCategory = category
                            } label: {
                                Label("Edit Category", systemImage: "pencil")
                            }
                            .disabled(model.isOfflineMode)
                            
                            Button(role: .destructive) {
                                let count = recipeCount(for: category)
                                if count > 0 {
                                    deleteAlertMessage = "Move or delete the \(count == 1 ? "recipe" : "recipes") in '\(category.name)' before deleting the category."
                                } else {
                                    Task {
                                        await model.deleteCategory(id: category.id)
                                    }
                                }
                            } label: {
                                Label("Delete Category", systemImage: "trash")
                            }
                            .disabled(model.isOfflineMode)
                        }
                    }
                }
            }
            
            if model.isLoadingCategories {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Updating from iCloud...")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else if model.currentSource != nil && model.categories.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(.blue)
                            Text("Welcome!")
                                .font(.headline)
                        }
                        Text("Create your first category to get started")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .listStyle(.sidebar)
        .refreshable {
            await refreshCategoriesSmooth()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showSourcesOverlay = true
                } label: {
                    Image(systemName: "gear")
                }
                .disabled(model.isOfflineMode)
                .accessibilityLabel("Settings")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        showingAddCategory = true
                    } label: {
                        Label("Add Category", systemImage: "tag")
                    }
                    .disabled(model.isOfflineMode || model.currentSource == nil)
                    
                    Button {
                        NotificationCenter.default.post(name: .requestAddRecipe, object: nil)
                    } label: {
                        Label("Add Recipe", systemImage: "fork.knife.circle")
                    }
                    .disabled(model.isOfflineMode || model.currentSource == nil || model.categories.isEmpty)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add")
            }
        }
        .sheet(isPresented: $showSourcesOverlay) {
            SourceSelector()
                .environmentObject(model)
#if os(macOS)
                .frame(minWidth: 400, minHeight: 300)
#endif
        }
        .onChange(of: collectionType) { _, newValue in
            switch newValue {
            case .home:
                isShowingHome = true
                selection = nil
            case .category(let category):
                isShowingHome = false
                selection = category.id
            case .none:
                break
            }
        }
        .alert("Cannot Delete Category", isPresented: .init(
            get: { deleteAlertMessage != nil },
            set: { if !$0 { deleteAlertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {
                deleteAlertMessage = nil
            }
        } message: {
            Text(deleteAlertMessage ?? "")
        }
    }
}
