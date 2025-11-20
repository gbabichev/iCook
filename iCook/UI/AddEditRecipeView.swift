import SwiftUI
import Combine
import CloudKit
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
    let preselectedCategoryId: CKRecord.ID?

    @State private var selectedCategoryId: CKRecord.ID?
    @State private var recipeName: String = ""
    @State private var recipeTime: String = ""
    @State private var recipeDetails: String = ""
    @State private var showingImagePicker = false
    @State private var selectedImageData: Data?
    @State private var existingImagePath: String?
    @State private var isUploading = false
    @State private var isSaving = false
    @State private var fileImporterTrigger = UUID()
    @State private var isCompressingImage = false
    @State private var saveErrorMessage: String?

    // Recipe Steps
    @State private var recipeSteps: [RecipeStep] = []
    @State private var expandedSteps: Set<Int> = []
    
    // Legacy ingredients (for backward compatibility)
    @State private var legacyIngredients: [String] = []
    @State private var newLegacyIngredient: String = ""
    @State private var showingLegacySection = false
    
    // iOS specific photo states
#if os(iOS)
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showingImageActionSheet = false
    @State private var showingCamera = false
#endif
    
    private var isFormValid: Bool {
        let nameValid = !recipeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let timeValid = !recipeTime.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                        Int(recipeTime.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
        return nameValid && timeValid
    }

    private var canEdit: Bool {
        guard let source = model.currentSource else { return false }
        return model.canEditSource(source)
    }

    var isEditing: Bool { editingRecipe != nil }
    
    init(editingRecipe: Recipe? = nil, preselectedCategoryId: CKRecord.ID? = nil) {
        self.editingRecipe = editingRecipe
        self.preselectedCategoryId = preselectedCategoryId
    }
    
    var body: some View {
        NavigationStack {
            Form {
                if let source = model.currentSource, !model.canEditSource(source) {
                    Section {
                        HStack {
                            Image(systemName: "lock.fill")
                                .foregroundColor(.orange)
                            Text("This source is read-only")
                                .foregroundColor(.orange)
                        }
                    }
                }

                if let errorMessage = saveErrorMessage {
                    Section {
                        HStack {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundColor(.red)
                            Text(errorMessage)
                                .foregroundColor(.red)
                        }
                    }
                }

                Section("Basic Information") {
                    // Category Picker
                    if !model.categories.isEmpty {
                        Picker("Category", selection: $selectedCategoryId) {
                            ForEach(model.categories) { category in
                                Text(category.name).tag(category.id as CKRecord.ID?)
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(!canEdit)
                    } else {
                        Text("No categories available")
                            .foregroundStyle(.secondary)
                    }

                    // Recipe Name - REQUIRED
                    TextField("Recipe Name *", text: $recipeName)
                        .disabled(!canEdit)

                    // Recipe Time - REQUIRED
                    HStack {
                        TextField("Cooking Time *", text: $recipeTime)
                            .disabled(!canEdit)
                        Text("minutes")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Image") {
                    imageSection.disabled(!canEdit)
                }

                // Recipe Steps Section
                Section {
                    VStack(alignment: .leading, spacing: 16) {

                        HStack {
                            Text("Recipe Steps")
                                .font(.headline)
                            Spacer()
                            Button("Add Step") {
                                addNewStep()
                            }
                            .buttonStyle(.bordered)
                            .disabled(!canEdit)
                        }
                        
                        if recipeSteps.isEmpty {
                            Text("No steps added yet. Add steps to structure your recipe with ingredients for each step.")
                                .font(.caption)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(Array(recipeSteps.enumerated()), id: \.element.stepNumber) { index, step in
                                StepEditView(
                                    step: Binding(
                                        get: { recipeSteps[index] },
                                        set: { recipeSteps[index] = $0 }
                                    ),
                                    stepNumber: step.stepNumber,
                                    onDelete: { deleteStep(at: index) },
                                    isExpanded: Binding(
                                        get: { expandedSteps.contains(step.stepNumber) },
                                        set: { isExpanded in
                                            if isExpanded {
                                                expandedSteps.insert(step.stepNumber)
                                            } else {
                                                expandedSteps.remove(step.stepNumber)
                                            }
                                        }
                                    )
                                )
                            }
                            .onMove(perform: moveSteps)
                        }
                    }
                } header: {
                    HStack {
                        Text("Recipe Steps")
                        Spacer()
                        if !recipeSteps.isEmpty {
                            Text("\(recipeSteps.count) steps")
                                .font(.caption)
                        }
                    }
                }
                
            }
            .formStyle(.grouped)
            .navigationTitle(isEditing ? "Edit Recipe" : "Add Recipe")
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
                    .disabled(!isFormValid || isSaving || !canEdit)
                }
            }
            .task {
                await initializeView()
            }
            .onChange(of: model.categories) { _, newCategories in
                handleCategoryChanges(newCategories)
            }
            // Photo picker implementations (keeping your existing implementations)
            // iOS specific photo handling
#if os(iOS)
            .photosPicker(
                isPresented: $showingImagePicker,
                selection: $selectedPhotoItem,
                matching: .images
            )
            .onChange(of: selectedPhotoItem) { _, newItem in
                Task {
                    guard let newItem = newItem else { return }
                    
                    await MainActor.run {
                        isUploading = true
                        isCompressingImage = true
                    }
                    
                    defer {
                        Task { @MainActor in
                            isUploading = false
                            isCompressingImage = false
                        }
                    }
                    
                    do {
                        guard let originalData = try await newItem.loadTransferable(type: Data.self) else {
                            return
                        }
                        
                        print("[Image] Loaded \(Int(Double(originalData.count) / 1024.0))KB from photo picker")
                        let compressedData = await compressImageInBackground(originalData)
                        
                        await MainActor.run {
                            if let compressed = compressedData {
                                selectedImageData = compressed
                                existingImagePath = nil
                                print("[Image] Stored compressed image: \(Int(Double(compressed.count) / 1024.0))KB")
                            } else {
                                selectedImageData = originalData
                                existingImagePath = nil
                            }
                        }
                    } catch {
                        print("Failed to load photo: \(error)")
                    }
                }
            }
            .fullScreenCover(isPresented: $showingCamera) {
                CameraView { image in
                    Task {
                        await MainActor.run {
                            isUploading = true
                            isCompressingImage = true
                        }
                        
                        defer {
                            Task { @MainActor in
                                isUploading = false
                                isCompressingImage = false
                            }
                        }
                        
                        guard let originalData = image.jpegData(compressionQuality: 0.95) else {
                            return
                        }
                        
                        print("[Camera] Captured \(Int(Double(originalData.count) / 1024.0))KB image")
                        let compressedData = await compressImageInBackground(originalData)
                        
                        await MainActor.run {
                            if let compressed = compressedData {
                                selectedImageData = compressed
                                existingImagePath = nil
                            } else {
                                selectedImageData = originalData
                                existingImagePath = nil
                            }
                        }
                    }
                }
            }
#else
            .fileImporter(
                isPresented: $showingImagePicker,
                allowedContentTypes: [.image],
                allowsMultipleSelection: false
            ) { result in
                showingImagePicker = false
                
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        loadImageFromURL(url)
                    }
                case .failure(let error):
                    print("Failed to pick image: \(error)")
                }
            }
            .id(fileImporterTrigger)
#endif
//            .alert("Error", isPresented: .init(
//                get: { model.error != nil },
//                set: { if !$0 { model.error = nil } }
//            )) {
//                Button("OK") { model.error = nil }
//            } message: {
//                Text(model.error ?? "")
//            }
        }
    }
    
    // MARK: - Step Management
    
    private func addNewStep() {
        let newStepNumber = (recipeSteps.map(\.stepNumber).max() ?? 0) + 1
        let newStep = RecipeStep(
            stepNumber: newStepNumber,
            instruction: "",
            ingredients: []
        )
        recipeSteps.append(newStep)
        expandedSteps.insert(newStepNumber)
    }
    
    private func deleteStep(at index: Int) {
        guard index < recipeSteps.count else { return }
        let stepNumber = recipeSteps[index].stepNumber
        recipeSteps.remove(at: index)
        expandedSteps.remove(stepNumber)
        
        // Renumber remaining steps
        for i in 0..<recipeSteps.count {
            recipeSteps[i] = RecipeStep(
                stepNumber: i + 1,
                instruction: recipeSteps[i].instruction,
                ingredients: recipeSteps[i].ingredients
            )
        }
        
        // Update expanded set with new numbers
        expandedSteps = Set(expandedSteps.compactMap { oldNumber in
            guard oldNumber > stepNumber else { return oldNumber }
            return oldNumber - 1
        })
    }
    
    private func moveSteps(from source: IndexSet, to destination: Int) {
        recipeSteps.move(fromOffsets: source, toOffset: destination)
        
        // Renumber all steps after reordering
        for i in 0..<recipeSteps.count {
            recipeSteps[i] = RecipeStep(
                stepNumber: i + 1,
                instruction: recipeSteps[i].instruction,
                ingredients: recipeSteps[i].ingredients
            )
        }
        
        // Preserve expanded state - just keep the current expanded set
        // since we've renumbered everything sequentially
    }
    
    // MARK: - Legacy Ingredient Management
    
    private func addLegacyIngredient() {
        let trimmed = newLegacyIngredient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        if !legacyIngredients.contains(where: { $0.lowercased() == trimmed.lowercased() }) {
            legacyIngredients.append(trimmed)
            newLegacyIngredient = ""
        } else {
            newLegacyIngredient = ""
        }
    }
    
    private func deleteLegacyIngredients(at offsets: IndexSet) {
        legacyIngredients.remove(atOffsets: offsets)
    }
    
    private func moveLegacyIngredients(from source: IndexSet, to destination: Int) {
        legacyIngredients.move(fromOffsets: source, toOffset: destination)
    }
    
    private func convertLegacyIngredientsToSteps() {
        guard !legacyIngredients.isEmpty else { return }
        
        if recipeSteps.isEmpty {
            // Create first step with all legacy ingredients
            let newStep = RecipeStep(
                stepNumber: 1,
                instruction: "Follow recipe instructions",
                ingredients: legacyIngredients
            )
            recipeSteps.append(newStep)
            expandedSteps.insert(1)
        } else {
            // Add to first step
            recipeSteps[0] = RecipeStep(
                stepNumber: recipeSteps[0].stepNumber,
                instruction: recipeSteps[0].instruction,
                ingredients: recipeSteps[0].ingredients + legacyIngredients
            )
        }
        
        legacyIngredients.removeAll()
        showingLegacySection = false
    }
    
    // MARK: - Initialization and State Management
    
    private func initializeView() async {
        if model.categories.isEmpty {
            await model.loadCategories()
        }

        if !isEditing, selectedCategoryId == nil {
            if let preselected = preselectedCategoryId, model.categories.contains(where: { $0.id == preselected }) {
                selectedCategoryId = preselected
            } else if let firstId = model.categories.first?.id {
                selectedCategoryId = firstId
            }
        }
        
        if let recipe = editingRecipe {
            selectedCategoryId = recipe.categoryID
            recipeName = recipe.name
            recipeTime = String(recipe.recipeTime)
            recipeDetails = recipe.details ?? ""
            // existingImagePath is no longer used with CloudKit assets

            // Load recipe steps
            if !recipe.recipeSteps.isEmpty {
                recipeSteps = recipe.recipeSteps
                // Expand first step by default
                if let firstStep = recipe.recipeSteps.first {
                    expandedSteps.insert(firstStep.stepNumber)
                }
            }

            // Load legacy ingredients (for recipes that haven't been converted yet)
            if let ingredients = recipe.ingredients, !ingredients.isEmpty {
                // Check if ingredients are already in steps
                let allStepIngredients = Set(recipeSteps.flatMap(\.ingredients))
                let uniqueLegacyIngredients = ingredients.filter { !allStepIngredients.contains($0) }

                if !uniqueLegacyIngredients.isEmpty {
                    legacyIngredients = uniqueLegacyIngredients
                    showingLegacySection = true
                }
            }
        }
    }
    
    private func handleCategoryChanges(_ newCategories: [Category]) {
        let ids = Set(newCategories.map { $0.id })

        if isEditing {
            if let recipe = editingRecipe, !ids.contains(recipe.categoryID) {
                selectedCategoryId = newCategories.first?.id
            }
        } else {
            if selectedCategoryId == nil {
                if let preselected = preselectedCategoryId, ids.contains(preselected) {
                    selectedCategoryId = preselected
                } else {
                    selectedCategoryId = newCategories.first?.id
                }
            } else if let categoryId = selectedCategoryId, !ids.contains(categoryId) {
                if let preselected = preselectedCategoryId, ids.contains(preselected) {
                    selectedCategoryId = preselected
                } else {
                    selectedCategoryId = newCategories.first?.id
                }
            }
        }
    }
    
    // MARK: - Save Recipe
    
    @MainActor
    private func saveRecipe() async {
        isSaving = true
        saveErrorMessage = nil // Clear previous error messages
        defer { isSaving = false }
        
        let trimmedName = recipeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTime = recipeTime.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !trimmedName.isEmpty else { return }
        guard !trimmedTime.isEmpty, let timeValue = Int(trimmedTime) else { return }
        
        let trimmedDetails = recipeDetails.trimmingCharacters(in: .whitespacesAndNewlines)
        let detailsToSave = trimmedDetails.isEmpty ? nil : trimmedDetails
        
        // Process recipe steps
        let processedSteps: [RecipeStep] = recipeSteps.compactMap { step -> RecipeStep? in
            let trimmedInstruction = step.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            let processedIngredients = step.ingredients
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            
            guard !trimmedInstruction.isEmpty || !processedIngredients.isEmpty else { return nil }
            
            return RecipeStep(
                stepNumber: step.stepNumber,
                instruction: trimmedInstruction.isEmpty ? "Step \(step.stepNumber)" : trimmedInstruction,
                ingredients: processedIngredients
            )
        }
        
        // Process legacy ingredients
        let processedLegacyIngredients = legacyIngredients
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        // Combine processed steps with legacy ingredients if needed
        let finalSteps: [RecipeStep]
        if !processedLegacyIngredients.isEmpty && !processedSteps.isEmpty {
            // Add legacy ingredients to the first step
            var steps = processedSteps
            steps[0] = RecipeStep(
                stepNumber: steps[0].stepNumber,
                instruction: steps[0].instruction,
                ingredients: steps[0].ingredients + processedLegacyIngredients
            )
            finalSteps = steps
        } else if !processedLegacyIngredients.isEmpty {
            // Create a single step with legacy ingredients
            finalSteps = [RecipeStep(
                stepNumber: 1,
                instruction: "Follow recipe instructions",
                ingredients: processedLegacyIngredients
            )]
        } else {
            finalSteps = processedSteps
        }
        
        guard let categoryId = selectedCategoryId else {
            return // Category is required
        }

        let success: Bool
        if let recipe = editingRecipe {
            print("DEBUG: Saving recipe - UPDATE mode. Recipe ID: \(recipe.id.recordName)")
            success = await model.updateRecipeWithSteps(
                id: recipe.id,
                categoryId: selectedCategoryId != recipe.categoryID ? selectedCategoryId : nil,
                name: trimmedName != recipe.name ? trimmedName : nil,
                recipeTime: timeValue != recipe.recipeTime ? timeValue : nil,
                details: detailsToSave != recipe.details ? detailsToSave : nil,
                image: selectedImageData,
                recipeSteps: finalSteps
            )
            print("DEBUG: Update result: \(success)")
        } else {
            print("DEBUG: Saving recipe - CREATE mode")
            success = await model.createRecipeWithSteps(
                categoryId: categoryId,
                name: trimmedName,
                recipeTime: timeValue,
                details: detailsToSave,
                image: selectedImageData,
                recipeSteps: finalSteps
            )
            print("DEBUG: Create result: \(success)")
        }

        if success {
            dismiss()
        } else {
            print("DEBUG: Save failed - not dismissing. Model error: \(model.error ?? "nil")")
            if let modelError = model.error {
                saveErrorMessage = "Failed to save recipe: \(modelError)"
            } else if isEditing {
                saveErrorMessage = "Failed to update recipe. Please try again or check the console for details."
            } else {
                saveErrorMessage = "Failed to create recipe. Please try again or check the console for details."
            }
        }
    }
    
    // MARK: - Image Section
    
    private var imageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Photo Picker Button
