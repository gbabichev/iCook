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
#if os(macOS)
    @State private var fileImporterTrigger = UUID()
#endif
    @State private var isCompressingImage = false
    @State private var saveErrorMessage: String?
    @State private var showingDeleteAlert = false
    @State private var isDeletingRecipe = false
    @State private var showingAddTag = false
    @State private var selectedTagIDs: Set<CKRecord.ID> = []
    
    // Recipe Steps
    @State private var recipeSteps: [RecipeStep] = []
    @State private var expandedSteps: Set<Int> = []
    
    // Legacy ingredients (for backward compatibility)
    @State private var legacyIngredients: [String] = []
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

    private var deleteConfirmationRecipeName: String {
        let trimmedName = recipeName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            return trimmedName
        }
        return editingRecipe?.name ?? "this recipe"
    }

    private var deleteConfirmationMessage: String {
        "Are you sure you want to delete '\(deleteConfirmationRecipeName)'? This action cannot be undone."
    }
    
    var isEditing: Bool { editingRecipe != nil }
    
    init(editingRecipe: Recipe? = nil, preselectedCategoryId: CKRecord.ID? = nil) {
        self.editingRecipe = editingRecipe
        self.preselectedCategoryId = preselectedCategoryId
    }
    
    var body: some View {
        Group {
#if os(macOS)
            macOSView
#else
            iOSView
#endif
        }
        .overlay {
            if isSaving {
                ZStack {
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(isEditing ? "Updating recipe..." : "Creating recipe...")
                            .font(.headline)
                            .foregroundStyle(.primary)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .overlay {
            if isDeletingRecipe {
                ZStack {
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Deleting recipe...")
                            .font(.headline)
                            .foregroundStyle(.primary)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .task {
            await initializeView()
        }
        .onChange(of: model.categories) { _, newCategories in
            handleCategoryChanges(newCategories)
        }
        .onChange(of: model.tags) { _, newTags in
            handleTagChanges(newTags)
        }
        .sheet(isPresented: $showingAddTag) {
            AddTagView()
                .environmentObject(model)
        }
#if os(iOS)
        .photosPicker(
            isPresented: $showingImagePicker,
            selection: $selectedPhotoItem,
            matching: .images
        )
        .onChange(of: selectedPhotoItem) { _, newItem in
            Task {
                await handleSelectedPhotoItemChange(newItem)
            }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraView { image in
                Task {
                    await handleCapturedCameraImage(image)
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
            case .failure:
                break
            }
        }
        .id(fileImporterTrigger)
#endif
        .alert("Delete Recipe", isPresented: $showingDeleteAlert) {
            Button("Delete", role: .destructive) {
                Task {
                    await deleteRecipe()
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(deleteConfirmationMessage)
        }
    }

    private var iOSView: some View {
        NavigationStack {
            Form {
                readOnlyBannerSection
                saveErrorSection
                
                Section("Basic Information") {
                    basicInformationContent
                }
                
                Section("Image") {
                    imageSection.disabled(!canEdit)
                }
                
                recipeStepsSection
                deleteRecipeSection
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
                    .disabled(!saveButtonEnabled)
                }
            }
        }
    }

#if os(macOS)
    private var macOSView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: isEditing ? "square.and.pencil" : "fork.knife.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(isEditing ? "Edit Recipe" : "Add Recipe")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Create and organize recipe details")
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
                        await saveRecipe()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!saveButtonEnabled)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    statusBanners
                    
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Basic Information")
                            .font(.headline)
                        basicInformationContent
                    }
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Image")
                            .font(.headline)
                        imageSection.disabled(!canEdit)
                    }
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    
                    VStack(alignment: .leading, spacing: 12) {
                        recipeStepsHeader
                        recipeStepsEditorContent
                    }
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    
                    if isEditing {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Danger Zone")
                                .font(.headline)

                            Button(role: .destructive) {
                                showingDeleteAlert = true
                            } label: {
                                HStack {
                                    Spacer()
                                    if isDeletingRecipe {
                                        ProgressView()
                                            .controlSize(.small)
                                        Text("Deleting...")
                                    } else {
                                        Text("Delete Recipe")
                                            .fontWeight(.semibold)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .disabled(!canEdit || isSaving || isDeletingRecipe)

                            Text("This action cannot be undone.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                .padding(16)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
#endif

    @ViewBuilder
    private var statusBanners: some View {
        if let source = model.currentSource, !model.canEditSource(source) {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .foregroundColor(.orange)
                Text("This source is read-only")
                    .font(.callout)
                    .foregroundStyle(.primary)
            }
            .padding(12)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }
        
        if let errorMessage = saveErrorMessage {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.red)
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.primary)
            }
            .padding(12)
            .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private var readOnlyBannerSection: some View {
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
    }

    @ViewBuilder
    private var saveErrorSection: some View {
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
    }

    @ViewBuilder
    private var basicInformationContent: some View {
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
        
        TextField("Recipe Name *", text: $recipeName)
            .disabled(!canEdit)
        
        HStack {
            TextField("Cooking Time *", text: $recipeTime)
                .disabled(!canEdit)
            Text("minutes")
                .foregroundStyle(.secondary)
        }

        recipeTagSelectionContent
    }

    private var saveButtonEnabled: Bool {
        isFormValid && !isSaving && !isDeletingRecipe && canEdit
    }

    private var recipeStepsSection: some View {
        Section {
            recipeStepsEditorContent
        } header: {
            recipeStepsHeader
        }
    }

    @ViewBuilder
    private var deleteRecipeSection: some View {
        if isEditing {
            Section {
                Button(role: .destructive) {
                    showingDeleteAlert = true
                } label: {
                    Label("Delete Recipe", systemImage: "trash")
                }
                .disabled(!canEdit || isSaving || isDeletingRecipe)
            } header: {
                Text("Danger Zone")
            } footer: {
                Text("This action cannot be undone.")
            }
        }
    }

    private var recipeStepsHeader: some View {
        HStack {
            Text("Recipe Steps")
            Spacer()
            if !recipeSteps.isEmpty {
                Text("\(recipeSteps.count) steps")
                    .font(.caption)
            }
        }
    }

    private var orderedSelectedTagIDs: [CKRecord.ID] {
        Array(selectedTagIDs).sorted { $0.recordName.localizedStandardCompare($1.recordName) == .orderedAscending }
    }

    @ViewBuilder
    private var recipeTagSelectionContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Tags", systemImage: "tag")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                Button {
                    showingAddTag = true
                } label: {
                    Label("Add Tag", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canEdit)
            }

            if model.tags.isEmpty {
                Text("No tags yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(model.tags) { tag in
                        let isSelected = selectedTagIDs.contains(tag.id)
                        Button {
                            if isSelected {
                                selectedTagIDs.remove(tag.id)
                            } else {
                                selectedTagIDs.insert(tag.id)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.caption)
                                Text(tag.name)
                                    .lineLimit(1)
                            }
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12),
                                in: Capsule()
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!canEdit)
                    }
                }
            }
        }
    }

    private var recipeStepsEditorContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recipe Steps")
                    .font(.headline)

                HStack {
                    if !recipeSteps.isEmpty {
                        Button("Collapse All") {
                            collapseAllSteps()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!canEdit)

                        Button("Expand All") {
                            expandAllSteps()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!canEdit)
                    }
                    Button("Add Step") {
                        addNewStep()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canEdit)

                    Spacer()
                }
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
    }

    // MARK: - Step Management
    
    private func expandAllSteps() {
        expandedSteps = Set(recipeSteps.map(\.stepNumber))
    }
    
    private func collapseAllSteps() {
        expandedSteps.removeAll()
    }
    
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
            selectedTagIDs = Set(recipe.tagIDs)
            recipeName = recipe.name
            recipeTime = String(recipe.recipeTime)
            recipeDetails = recipe.details ?? ""
            if existingImagePath == nil {
                existingImagePath = model.cloudKitManager.cachedImagePathForRecipe(recipe.id)
            }
            
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

    private func handleTagChanges(_ newTags: [Tag]) {
        let validIDs = Set(newTags.map { $0.id })
        selectedTagIDs.formIntersection(validIDs)
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
        let selectedTagIDsArray = orderedSelectedTagIDs
        if let recipe = editingRecipe {
            let originalTagIDs = Set(recipe.tagIDs)
            let tagIDsForUpdate: [CKRecord.ID]? = selectedTagIDs == originalTagIDs ? nil : selectedTagIDsArray
            success = await model.updateRecipeWithSteps(
                id: recipe.id,
                categoryId: selectedCategoryId != recipe.categoryID ? selectedCategoryId : nil,
                name: trimmedName != recipe.name ? trimmedName : nil,
                recipeTime: timeValue != recipe.recipeTime ? timeValue : nil,
                details: detailsToSave != recipe.details ? detailsToSave : nil,
                image: selectedImageData,
                recipeSteps: finalSteps,
                tagIDs: tagIDsForUpdate
            )
        } else {
            success = await model.createRecipeWithSteps(
                categoryId: categoryId,
                name: trimmedName,
                recipeTime: timeValue,
                details: detailsToSave,
                image: selectedImageData,
                recipeSteps: finalSteps,
                tagIDs: selectedTagIDsArray
            )
        }
        
        if success {
            if let recipe = editingRecipe {
                var updated = recipe
                if let cached = model.cloudKitManager.cachedImagePathForRecipe(recipe.id) {
                    updated.cachedImagePath = cached
                }
                updated.name = trimmedName
                updated.details = detailsToSave
                updated.recipeTime = timeValue
                updated.recipeSteps = finalSteps
                updated.tagIDs = selectedTagIDsArray
                NotificationCenter.default.post(name: .recipeUpdated, object: updated)
            }
            dismiss()
        } else {
            if let modelError = model.error {
                saveErrorMessage = "Failed to save recipe: \(modelError)"
            } else if isEditing {
                saveErrorMessage = "Failed to update recipe. Please try again or check the console for details."
            } else {
                saveErrorMessage = "Failed to create recipe. Please try again or check the console for details."
            }
        }
    }

    @MainActor
    private func deleteRecipe() async {
        guard let recipe = editingRecipe else { return }
        isDeletingRecipe = true
        saveErrorMessage = nil
        let success = await model.deleteRecipeWithUIFeedback(id: recipe.id)
        isDeletingRecipe = false

        if success {
            dismiss()
        } else {
            if let modelError = model.error {
                saveErrorMessage = "Failed to delete recipe: \(modelError)"
            } else {
                saveErrorMessage = "Failed to delete recipe. Please try again."
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
            HStack {
                Button {
                    fileImporterTrigger = UUID()
                    showingImagePicker = true
                } label: {
                    HStack {
                        Image(systemName: "photo.badge.plus")
                        Text((selectedImageData != nil || existingImagePath != nil) ? "Change Photo" : "Add Photo")
                    }
                }
                
                // Add Remove Photo option for macOS when there's an image
                if selectedImageData != nil || existingImagePath != nil {
                    Button("Remove Photo", role: .destructive) {
                        selectedImageData = nil
                        existingImagePath = nil
                    }
                }
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
                            .allowsHitTesting(false)
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
                            .allowsHitTesting(false)
                            .zIndex(0)
                    } else {
                        placeholderImageView
                    }
#endif
                }
            } else if let imagePath = existingImagePath {
                AsyncImage(url: URL(fileURLWithPath: imagePath)) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(height: 200)
                            .clipped()
                            .cornerRadius(8)
                            .allowsHitTesting(false)
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
                .allowsHitTesting(false)
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

#if os(iOS)
    @MainActor
    private func setImageLoadingState(_ isLoading: Bool) {
        isUploading = isLoading
        isCompressingImage = isLoading
    }

    private func handleSelectedPhotoItemChange(_ newItem: PhotosPickerItem?) async {
        guard let newItem = newItem else { return }

        await MainActor.run {
            setImageLoadingState(true)
        }

        defer {
            Task { @MainActor in
                setImageLoadingState(false)
            }
        }

        do {
            guard let originalData = try await newItem.loadTransferable(type: Data.self) else {
                return
            }

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
        } catch {
        }
    }

    private func handleCapturedCameraImage(_ image: UIImage) async {
        await MainActor.run {
            setImageLoadingState(true)
        }

        defer {
            Task { @MainActor in
                setImageLoadingState(false)
            }
        }

        guard let originalData = image.jpegData(compressionQuality: 0.95) else {
            return
        }

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
#endif

#if os(macOS)
    private func loadImageFromURL(_ url: URL) {
        Task {
            isUploading = true
            isCompressingImage = true
            defer {
                isUploading = false
                isCompressingImage = false
            }
            
            
            let didStartAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccess { url.stopAccessingSecurityScopedResource() }
            }
            
            do {
                let originalData = try Data(contentsOf: url, options: .mappedIfSafe)
                
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
                
            } catch {
                await MainActor.run {
                    // Could show an error alert here
                }
            }
        }
    }
#endif
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
            return nil
        }
        
        let originalSize = image.size
        
        let maxSide = max(originalSize.width, originalSize.height)
        let needsResize = maxSide > maxDimension
        let targetSize: CGSize
        
        if needsResize {
            let scaleRatio = maxDimension / maxSide
            targetSize = CGSize(width: originalSize.width * scaleRatio, height: originalSize.height * scaleRatio)
        } else {
            targetSize = originalSize
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
        } else {
            finalImage = image
        }
        
        // Always apply JPEG compression
        guard let compressedData = finalImage.jpegData(compressionQuality: quality) else {
            return nil
        }
        
        return compressedData
    }
#else
    nonisolated private func compressImageData(_ data: Data, maxDimension: CGFloat = 1600, quality: CGFloat = 0.7) -> Data? {
        guard let nsImage = NSImage(data: data) else {
            return nil
        }
        
        let originalSize = nsImage.size
        let maxSide = max(originalSize.width, originalSize.height)
        
        let needsResize = maxSide > maxDimension
        let targetSize: NSSize
        
        if needsResize {
            let scale = maxDimension / maxSide
            targetSize = NSSize(width: originalSize.width * scale, height: originalSize.height * scale)
        } else {
            targetSize = originalSize
        }
        
        guard let originalRep = NSBitmapImageRep(data: data) ?? nsImage.representations.first as? NSBitmapImageRep else {
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
            return nil
        }
        
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

                        TextField(
                            "Add instructions for this step",
                            text: .init(
                                get: { step.instruction },
                                set: { newValue in
                                    step = RecipeStep(
                                        stepNumber: step.stepNumber,
                                        instruction: newValue,
                                        ingredients: step.ingredients
                                    )
                                }
                            )
                        )
                        .focused($isInstructionFocused)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)

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
