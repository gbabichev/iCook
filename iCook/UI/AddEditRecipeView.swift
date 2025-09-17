import SwiftUI
#if os(iOS)
import PhotosUI
import UIKit
#else
import AppKit
import UniformTypeIdentifiers
#endif

struct AddEditRecipeView: View {
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.dismiss) private var dismiss
    
    let editingRecipe: Recipe?
    
    @State private var selectedCategoryId: Int = 1
    @State private var recipeName: String = ""
    @State private var recipeTime: String = ""
    @State private var recipeDetails: String = ""
    @State private var showingImagePicker = false
    @State private var selectedImageData: Data?
    @State private var existingImagePath: String?
    @State private var isUploading = false
    @State private var isSaving = false
    
    var isEditing: Bool { editingRecipe != nil }
    
    init(editingRecipe: Recipe? = nil) {
        self.editingRecipe = editingRecipe
    }
    
    var body: some View {
                
        NavigationStack {
            Form {
                Section("Basic Information") {
                    // Category Picker
                    Picker("Category", selection: $selectedCategoryId) {
                        ForEach(model.categories) { category in
                            Text(category.name).tag(category.id)
                        }
                    }
                    .pickerStyle(.menu)
                    
                    // Recipe Name
                    TextField("Recipe Name", text: $recipeName)
                        //.textInputAutocapitalization(.words)
                    
                    // Recipe Time
                    HStack {
                        TextField("Cooking Time", text: $recipeTime)
                            //.keyboardType(.numberPad)
                        Text("minutes")
                            .foregroundStyle(.secondary)
                    }
                }
                
                Section("Image") {
                    VStack(alignment: .leading, spacing: 12) {
                        // File Picker Button
                        Button {
                            showingImagePicker = true
                        } label: {
                            HStack {
                                Image(systemName: "photo.badge.plus")
                                Text(selectedImageData != nil ? "Change Photo" : "Add Photo")
                            }
                        }
                        
                        // Image Preview
                        if let imageData = selectedImageData {
                            Group {
                                #if os(iOS)
                                if let uiImage = UIImage(data: imageData) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(height: 200)
                                        .clipped()
                                        .cornerRadius(8)
                                } else {
                                    placeholderImageView
                                }
                                #else
                                if let nsImage = NSImage(data: imageData) {
                                    Image(nsImage: nsImage)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(height: 200)
                                        .clipped()
                                        .cornerRadius(8)
                                } else {
                                    placeholderImageView
                                }
                                #endif
                            }
                        }else if let imagePath = existingImagePath {
                            AsyncImage(url: imageURL(from: imagePath)) { phase in
                                switch phase {
                                case .success(let image):
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(height: 200)
                                        .clipped()
                                        .cornerRadius(8)
                                case .failure(_):
                                    Rectangle()
                                        .fill(.gray.opacity(0.2))
                                        .frame(height: 200)
                                        .cornerRadius(8)
                                        .overlay {
                                            Image(systemName: "photo")
                                                .foregroundStyle(.secondary)
                                        }
                                case .empty:
                                    Rectangle()
                                        .fill(.gray.opacity(0.2))
                                        .frame(height: 200)
                                        .cornerRadius(8)
                                        .overlay {
                                            ProgressView()
                                        }
                                @unknown default:
                                    EmptyView()
                                }
                            }
                        }
                        
                        if isUploading {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Uploading image...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                
                Section("Recipe Details") {
                    TextField(
                        "",
                        text: $recipeDetails,
                        axis: .vertical
                    )
                    .lineLimit(8...20)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isEditing ? "Edit Recipe" : "Add Recipe")
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
                            await saveRecipe()
                        }
                    }
                    .disabled(recipeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
            .task {
                // Load categories if empty
                if model.categories.isEmpty {
                    await model.loadCategories()
                }
                
                // Setup for editing
                if let recipe = editingRecipe {
                    selectedCategoryId = recipe.category_id
                    recipeName = recipe.name
                    recipeTime = String(recipe.recipe_time)
                    recipeDetails = recipe.details ?? ""
                    existingImagePath = recipe.image
                } else if !model.categories.isEmpty {
                    selectedCategoryId = model.categories.first?.id ?? 1
                }
            }
            .onChange(of: showingImagePicker) { _, isShowing in
                // Handle file picker result if needed
            }
            .fileImporter(
                isPresented: $showingImagePicker,
                allowedContentTypes: [.image],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        loadImageFromURL(url)
                    }
                case .failure(let error):
                    print("Failed to pick image: \(error)")
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
    
    private var placeholderImageView: some View {
        Rectangle()
            .fill(.gray.opacity(0.2))
            .frame(height: 200)
            .cornerRadius(8)
            .overlay {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
    }
    
    private func imageURL(from path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        var comps = URLComponents(url: APIConfig.base, resolvingAgainstBaseURL: false)
        comps?.query = nil
        comps?.path = path.hasPrefix("/") ? path : "/" + path
        return comps?.url
    }
    
    private func loadImageFromURL(_ url: URL) {
        Task {
            isUploading = true
            defer { isUploading = false }
            
            do {
                let data = try Data(contentsOf: url)
                await MainActor.run {
                    selectedImageData = data
                    existingImagePath = nil
                }
            } catch {
                print("Failed to load image from URL: \(error)")
            }
        }
    }
    
    @MainActor
    private func saveRecipe() async {
        isSaving = true
        defer { isSaving = false }
        
        let trimmedName = recipeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        
        let timeValue = Int(recipeTime.trimmingCharacters(in: .whitespacesAndNewlines))
        let trimmedDetails = recipeDetails.trimmingCharacters(in: .whitespacesAndNewlines)
        let detailsToSave = trimmedDetails.isEmpty ? nil : trimmedDetails
        
        var imagePathToSave = existingImagePath
        
        // Upload new image if selected
        if let imageData = selectedImageData {
            let fileName = "recipe_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(8)).jpg"
            if let uploadedPath = await model.uploadImage(imageData: imageData, fileName: String(fileName)) {
                imagePathToSave = uploadedPath
            } else {
                // Upload failed, but continue anyway
                print("Image upload failed, continuing without image")
            }
        }
        
        let success: Bool
        if let recipe = editingRecipe {
            // Update existing recipe
            success = await model.updateRecipe(
                id: recipe.id,
                categoryId: selectedCategoryId != recipe.category_id ? selectedCategoryId : nil,
                name: trimmedName != recipe.name ? trimmedName : nil,
                recipeTime: timeValue != recipe.recipe_time ? timeValue : nil,
                details: detailsToSave != recipe.details ? detailsToSave : nil,
                image: imagePathToSave != recipe.image ? imagePathToSave : nil
            )
        } else {
            // Create new recipe
            success = await model.createRecipe(
                categoryId: selectedCategoryId,
                name: trimmedName,
                recipeTime: timeValue,
                details: detailsToSave,
                image: imagePathToSave
            )
        }
        
        if success {
            dismiss()
        }
    }
}