#if os(iOS)
            Button {
                showingImageActionSheet = true
            } label: {
                HStack {
                    Image(systemName: "photo.badge.plus")
                    Text((selectedImageData != nil || existingImagePath != nil) ? "Change Photo" : "Add Photo")
                }
            }
            .confirmationDialog("Add Photo", isPresented: $showingImageActionSheet) {
                Button("Take Photo") {
                    showingCamera = true
                }
                Button("Choose from Library") {
                    showingImagePicker = true
                }
                if selectedImageData != nil || existingImagePath != nil {
                    Button("Remove Photo", role: .destructive) {
                        selectedImageData = nil
                        existingImagePath = nil
                    }
                }
                Button("Cancel", role: .cancel) { }
            }
#else
            // macOS File Picker Button
            Button {
                fileImporterTrigger = UUID()
                showingImagePicker = true
            } label: {
                HStack {
                    Image(systemName: "photo.badge.plus")
                    Text((selectedImageData != nil || existingImagePath != nil) ? "Change Photo" : "Add Photo")
                }
            }
            .buttonStyle(.bordered)
            .contentShape(Rectangle())
            .zIndex(1)
            .allowsHitTesting(true)
            .frame(maxWidth: .infinity, alignment: .leading)
            
            // Add Remove Photo option for macOS when there's an image
            if selectedImageData != nil || existingImagePath != nil {
                Button("Remove Photo", role: .destructive) {
                    selectedImageData = nil
                    existingImagePath = nil
                }
                .buttonStyle(.bordered)
                .zIndex(1)
                .allowsHitTesting(true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
#endif
            
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
                            .zIndex(0)
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
                            .zIndex(0)
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
            
            if isUploading || isCompressingImage {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text(isCompressingImage ? "Compressing image..." : "Uploading image...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
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
        // CloudKit assets don't use URL paths
        // This is kept for backward compatibility but no longer functional
        return nil
    }
    
    private func loadImageFromURL(_ url: URL) {
        Task {
            isUploading = true
            isCompressingImage = true
            defer {
                isUploading = false
                isCompressingImage = false
            }
            
#if os(macOS)
            let didStartAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccess { url.stopAccessingSecurityScopedResource() }
            }
#endif
            
            do {
                let originalData = try Data(contentsOf: url, options: .mappedIfSafe)
                print("[Image] Loaded \(Int(Double(originalData.count) / 1024.0))KB from file")
                
                let compressedData = await compressImageInBackground(originalData)
                
                await MainActor.run {
                    if let compressed = compressedData {
                        selectedImageData = compressed
                        existingImagePath = nil
                        print("[Image] Stored compressed image in memory: \(Int(Double(compressed.count) / 1024.0))KB")
                    } else {
                        print("[Image] Compression failed, storing original")
                        selectedImageData = originalData
                        existingImagePath = nil
                    }
                }
                
            } catch {
                print("Failed to load image from URL: \(error)")
                await MainActor.run {
                    // Could show an error alert here
                }
            }
        }
    }
    
    // Background compression function
    private func compressImageInBackground(_ data: Data, maxDimension: CGFloat = 1600, quality: CGFloat = 0.7) async -> Data? {
#if os(iOS)
        return await MainActor.run {
            return compressImageData(data, maxDimension: maxDimension, quality: quality)
        }
#else
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = compressImageData(data, maxDimension: maxDimension, quality: quality)
                continuation.resume(returning: result)
            }
        }
#endif
    }
    
    // Cross-platform image compression helper
