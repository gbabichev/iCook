//
//  ModifyCategory.swift
//  iCook
//
//  Created by George Babichev on 9/16/25.
//

import SwiftUI

// MARK: - Icon Selection Grid
struct IconSelectionGrid: View {
    @Binding var selectedIcon: String
    
    private let iconOptions = [
        "fork.knife", "cup.and.saucer", "birthday.cake", "carrot",
        "leaf", "fish", "popcorn", "wineglass", "mug.fill",
        "takeoutbag.and.cup.and.straw", "refrigerator", "cooktop",
        "flame", "drop", "snowflake", "sun.max", "moon",
        "star", "heart", "house"
    ]
    
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 16) {
            ForEach(iconOptions, id: \.self) { icon in
                IconButton(icon: icon, isSelected: selectedIcon == icon) {
                    selectedIcon = icon
                }
            }
        }
        .padding(.vertical, 8)
    }
}

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
    @State private var categoryName = ""
    @State private var selectedIcon = "fork.knife"
    @State private var isCreating = false
    
    let editingCategory: Category?
    
    init(editingCategory: Category? = nil) {
        self.editingCategory = editingCategory
    }
    
    private var isEditing: Bool {
        editingCategory != nil
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                // Subtle background for a more "carded" form look on iOS
                #if os(iOS)
                Color(.systemGroupedBackground).ignoresSafeArea()
                #endif

                Form {
                    Section("Category Name") {
                        TextField("Enter category name", text: $categoryName)
                            .submitLabel(.done)
                            .onSubmit {
                                let trimmed = categoryName.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmed.isEmpty && !isCreating { saveCategory() }
                            }
                        #if os(iOS)
                            .textInputAutocapitalization(.words)
                        #endif
                            .disableAutocorrection(true)
                            .accessibilityLabel("Category name")
                            .accessibilityHint("Enter a short, descriptive name")
                            .padding(.vertical, 6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(.red, lineWidth: 2)
                                    .opacity(categoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 1 : 0)
                            )
                            .animation(.easeInOut(duration: 0.15), value: categoryName)
                    }

                    Section("Icon") {
                        IconSelectionGrid(selectedIcon: $selectedIcon)
                            .accessibilityLabel("Icon picker")
                    }
                }
                .scrollContentBackground(.hidden) // lets our background show through
                .formStyle(.grouped)
            }
            .navigationTitle(isEditing ? "Edit Category" : "Add Category")
            .toolbar {
                // iOS keyboard dismiss
                #if os(iOS)
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                }
                #endif

                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isCreating)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        saveCategory()
                    } label: {
                        if isCreating {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Save")
                                .fontWeight(.semibold)
                        }
                    }
                    .keyboardShortcut(.defaultAction) // macOS default ⌘ action; harmless on iOS
                    .disabled(categoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreating)
                }
            }
        }
        .interactiveDismissDisabled(isCreating) // don't swipe-dismiss mid-save
        .disabled(isCreating) // prevent taps while saving
        .overlay {
            // Dimmed progress overlay with a smooth fade
            if isCreating {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                            .progressViewStyle(.circular)
                        Text(isEditing ? "Updating…" : "Creating…")
                            .font(.callout)
                            .foregroundStyle(.primary)
                    }
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .transition(.opacity.combined(with: .scale))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isCreating)
        .onAppear {
            if let category = editingCategory {
                categoryName = category.name
                selectedIcon = category.icon
            }
        }
    }
    
    private func saveCategory() {
        Task {
            await saveCategoryAsync()
        }
    }
    
    @MainActor
    private func saveCategoryAsync() async {
        isCreating = true
        defer { isCreating = false }
        
        do {
            let success: Bool
            if let category = editingCategory {
                success = await model.updateCategory(id: category.id, name: categoryName.trimmingCharacters(in: .whitespacesAndNewlines), icon: selectedIcon)
            } else {
                success = await model.createCategory(name: categoryName.trimmingCharacters(in: .whitespacesAndNewlines), icon: selectedIcon)
            }
            
            if success {
                dismiss()
            }
        }
    }
}

