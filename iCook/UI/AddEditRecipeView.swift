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

    
    // iOS specific photo states
#if os(iOS)
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showingImageActionSheet = false
    @State private var showingCamera = false
#endif
    
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

                // Initialize selection for create flow once categories are available
                if !isEditing, selectedCategoryId == 0 {
                    if let firstId = model.categories.first?.id {
                        selectedCategoryId = firstId
                        print("[AddEditRecipeView] Initialized categoryId to \(firstId)")
                    }
                }

                // Setup for editing
                if let recipe = editingRecipe {
                    selectedCategoryId = recipe.category_id
                    recipeName = recipe.name
                    recipeTime = String(recipe.recipe_time)
                    recipeDetails = recipe.details ?? ""
                    existingImagePath = recipe.image
                }
            }
            .onChange(of: model.categories) { _, newCategories in
                // Keep selection valid after categories load/refresh without clobbering user choice
                guard !isEditing else { return }
                let ids = Set(newCategories.map { $0.id })
                if selectedCategoryId == 0 {
                    selectedCategoryId = newCategories.first?.id ?? 0
                    print("[AddEditRecipeView] Categories loaded; defaulted categoryId to \(selectedCategoryId)")
                } else if !ids.contains(selectedCategoryId) {
                    selectedCategoryId = newCategories.first?.id ?? 0
                    print("[AddEditRecipeView] Previous selection invalid; reset to \(selectedCategoryId)")
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
    let maxSide = max(originalSize.width, originalSize.height)
    
    // Always apply JPEG compression, and resize if needed
    let needsResize = maxSide > maxDimension
    let targetSize: CGSize
    
    if needsResize {
        let scale = maxDimension / maxSide
        targetSize = CGSize(width: originalSize.width * scale, height: originalSize.height * scale)
        print("[Compression] Resizing from \(originalSize) to \(targetSize)")
    } else {
        targetSize = originalSize
        print("[Compression] No resize needed, original size: \(originalSize)")
    }
    
    // Create the final image (resized if needed)
    let finalImage: UIImage
    if needsResize {
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        finalImage = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
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

        // ... rest of your save logic stays the same
        let selectedName = model.categories.first(where: { $0.id == selectedCategoryId })?.name ?? "<unknown>"
        print("[AddEditRecipeView] create/update — categoryId=\(selectedCategoryId) (\(selectedName)), name=\(trimmedName), time=\(String(describing: timeValue)), hasImage=\(selectedImageData != nil || imagePathToSave != nil)")
        
        let success: Bool
        if let recipe = editingRecipe {
            success = await model.updateRecipe(
                id: recipe.id,
                categoryId: selectedCategoryId != recipe.category_id ? selectedCategoryId : nil,
                name: trimmedName != recipe.name ? trimmedName : nil,
                recipeTime: timeValue != recipe.recipe_time ? timeValue : nil,
                details: detailsToSave != recipe.details ? detailsToSave : nil,
                image: imagePathToSave != recipe.image ? imagePathToSave : nil
            )
        } else {
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

// iOS Camera Support
#if os(iOS)
@preconcurrency import AVFoundation

struct CameraView: View {
    let onImageCaptured: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var cameraManager = CameraManager()
    
    var body: some View {
        NavigationStack {
            ZStack {
                // Camera preview
                CameraPreview(session: cameraManager.session)
                    .ignoresSafeArea()
                
                VStack {
                    Spacer()
                    
                    // Camera controls
                    HStack {
                        Button("Cancel") {
                            dismiss()
                        }
                        .foregroundColor(.white)
                        .padding()
                        
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
                        
                        // Flip camera button
                        Button {
                            cameraManager.flipCamera()
                        } label: {
                            Image(systemName: "camera.rotate")
                                .font(.title2)
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
        }
    }
}

class CameraManager: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private var photoOutput = AVCapturePhotoOutput()
    private var videoDeviceInput: AVCaptureDeviceInput?
    private var captureCompletion: ((UIImage?) -> Void)?
    
    override init() {
        super.init()
        setupCamera()
    }
    
    func requestPermission() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                if granted {
                    self?.startSession()
                }
            }
        }
    }
    
    private func setupCamera() {
        session.sessionPreset = .photo
        
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            return
        }
        
        do {
            let videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)
            
            if session.canAddInput(videoDeviceInput) {
                session.addInput(videoDeviceInput)
                self.videoDeviceInput = videoDeviceInput
            }
            
            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
                // photoOutput.isHighResolutionCaptureEnabled = true
            }
        } catch {
            print("Error setting up camera: \(error)")
        }
    }
    
    func startSession() {
        if !session.isRunning {
            let session = self.session
            DispatchQueue.global(qos: .userInitiated).async { [weak session] in
                session?.startRunning()
            }
        }
    }
    
    func stopSession() {
        if session.isRunning {
            let session = self.session
            DispatchQueue.global(qos: .userInitiated).async { [weak session] in
                session?.stopRunning()
            }
        }
    }
    
    func capturePhoto(completion: @escaping (UIImage?) -> Void) {
        let settings = AVCapturePhotoSettings()
        if #available(iOS 16.0, *) {
            settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        } else {
            settings.isHighResolutionPhotoEnabled = true
        }
        
        captureCompletion = completion
        photoOutput.capturePhoto(with: settings, delegate: self)
    }
    
    func flipCamera() {
        guard let currentInput = videoDeviceInput else { return }
        
        session.beginConfiguration()
        session.removeInput(currentInput)
        
        let newPosition: AVCaptureDevice.Position = currentInput.device.position == .back ? .front : .back
        guard let newDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPosition),
              let newInput = try? AVCaptureDeviceInput(device: newDevice) else {
            session.addInput(currentInput)
            session.commitConfiguration()
            return
        }
        
        if session.canAddInput(newInput) {
            session.addInput(newInput)
            videoDeviceInput = newInput
        } else {
            session.addInput(currentInput)
        }
        
        session.commitConfiguration()
    }
}

extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let imageData = photo.fileDataRepresentation(),
              let image = UIImage(data: imageData) else {
            captureCompletion?(nil)
            return
        }
        
        captureCompletion?(image)
        captureCompletion = nil
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }
    
    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}
#endif