#if os(iOS)
    nonisolated private func compressImageData(_ data: Data, maxDimension: CGFloat = 1600, quality: CGFloat = 0.7) -> Data? {
        guard let image = UIImage(data: data) else {
            print("[Compression] Failed to create UIImage from data")
            return nil
        }
        
        let originalSize = image.size
        let scale = image.scale
        print("[Compression] Original image size: \(originalSize), scale: \(scale)")
        
        let maxSide = max(originalSize.width, originalSize.height)
        let needsResize = maxSide > maxDimension
        let targetSize: CGSize
        
        if needsResize {
            let scaleRatio = maxDimension / maxSide
            targetSize = CGSize(width: originalSize.width * scaleRatio, height: originalSize.height * scaleRatio)
            print("[Compression] Scale ratio: \(scaleRatio), target size: \(targetSize)")
        } else {
            targetSize = originalSize
            print("[Compression] No resize needed, original size: \(originalSize)")
        }
        
        // Create the final image with explicit scale
        let finalImage: UIImage
        if needsResize {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1.0 // Force scale to 1.0
            let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
            finalImage = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: targetSize))
            }
            print("[Compression] Rendered image size: \(finalImage.size), scale: \(finalImage.scale)")
        } else {
            finalImage = image
        }
        
        // Always apply JPEG compression
        guard let compressedData = finalImage.jpegData(compressionQuality: quality) else {
            print("[Compression] Failed to create JPEG data")
            return nil
        }
        
        let originalKB = Double(data.count) / 1024.0
        let compressedKB = Double(compressedData.count) / 1024.0
        print("[Compression] \(Int(originalKB))KB → \(Int(compressedKB))KB (quality: \(quality))")
        
        return compressedData
    }
