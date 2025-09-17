//
//  ModifyCategory.swift
//  iCook
//
//  Created by George Babichev on 9/16/25.
//

import SwiftUI

// MARK: - Individual Icon Button
struct IconButton: View {
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: isSelected ? 2 : 1)
                )
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .buttonStyle(.plain)
    }
}


struct AddCategoryView: View {
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.dismiss) private var dismiss
    
    let editingCategory: Category?
    
    @State private var categoryName: String = ""
    @State private var selectedIcon: String = "fork.knife"
    @State private var isSaving = false
    
    // Fixed: Removed duplicates from commonIcons array
    private let commonIcons = [
        "fork.knife",
        "cup.and.saucer",
        "cup.and.saucer.fill",
        "birthday.cake.fill",
        "carrot.fill",
        "leaf.fill",
        "fish.fill",
        "popcorn.fill",
        "wineglass.fill",
        "mug.fill",
        "takeoutbag.and.cup.and.straw",
        "takeoutbag.and.cup.and.straw.fill",
        "refrigerator.fill",
        "cooktop.fill",
        "flame.fill",
        "drop.fill",
        "snowflake",
        "sun.max.fill",
        "moon.fill",
        "star.fill",
        "heart.fill",
        "house.fill",
        "waterbottle.fill"
    ]
    var isEditing: Bool { editingCategory != nil }
    
    init(editingCategory: Category? = nil) {
        self.editingCategory = editingCategory
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Category Information") {
                    TextField("Category Name", text: $categoryName)
                        //.textInputAutocapitalization(.words)
                }
                
                Section("Choose an Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 12) {
                        ForEach(commonIcons, id: \.self) { icon in
                            Button {
                                selectedIcon = icon
                            } label: {
                                Image(systemName: icon)
                                    .font(.title2)
                                    .frame(width: 40, height: 40)
                                    .background(
                                        selectedIcon == icon ?
                                        Color.accentColor.opacity(0.2) :
                                        Color.clear
                                    )
                                    .cornerRadius(8)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(
                                                selectedIcon == icon ? Color.accentColor : Color.clear,
                                                lineWidth: 2
                                            )
                                    )
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isEditing ? "Edit Category" : "Add Category")
            //.navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Update" : "Create") {
                        Task {
                            await saveCategory()
                        }
                    }
                    .disabled(categoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
            .task {
                if let category = editingCategory {
                    categoryName = category.name
                    selectedIcon = category.icon
                }
            }
            .alert("Error",
                   isPresented: .init(
                       get: { model.error != nil },
                       set: { if !$0 { model.error = nil } }
                   ),
                   actions: { Button("OK") { model.error = nil } },
                   message: { Text(model.error ?? "") }
            )
        }
    }
    
    @MainActor
    private func saveCategory() async {
        isSaving = true
        defer { isSaving = false }
        
        let trimmedName = categoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedIcon = selectedIcon.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !trimmedName.isEmpty && !trimmedIcon.isEmpty else { return }
        
        let success: Bool
        if let category = editingCategory {
            success = await model.updateCategory(id: category.id, name: trimmedName, icon: trimmedIcon)
        } else {
            success = await model.createCategory(name: trimmedName, icon: trimmedIcon)
        }
        
        if success {
            dismiss()
        }
    }
}

#Preview {
    NavigationStack {
        AddCategoryView()
    }
    .environmentObject(AppViewModel())
}
