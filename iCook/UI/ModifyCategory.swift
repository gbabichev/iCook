//
//  ModifyCategory.swift
//  iCook
//
//  Created by George Babichev on 9/16/25.
//

import SwiftUI
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

struct AddCategoryView: View {
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.dismiss) private var dismiss
    
    let editingCategory: Category?
    
    @State private var categoryName: String = ""
    @State private var selectedIcon: String = "🍴"
    @State private var isSaving = false
    @State private var isDeleting = false
    
    // Emoji icons grouped for quicker scanning
    private let iconGroups: [(title: String, icons: [String])] = [
        ("General", ["🍴", "🌱", "☕"]),
        ("Meals", ["🍔", "🍕", "🌮", "🌯", "🍣", "🍝", "🍜", "🍲", "🥘", "🍛", "🍱", "🍙", "🥟", "🥪"]),
        ("Proteins & Dairy", ["🐟", "🍗", "🍖", "🥩", "🥓", "🍤", "🧀", "🧈", "🍳"]),
        ("Produce", ["🧄", "🧅", "🥔", "🥕", "🥦", "🍄", "🌶️", "🍅", "🥑", "🍎", "🍋", "🍇", "🍓", "🫐", "🍌", "🫘"]),
        ("Baked & Desserts", ["🥐", "🍞", "🥖", "🧁", "🍰", "🍪", "🍩", "🍫", "🍨"])
    ]
    var isEditing: Bool { editingCategory != nil }

    private var trimmedCategoryName: String {
        categoryName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasDuplicateName: Bool {
        model.categories.contains {
            if let editingCategory, $0.id == editingCategory.id { return false }
            return $0.name.compare(trimmedCategoryName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    private var showDuplicateWarning: Bool {
        hasDuplicateName && !isSaving
    }

    private var editingCategoryRecipeCount: Int {
        guard let editingCategory else { return 0 }
        return model.recipeCounts[editingCategory.id] ?? 0
    }

    private var canDeleteCategory: Bool {
        canEdit && isEditing && editingCategoryRecipeCount == 0 && !isSaving && !isDeleting
    }
    
    init(editingCategory: Category? = nil) {
        self.editingCategory = editingCategory
    }
    
    var body: some View {
        Group {
#if os(macOS)
            macOSView
#else
            iOSView
#endif
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

    #if os(iOS)
    private var iOSView: some View {
        NavigationStack {
            Form {
                if model.currentSource == nil {
                    Section {
                        HStack {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundColor(.red)
                            Text("Please add a Source first, by clicking the Cloud icon in the toolbar.")
                                .foregroundColor(.red)
                        }
                    }
                } else if let source = model.currentSource, !model.canEditSource(source) {
                    Section {
                        HStack {
                            Image(systemName: "lock.fill")
                                .foregroundColor(.orange)
                            Text("This source is read-only")
                                .foregroundColor(.orange)
                        }
                    }
                }
                
                Section("Category Information") {
                    TextField("Category Name", text: $categoryName)
                        .iOSModernInputFieldStyle()
#if os(iOS)
                        .textInputAutocapitalization(.words)
#endif
                        .disabled(!canEdit)
                }

                Section {
                    Text("Organize recipes with category names and icons")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if showDuplicateWarning {
                    Section {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("A category with this name already exists.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                
                Section("Choose an Icon") {
                    iconPickerGrid
                    .padding(.vertical, 8)
                }

                if isEditing {
                    Section {
                        Button(role: .destructive) {
                            Task {
                                await deleteCategory()
                            }
                        } label: {
                            if isDeleting {
                                HStack {
                                    ProgressView()
                                    Text("Deleting...")
                                }
                            } else {
                                Text("Delete Category")
                            }
                        }
                        .disabled(!canDeleteCategory)
                    } footer: {
                        if editingCategoryRecipeCount > 0 {
                            Text("Move or delete the \(editingCategoryRecipeCount == 1 ? "recipe" : "recipes") in this category before deleting it.")
                        }
                    }
                }
            }
            .formStyle(.grouped)
#if os(iOS)
            .scrollDismissesKeyboard(.immediately)
#endif
            .navigationTitle(isEditing ? "Edit Category" : "Add Category")
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
                    .disabled(!canEdit || trimmedCategoryName.isEmpty || hasDuplicateName || isSaving || isDeleting)
                }
#if os(iOS)
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        dismissKeyboard()
                    }
                }
#endif
            }
        }
    }
    #endif

#if os(macOS)
    private var macOSView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "tray")
                    .font(.title2)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(isEditing ? "Edit Category" : "Add Category")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Organize recipes with category names and icons")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(isEditing ? "Update" : "Create") {
                    Task {
                        await saveCategory()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saveButtonDisabled)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    statusBanner

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Category Information")
                            .font(.headline)

                        TextField("Category Name", text: $categoryName)
                            .iOSModernInputFieldStyle()
                            .disabled(!canEdit)
                    }
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    if showDuplicateWarning {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("A category with this name already exists.")
                                .font(.callout)
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Choose an Icon")
                            .font(.headline)

                        iconPickerGrid
                    }
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    if isEditing {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Danger Zone")
                                .font(.headline)

                            Button(role: .destructive) {
                                Task {
                                    await deleteCategory()
                                }
                            } label: {
                                HStack {
                                    Spacer()
                                    if isDeleting {
                                        ProgressView()
                                            .controlSize(.small)
                                        Text("Deleting...")
                                    } else {
                                        Text("Delete Category")
                                            .fontWeight(.semibold)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .disabled(!canDeleteCategory)

                            if editingCategoryRecipeCount > 0 {
                                Text("Move or delete the \(editingCategoryRecipeCount == 1 ? "recipe" : "recipes") in this category before deleting it.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(14)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                .padding(16)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var statusBanner: some View {
        if model.currentSource == nil {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.red)
                Text("Create a collection first before adding categories.")
                    .font(.callout)
            }
            .padding(12)
            .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        } else if let source = model.currentSource, !model.canEditSource(source) {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .foregroundColor(.orange)
                Text("This collection is read-only.")
                    .font(.callout)
            }
            .padding(12)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }
    }
#endif

    private var iconPickerGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(iconGroups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 12) {
                        ForEach(group.icons, id: \.self) { icon in
                            Button {
                                selectedIcon = icon
                            } label: {
                                Text(icon)
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
                            .buttonStyle(.plain)
                            .disabled(!canEdit)
                        }
                    }
                }
            }
        }
    }

    #if os(macOS)
    private var saveButtonDisabled: Bool {
        !canEdit || trimmedCategoryName.isEmpty || hasDuplicateName || isSaving || isDeleting
    }
    #endif
    
    private var canEdit: Bool {
        guard let source = model.currentSource else { return false }
        return model.canEditSource(source)
    }
    
    @MainActor
    private func saveCategory() async {
        isSaving = true
        
        let trimmedName = trimmedCategoryName
        let trimmedIcon = selectedIcon.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !trimmedName.isEmpty && !trimmedIcon.isEmpty && !hasDuplicateName else {
            isSaving = false
            return
        }
        
        let success: Bool
        if let category = editingCategory {
            success = await model.updateCategory(id: category.id, name: trimmedName, icon: trimmedIcon)
        } else {
            success = await model.createCategory(name: trimmedName, icon: trimmedIcon)
        }
        
        if success {
            dismiss()
            return
        }

        isSaving = false
    }

    @MainActor
    private func deleteCategory() async {
        guard let category = editingCategory else { return }
        guard editingCategoryRecipeCount == 0 else { return }

        isDeleting = true
        await model.deleteCategory(id: category.id)

        if model.error == nil {
            dismiss()
            return
        }

        isDeleting = false
    }

#if os(iOS)
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
#endif
}