#else
    nonisolated private func compressImageData(_ data: Data, maxDimension: CGFloat = 1600, quality: CGFloat = 0.7) -> Data? {
        guard let nsImage = NSImage(data: data) else {
            print("[Compression] Failed to create NSImage from data")
            return nil
        }
        
        let originalSize = nsImage.size
        let maxSide = max(originalSize.width, originalSize.height)
        
        let needsResize = maxSide > maxDimension
        let targetSize: NSSize
        
        if needsResize {
            let scale = maxDimension / maxSide
            targetSize = NSSize(width: originalSize.width * scale, height: originalSize.height * scale)
            print("[Compression] Resizing from \(originalSize) to \(targetSize)")
        } else {
            targetSize = originalSize
            print("[Compression] No resize needed, original size: \(originalSize)")
        }
        
        guard let originalRep = NSBitmapImageRep(data: data) ?? nsImage.representations.first as? NSBitmapImageRep else {
            print("[Compression] Failed to get bitmap representation")
            return nil
        }
        
        let finalRep: NSBitmapImageRep
        
        if needsResize {
            let pixelsWide = Int(targetSize.width)
            let pixelsHigh = Int(targetSize.height)
            
            guard let resizedRep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelsWide,
                pixelsHigh: pixelsHigh,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bitmapFormat: [],
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else {
                print("[Compression] Failed to create resized bitmap rep")
                return nil
            }
            
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: resizedRep)
            NSGraphicsContext.current?.imageInterpolation = .high
            
            nsImage.draw(
                in: NSRect(origin: .zero, size: targetSize),
                from: NSRect(origin: .zero, size: originalSize),
                operation: .copy,
                fraction: 1.0
            )
            
            NSGraphicsContext.restoreGraphicsState()
            finalRep = resizedRep
        } else {
            finalRep = originalRep
        }
        
        guard let compressedData = finalRep.representation(
            using: .jpeg,
            properties: [.compressionFactor: quality]
        ) else {
            print("[Compression] Failed to create JPEG representation")
            return nil
        }
        
        let originalKB = Double(data.count) / 1024.0
        let compressedKB = Double(compressedData.count) / 1024.0
        print("[Compression] \(Int(originalKB))KB → \(Int(compressedKB))KB (quality: \(quality))")
        
        return compressedData
    }
