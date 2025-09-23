import SwiftUI
import Combine
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
    let preselectedCategoryId: Int?
    
    @State private var selectedCategoryId: Int = 0
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
    @State private var ingredients: [String] = []
    @State private var newIngredient: String = ""
    
    
    // iOS specific photo states
#if os(iOS)
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showingImageActionSheet = false
    @State private var showingCamera = false
#endif
    
    var isEditing: Bool { editingRecipe != nil }
    
    init(editingRecipe: Recipe? = nil, preselectedCategoryId: Int? = nil) {
        self.editingRecipe = editingRecipe
        self.preselectedCategoryId = preselectedCategoryId
    }
    
    var body: some View {
        
        NavigationStack {
            Form {
                Section("Basic Information") {
                    // Category Picker
                    Picker("Category", selection: $selectedCategoryId) {
                        ForEach(model.categories) { category in
                            Text(category.name).tag(Int(category.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selectedCategoryId) { oldValue, newValue in
                        print("[AddEditRecipeView] User changed categoryId from \(oldValue) to \(newValue)")
                    }
                    
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
                            // Force refresh the fileImporter by changing the trigger
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
                
                Section("Ingredients") {
                    // Add ingredient field
                    HStack {
                        TextField("Add ingredient", text: $newIngredient)
                            .onSubmit {
                                addIngredient()
                            }
                        
                        Button("Add") {
                            addIngredient()
                        }
                        .disabled(newIngredient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    
                    // List of current ingredients
                    if !ingredients.isEmpty {
                        ForEach(Array(ingredients.enumerated()), id: \.offset) { index, ingredient in
                            HStack {
                                Text("• \(ingredient)")
                                Spacer()
                                Button {
                                    ingredients.remove(at: index)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundColor(.red)
                                }
                            }
                        }
                        .onDelete(perform: deleteIngredients)
                        .onMove(perform: moveIngredients)
                    } else {
                        Text("No ingredients added yet")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }

                Section("Recipe Details") {
                    TextEditor(text: $recipeDetails)
                        .frame(minHeight: 400)
                        .scrollContentBackground(.hidden)
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
                
                // Initialize selection for create flow once categories are available
                if !isEditing, selectedCategoryId == 0 {
                    // Use preselected category if available, otherwise use first category
                    if let preselected = preselectedCategoryId, model.categories.contains(where: { $0.id == preselected }) {
                        selectedCategoryId = preselected
                        print("[AddEditRecipeView] Initialized categoryId to preselected \(preselected)")
                    } else if let firstId = model.categories.first?.id {
                        selectedCategoryId = firstId
                        print("[AddEditRecipeView] Initialized categoryId to first available \(firstId)")
                    }
                }
                
                // Setup for editing
                if let recipe = editingRecipe {
                    selectedCategoryId = recipe.category_id
                    recipeName = recipe.name
                    recipeTime = String(recipe.recipe_time)
                    recipeDetails = recipe.details ?? ""
                    existingImagePath = recipe.image
                    // Initialize ingredients array
                    ingredients = recipe.ingredients ?? []
                    print("[AddEditRecipeView] Loaded \(ingredients.count) ingredients for editing")
                }
            }
            .onChange(of: model.categories) { _, newCategories in
                let ids = Set(newCategories.map { $0.id })
                
                if isEditing {
                    // For editing: ensure the recipe's category still exists, otherwise pick first available
                    if let recipe = editingRecipe, !ids.contains(recipe.category_id) {
                        selectedCategoryId = newCategories.first?.id ?? 0
                        print("[AddEditRecipeView] Recipe's category \(recipe.category_id) not found; reset to \(selectedCategoryId)")
                    }
                } else {
                    // For creating: prioritize preselected, then current selection, then default
                    if selectedCategoryId == 0 {
                        if let preselected = preselectedCategoryId, ids.contains(preselected) {
                            selectedCategoryId = preselected
                            print("[AddEditRecipeView] Categories loaded; set to preselected \(preselected)")
                        } else {
                            selectedCategoryId = newCategories.first?.id ?? 0
                            print("[AddEditRecipeView] Categories loaded; defaulted categoryId to \(selectedCategoryId)")
                        }
                    } else if !ids.contains(selectedCategoryId) {
                        if let preselected = preselectedCategoryId, ids.contains(preselected) {
                            selectedCategoryId = preselected
                            print("[AddEditRecipeView] Previous selection invalid; using preselected \(preselected)")
                        } else {
                            selectedCategoryId = newCategories.first?.id ?? 0
                            print("[AddEditRecipeView] Previous selection invalid; reset to \(selectedCategoryId)")
                        }
                    }
                }
            }
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
                        // Load the data
                        guard let originalData = try await newItem.loadTransferable(type: Data.self) else {
                            return
                        }
                        
                        print("[Image] Loaded \(Int(Double(originalData.count) / 1024.0))KB from photo picker")
                        
                        // Compress on background thread
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
                        
                        // Get original data
                        guard let originalData = image.jpegData(compressionQuality: 0.95) else {
                            return
                        }
                        
                        print("[Camera] Captured \(Int(Double(originalData.count) / 1024.0))KB image")
                        
                        // Compress on background thread
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
            // macOS file importer - Fixed version
            .fileImporter(
                isPresented: $showingImagePicker,
                allowedContentTypes: [.image],
                allowsMultipleSelection: false
            ) { result in
                // Reset the picker state immediately
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
            // This id forces the fileImporter to refresh when the trigger changes
            .id(fileImporterTrigger)
#endif
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
                // Read file data
                let originalData = try Data(contentsOf: url, options: .mappedIfSafe)
                print("[Image] Loaded \(Int(Double(originalData.count) / 1024.0))KB from file")
                
                // Compress immediately on background thread
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
    
    
    // New background compression function
    private func compressImageInBackground(_ data: Data, maxDimension: CGFloat = 1600, quality: CGFloat = 0.7) async -> Data? {
#if os(iOS)
        // iOS UIKit operations must happen on main thread
        return await MainActor.run {
            return compressImageData(data, maxDimension: maxDimension, quality: quality)
        }
#else
        // macOS can do compression on background thread
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
    // Fixed macOS version using modern APIs
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
        
        // Create bitmap representation directly instead of using lockFocus
        guard let originalRep = NSBitmapImageRep(data: data) ?? nsImage.representations.first as? NSBitmapImageRep else {
            print("[Compression] Failed to get bitmap representation")
            return nil
        }
        
        let finalRep: NSBitmapImageRep
        
        if needsResize {
            // Create new bitmap rep with target size
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
            
            // Draw the original image into the new rep
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
        
        // Create JPEG data with compression
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

    // Replace the saveRecipe method in AddEditRecipeView with this updated version:

    @MainActor
    private func saveRecipe() async {
        isSaving = true
        defer { isSaving = false }
        
        let trimmedName = recipeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        
        let timeValue = Int(recipeTime.trimmingCharacters(in: .whitespacesAndNewlines))
        let trimmedDetails = recipeDetails.trimmingCharacters(in: .whitespacesAndNewlines)
        let detailsToSave = trimmedDetails.isEmpty ? nil : trimmedDetails
        
        // Process ingredients - remove empty ones and trim whitespace
        let processedIngredients = ingredients
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let ingredientsToSave = processedIngredients.isEmpty ? nil : processedIngredients
        
        var imagePathToSave = existingImagePath

        // Upload image if selected (already compressed!)
        if let imageData = selectedImageData {
            let sizeKB = Double(imageData.count) / 1024.0
            print("[Upload] Uploading pre-compressed image: \(Int(sizeKB))KB")

            let fileName = "recipe_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(8)).jpg"
            if let uploadedPath = await model.uploadImage(imageData: imageData, fileName: String(fileName)) {
                imagePathToSave = uploadedPath
            } else {
                print("Image upload failed, continuing without image")
            }
        }

        let selectedName = model.categories.first(where: { $0.id == selectedCategoryId })?.name ?? "<unknown>"
        print("[AddEditRecipeView] create/update – categoryId=\(selectedCategoryId) (\(selectedName)), name=\(trimmedName), time=\(String(describing: timeValue)), hasImage=\(selectedImageData != nil || imagePathToSave != nil), ingredients=\(processedIngredients.count)")
        
        let success: Bool
        if let recipe = editingRecipe {
            // Determine what changed for the update
            let ingredientsChanged = (recipe.ingredients ?? []) != processedIngredients
            
            success = await model.updateRecipeWithUIFeedback(
                id: recipe.id,
                categoryId: selectedCategoryId != recipe.category_id ? selectedCategoryId : nil,
                name: trimmedName != recipe.name ? trimmedName : nil,
                recipeTime: timeValue != recipe.recipe_time ? timeValue : nil,
                details: detailsToSave != recipe.details ? detailsToSave : nil,
                image: imagePathToSave != recipe.image ? imagePathToSave : nil,
                ingredients: ingredientsChanged ? ingredientsToSave : nil
            )
        } else {
            success = await model.createRecipe(
                categoryId: selectedCategoryId,
                name: trimmedName,
                recipeTime: timeValue,
                details: detailsToSave,
                image: imagePathToSave,
                ingredients: ingredientsToSave
            )
        }
        
        if success {
            dismiss()
        }
    }
    
    private func addIngredient() {
        let trimmed = newIngredient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        // Avoid duplicates
        if !ingredients.contains(where: { $0.lowercased() == trimmed.lowercased() }) {
            ingredients.append(trimmed)
            newIngredient = ""
        } else {
            newIngredient = ""
        }
    }

    private func deleteIngredients(at offsets: IndexSet) {
        ingredients.remove(atOffsets: offsets)
    }

    private func moveIngredients(from source: IndexSet, to destination: Int) {
        ingredients.move(fromOffsets: source, toOffset: destination)
    }
    
    
}

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

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let cameraManager: CameraManager
    
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        // Attach preview layer so the manager can create a RotationCoordinator
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
             cameraManager.updatePreviewRotation()
         }
         
        return view
    }
    
    func updateUIView(_ uiView: PreviewView, context: Context) {
        // Keep preview leveled relative to horizon
        cameraManager.updatePreviewRotation()
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

@MainActor
class CameraManager: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private var photoOutput = AVCapturePhotoOutput()
    private var videoDeviceInput: AVCaptureDeviceInput?
    private var captureCompletion: ((UIImage?) -> Void)?
    
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    
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
            // Back cameras first
            if camera1.position != camera2.position {
                return camera1.position == .back
            }
            
            // Within same position, prefer virtual multi‑camera types, then single‑lens wide → ultra‑wide → telephoto
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
        
        // Preferred default: virtual multi‑camera on the back if available
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
        
        print("Discovered \(availableCameras.count) cameras:")
        availableCameras.forEach { camera in
            print("- \(camera.displayName) (\(camera.device.deviceType.rawValue))")
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
            // After setting up inputs/outputs, configure rotation coordinator
            reconfigureRotationCoordinator()
        } catch {
            print("Error setting up camera: \(error)")
        }
    }

    func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = layer
        reconfigureRotationCoordinator()
        updatePreviewRotation()
    }

    private func reconfigureRotationCoordinator() {
        guard let device = currentCamera?.device else { return }
        // Create/refresh the rotation coordinator; previewLayer is optional
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        
        // Apply initial angles to connections if available
        if let conn = previewLayer?.connection, let coord = rotationCoordinator,
           conn.isVideoRotationAngleSupported(coord.videoRotationAngleForHorizonLevelPreview) {
            conn.videoRotationAngle = coord.videoRotationAngleForHorizonLevelPreview
        }
    }

    func updatePreviewRotation() {
        guard let coord = rotationCoordinator, let conn = previewLayer?.connection,
              conn.isVideoRotationAngleSupported(coord.videoRotationAngleForHorizonLevelPreview) else { return }
        conn.videoRotationAngle = coord.videoRotationAngleForHorizonLevelPreview
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
        reconfigureRotationCoordinator()
        updatePreviewRotation()
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
            // Fall back to the maximum supported quality level
            settings.photoQualityPrioritization = photoOutput.maxPhotoQualityPrioritization
        }
        
        // Set rotation using RotationCoordinator for horizon‑level capture (iOS 17+)
        if let photoOutputConnection = photoOutput.connection(with: .video), let coord = rotationCoordinator {
            let angle = coord.videoRotationAngleForHorizonLevelCapture
            if photoOutputConnection.isVideoRotationAngleSupported(angle) {
                photoOutputConnection.videoRotationAngle = angle
            }
        }
        
        captureCompletion = completion
        photoOutput.capturePhoto(with: settings, delegate: self)
    }
}

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
                let fixedImage = self.fixImageOrientation(image)
                self.captureCompletion?(fixedImage)
            } else {
                self.captureCompletion?(nil)
            }
            self.captureCompletion = nil
        }
    }
    
    private func fixImageOrientation(_ image: UIImage) -> UIImage {
        if image.imageOrientation == .up {
            return image
        }
        
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}
#endif