#endif
}

// MARK: - Step Edit View

struct StepEditView: View {
    @Binding var step: RecipeStep
    let stepNumber: Int
    let onDelete: () -> Void
    @Binding var isExpanded: Bool
    
    @State private var newIngredient: String = ""
    @FocusState private var isInstructionFocused: Bool
    @FocusState private var isNewIngredientFocused: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Step Header
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        Text("Step \(stepNumber)")
                            .font(.headline)
                        
                        if !step.ingredients.isEmpty {
                            Text("(\(step.ingredients.count) ingredients)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    // Step Instruction
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Instructions:")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        
                        TextField("",text: .init(
                            get: { step.instruction },
                            set: { newValue in
                                step = RecipeStep(
                                    stepNumber: step.stepNumber,
                                    instruction: newValue,
                                    ingredients: step.ingredients
                                )
                            }
                        ), axis: .vertical)
                        .focused($isInstructionFocused)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...6)
                    }
                    
                    // Step Ingredients
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ingredients:")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        
                        // Add ingredient field
                        HStack {
                            TextField("Add ingredient for step \(stepNumber)", text: $newIngredient)
                                .focused($isNewIngredientFocused)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit {
                                    addIngredient()
                                }
                            
                            Button("Add") {
                                addIngredient()
                            }
                            .buttonStyle(.bordered)
                            .disabled(newIngredient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        
                        // Current ingredients
                        if !step.ingredients.isEmpty {
                            ForEach(Array(step.ingredients.enumerated()), id: \.offset) { index, ingredient in
                                HStack {
                                    Text("•")
                                        .foregroundStyle(.secondary)
                                    
                                    TextField("Ingredient", text: .init(
                                        get: { ingredient },
                                        set: { newValue in
                                            updateIngredient(at: index, with: newValue)
                                        }
                                    ))
                                    .textFieldStyle(.roundedBorder)
                                    
                                    Button {
                                        removeIngredient(at: index)
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .foregroundColor(.red)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.vertical, 2)
                            }
                        } else {
                            Text("No ingredients for this step yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 4)
                        }
                    }
                }
                .padding(.leading, 16)
            }
        }
        //.padding()
        //.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
    
    private func updateIngredient(at index: Int, with newValue: String) {
        var newIngredients = step.ingredients
        newIngredients[index] = newValue
        step = RecipeStep(
            stepNumber: step.stepNumber,
            instruction: step.instruction,
            ingredients: newIngredients
        )
    }
    
    private func addIngredient() {
        let trimmed = newIngredient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        var newIngredients = step.ingredients
        if !newIngredients.contains(where: { $0.lowercased() == trimmed.lowercased() }) {
            newIngredients.append(trimmed)
            step = RecipeStep(
                stepNumber: step.stepNumber,
                instruction: step.instruction,
                ingredients: newIngredients
            )
        }
        newIngredient = ""
    }
    
    private func removeIngredient(at index: Int) {
        var newIngredients = step.ingredients
        newIngredients.remove(at: index)
        step = RecipeStep(
            stepNumber: step.stepNumber,
            instruction: step.instruction,
            ingredients: newIngredients
        )
    }
}











// MARK: - iOS Camera
// iOS Camera Support
// Enhanced iOS 17+ Camera Implementation with Multi-Camera Support

#if os(iOS)
@preconcurrency import AVFoundation

struct CameraInfo: Identifiable, Hashable {
    let id = UUID()
    let device: AVCaptureDevice
    let displayName: String
    let position: AVCaptureDevice.Position
    
    init(device: AVCaptureDevice) {
        self.device = device
        self.position = device.position
        
        // Create user-friendly names
        let positionName = position == .front ? "Front" : "Back"
        switch device.deviceType {
        case .builtInWideAngleCamera:
            self.displayName = "\(positionName) Wide"
        case .builtInUltraWideCamera:
            self.displayName = "\(positionName) Ultra Wide"
        case .builtInTelephotoCamera:
            self.displayName = "\(positionName) Telephoto"
        case .builtInDualCamera:
            self.displayName = "\(positionName) Dual"
        case .builtInDualWideCamera:
            self.displayName = "\(positionName) Dual Wide"
        case .builtInTripleCamera:
            self.displayName = "\(positionName) Triple"
        default:
            self.displayName = "\(positionName) Camera"
        }
    }
}

struct CameraView: View {
    let onImageCaptured: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var cameraManager = CameraManager()
    @State private var showingCameraSelector = false
    
    var body: some View {
        NavigationStack {
            ZStack {
                // Camera preview
                CameraPreview(session: cameraManager.session, cameraManager: cameraManager)
                    .ignoresSafeArea()
                
                VStack {
                    // Top controls
                    HStack {
                        Button("Cancel") {
                            dismiss()
                        }
                        .foregroundColor(.white)
                        .padding()
                        
                        Spacer()
                        
                        // Camera selector button
                        if cameraManager.availableCameras.count > 1 {
                            Button {
                                showingCameraSelector = true
                            } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: "camera.circle")
                                        .font(.title2)
                                    Text(cameraManager.currentCamera?.displayName ?? "Camera")
                                        .font(.caption)
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal)
                            }
                        }
                    }
                    .padding(.top, 50)
                    
                    Spacer()
                    
                    // Bottom controls
                    HStack {
                        // Flash toggle (if supported)
                        if cameraManager.currentCamera?.device.hasFlash == true {
                            Button {
                                cameraManager.toggleFlash()
                            } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: cameraManager.flashMode == .on ? "bolt.fill" : cameraManager.flashMode == .auto ? "bolt.badge.automatic" : "bolt.slash")
                                        .font(.title2)
                                    Text(cameraManager.flashMode == .on ? "On" : cameraManager.flashMode == .auto ? "Auto" : "Off")
                                        .font(.caption)
                                }
                                .foregroundColor(.white)
                                .padding()
                            }
                        } else {
                            Spacer()
                                .frame(width: 60)
                        }
                        
                        Spacer()
                        
                        // Capture button
                        Button {
                            cameraManager.capturePhoto { image in
                                if let image = image {
                                    onImageCaptured(image)
                                }
                                dismiss()
                            }
                        } label: {
                            Circle()
                                .stroke(Color.white, lineWidth: 4)
                                .frame(width: 70, height: 70)
                                .overlay(
                                    Circle()
                                        .fill(Color.white)
                                        .frame(width: 60, height: 60)
                                )
                        }
                        
                        Spacer()
                        
                        // Quick camera flip (front/back toggle)
                        Button {
                            cameraManager.flipToOppositePosition()
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "camera.rotate")
                                    .font(.title2)
                                Text("Flip")
                                    .font(.caption)
                            }
                            .foregroundColor(.white)
                            .padding()
                        }
                    }
                    .padding(.bottom, 50)
                }
            }
            .onAppear {
                cameraManager.requestPermission()
            }
            .onDisappear {
                cameraManager.stopSession()
            }
            .confirmationDialog("Select Camera", isPresented: $showingCameraSelector) {
                ForEach(cameraManager.availableCameras) { cameraInfo in
                    Button(cameraInfo.displayName) {
                        cameraManager.switchToCamera(cameraInfo)
                    }
                }
                Button("Cancel", role: .cancel) { }
            }
        }
    }
}

// MARK: - Camera Preview (Modernized)
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let cameraManager: CameraManager

    func makeCoordinator() -> Coordinator {
        Coordinator(cameraManager: cameraManager)
    }
    
    @MainActor
    final class Coordinator: NSObject {
        var previewLayer: AVCaptureVideoPreviewLayer?
        var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
        private var orientationObserver: NSObjectProtocol?
        private var deviceChangeObserver: NSObjectProtocol?
        private weak var cameraManager: CameraManager?
        
        init(cameraManager: CameraManager) {
            self.cameraManager = cameraManager
            super.init()
        }
        
        @MainActor
        func teardown() {
            removeAllObservers()
            rotationCoordinator = nil
            previewLayer = nil
        }
        
        @MainActor
        func setupRotationCoordinator(for previewLayer: AVCaptureVideoPreviewLayer) {
            guard let cameraManager = cameraManager,
                  let device = cameraManager.currentCamera?.device else { return }
            
            // Create rotation coordinator with the preview layer
            rotationCoordinator = AVCaptureDevice.RotationCoordinator(
                device: device,
                previewLayer: previewLayer
            )
            
            // Store it in camera manager for photo capture
            cameraManager.rotationCoordinator = rotationCoordinator
            
            // Set up observers
            setupOrientationObserver()
            setupDeviceChangeObserver()
        }
        
        @MainActor
        private func setupOrientationObserver() {
            removeOrientationObserver() // Remove any existing observer
            
            orientationObserver = NotificationCenter.default.addObserver(
                forName: UIDevice.orientationDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.updateVideoRotation()
                }
            }
        }
        
        @MainActor
        func setupDeviceChangeObserver() {
            removeDeviceChangeObserver()
            
            deviceChangeObserver = NotificationCenter.default.addObserver(
                forName: .cameraDeviceChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.deviceChanged()
                }
            }
        }
        
        @MainActor
        private func removeOrientationObserver() {
            if let observer = orientationObserver {
                NotificationCenter.default.removeObserver(observer)
                orientationObserver = nil
            }
        }
        
        @MainActor
        private func removeDeviceChangeObserver() {
            if let observer = deviceChangeObserver {
                NotificationCenter.default.removeObserver(observer)
                deviceChangeObserver = nil
            }
        }
        
        @MainActor
        private func removeAllObservers() {
            removeOrientationObserver()
            removeDeviceChangeObserver()
        }
        
        @MainActor
        func updateVideoRotation() {
            guard let previewLayer = previewLayer,
                  let connection = previewLayer.connection,
                  let coordinator = rotationCoordinator else { return }
            
            // Use the correct rotation angle for preview
            connection.videoRotationAngle = coordinator.videoRotationAngleForHorizonLevelPreview
            
            // Handle mirroring for front camera
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = (cameraManager?.currentCamera?.position == .front)
            }
        }
        
        @MainActor
        func deviceChanged() {
            // Recreate rotation coordinator when device changes
            if let previewLayer = previewLayer {
                setupRotationCoordinator(for: previewLayer)
                updateVideoRotation()
            }
        }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        
        // Store reference and setup rotation coordinator
        context.coordinator.previewLayer = view.videoPreviewLayer
        
        Task { @MainActor in
            context.coordinator.setupRotationCoordinator(for: view.videoPreviewLayer)
            context.coordinator.updateVideoRotation()
        }
        
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        Task { @MainActor in
            context.coordinator.updateVideoRotation()
        }
    }
    
    static func dismantleUIView(_ uiView: PreviewView, coordinator: Coordinator) {
        Task { @MainActor in
            coordinator.teardown()
        }
    }
    
}

// MARK: - Camera Manager (Modernized)
// MARK: - Camera Manager (Fixed)
@MainActor
class CameraManager: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private var photoOutput = AVCapturePhotoOutput()
    private var videoDeviceInput: AVCaptureDeviceInput?
    private var captureCompletion: ((UIImage?) -> Void)?
    var rotationCoordinator: AVCaptureDevice.RotationCoordinator?

    @Published var availableCameras: [CameraInfo] = []
    @Published var currentCamera: CameraInfo?
    @Published var flashMode: AVCaptureDevice.FlashMode = .auto
    
    override init() {
        super.init()
        discoverCameras()
        setupCamera()
    }
    
    private func discoverCameras() {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .builtInUltraWideCamera,
                .builtInTelephotoCamera,
                .builtInDualCamera,
                .builtInDualWideCamera,
                .builtInTripleCamera
            ],
            mediaType: .video,
            position: .unspecified
        )
        
        availableCameras = discoverySession.devices.map { CameraInfo(device: $0) }
        
        // Sort cameras: back cameras first, then by type preference
        availableCameras.sort { camera1, camera2 in
            if camera1.position != camera2.position {
                return camera1.position == .back
            }
            
            let typeOrder: [AVCaptureDevice.DeviceType] = [
                .builtInTripleCamera,
                .builtInDualWideCamera,
                .builtInDualCamera,
                .builtInWideAngleCamera,
                .builtInUltraWideCamera,
                .builtInTelephotoCamera
            ]
            let index1 = typeOrder.firstIndex(of: camera1.device.deviceType) ?? typeOrder.count
            let index2 = typeOrder.firstIndex(of: camera2.device.deviceType) ?? typeOrder.count
            return index1 < index2
        }
        
        // Set default camera
        let preferredBackVirtualTypes: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInDualCamera
        ]
        if let virtualBack = availableCameras.first(where: { $0.position == .back && preferredBackVirtualTypes.contains($0.device.deviceType) }) {
            currentCamera = virtualBack
        } else if let backWide = availableCameras.first(where: { $0.position == .back && $0.device.deviceType == .builtInWideAngleCamera }) {
            currentCamera = backWide
        } else {
            currentCamera = availableCameras.first
        }
    }
    
    func requestPermission() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            Task { @MainActor in
                if granted {
                    self?.startSession()
                }
            }
        }
    }
    
    private func setupCamera() {
        session.sessionPreset = .photo
        
        guard let currentCamera = currentCamera else { return }
        
        do {
            let videoDeviceInput = try AVCaptureDeviceInput(device: currentCamera.device)
            
            if session.canAddInput(videoDeviceInput) {
                session.addInput(videoDeviceInput)
                self.videoDeviceInput = videoDeviceInput
            }
            
            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
            }
        } catch {
            print("Error setting up camera: \(error)")
        }
    }
    
    func switchToCamera(_ cameraInfo: CameraInfo) {
        guard cameraInfo.id != currentCamera?.id else { return }

        session.beginConfiguration()

        // Remove current input
        if let currentInput = videoDeviceInput {
            session.removeInput(currentInput)
        }

        // Add new input
        do {
            let newInput = try AVCaptureDeviceInput(device: cameraInfo.device)
            if session.canAddInput(newInput) {
                session.addInput(newInput)
                videoDeviceInput = newInput
                currentCamera = cameraInfo

                // Don't create rotation coordinator here - let the preview handle it
                // The coordinator needs the preview layer reference
                rotationCoordinator = nil

                // Update flash mode based on new camera capabilities
                if !cameraInfo.device.hasFlash && flashMode != .off {
                    flashMode = .off
                }
            }
        } catch {
            print("Error switching camera: \(error)")
            // Restore previous camera if switch failed
            if let previousInput = videoDeviceInput {
                session.addInput(previousInput)
            }
        }

        session.commitConfiguration()
        
        // Notify that the device changed
        NotificationCenter.default.post(name: .cameraDeviceChanged, object: cameraInfo)
    }
    
    func flipToOppositePosition() {
        guard let current = currentCamera else { return }
        
        let targetPosition: AVCaptureDevice.Position = current.position == .back ? .front : .back
        
        // Find the first camera of the opposite position (preferring wide camera)
        if let targetCamera = availableCameras.first(where: { $0.position == targetPosition && $0.device.deviceType == .builtInWideAngleCamera }) ??
           availableCameras.first(where: { $0.position == targetPosition }) {
            switchToCamera(targetCamera)
        }
    }
    
    func toggleFlash() {
        guard currentCamera?.device.hasFlash == true else { return }
        
        switch flashMode {
        case .off:
            flashMode = .auto
        case .auto:
            flashMode = .on
        case .on:
            flashMode = .off
        @unknown default:
            flashMode = .auto
        }
    }
    
    func startSession() {
        if !session.isRunning {
            let session = self.session
            Task.detached {
                session.startRunning()
            }
        }
    }
    
    func stopSession() {
        if session.isRunning {
            let session = self.session
            Task.detached {
                session.stopRunning()
            }
        }
    }
    
    func capturePhoto(completion: @escaping (UIImage?) -> Void) {
        let settings = AVCapturePhotoSettings()
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        settings.flashMode = flashMode

        // Only set photoQualityPrioritization if the output supports it
        if photoOutput.maxPhotoQualityPrioritization.rawValue >= AVCapturePhotoOutput.QualityPrioritization.quality.rawValue {
            settings.photoQualityPrioritization = .quality
        } else {
            settings.photoQualityPrioritization = photoOutput.maxPhotoQualityPrioritization
        }

        // Use modern rotation approach
        if let photoConnection = photoOutput.connection(with: .video),
           let coordinator = rotationCoordinator {
            
            if photoConnection.isVideoRotationAngleSupported(coordinator.videoRotationAngleForHorizonLevelCapture) {
                photoConnection.videoRotationAngle = coordinator.videoRotationAngleForHorizonLevelCapture
            }
            
            if photoConnection.isVideoMirroringSupported {
                photoConnection.automaticallyAdjustsVideoMirroring = false
                photoConnection.isVideoMirrored = (currentCamera?.position == .front)
            }
        }
        
        captureCompletion = completion
        photoOutput.capturePhoto(with: settings, delegate: self)
    }
}

// MARK: - AVCapturePhotoCaptureDelegate
extension CameraManager: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let imageData = photo.fileDataRepresentation() else {
            Task { @MainActor in
                self.captureCompletion?(nil)
                self.captureCompletion = nil
            }
            return
        }
        
        Task { @MainActor in
            if let image = UIImage(data: imageData) {
                self.captureCompletion?(image)
            } else {
                self.captureCompletion?(nil)
            }
            self.captureCompletion = nil
        }
    }
}

// Add this extension for the notification
extension Notification.Name {
    static let cameraDeviceChanged = Notification.Name("cameraDeviceChanged")
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

#endif
