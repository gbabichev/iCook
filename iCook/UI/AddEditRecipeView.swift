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
    
    @State private var selectedCategoryId: Int = 1
    @State private var recipeName: String = ""
    @State private var recipeTime: String = ""
    @State private var recipeDetails: String = ""
    @State private var showingImagePicker = false
    @State private var selectedImageData: Data?
    @State private var existingImagePath: String?
    @State private var isUploading = false
    @State private var isSaving = false
    
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
                        // Photo Picker Button
#if os(iOS)
                        Button {
                            showingImageActionSheet = true
                        } label: {
                            HStack {
                                Image(systemName: "photo.badge.plus")
                                Text(selectedImageData != nil ? "Change Photo" : "Add Photo")
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
                            showingImagePicker = true
                        } label: {
                            HStack {
                                Image(systemName: "photo.badge.plus")
                                Text(selectedImageData != nil ? "Change Photo" : "Add Photo")
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
            // iOS specific photo handling
#if os(iOS)
            .photosPicker(
                isPresented: $showingImagePicker,
                selection: $selectedPhotoItem,
                matching: .images
            )
            .onChange(of: selectedPhotoItem) { _, newItem in
                Task {
                    if let data = try? await newItem?.loadTransferable(type: Data.self) {
                        await MainActor.run {
                            selectedImageData = data
                            existingImagePath = nil
                        }
                    }
                }
            }
            .fullScreenCover(isPresented: $showingCamera) {
                CameraView { image in
                    if let imageData = image.jpegData(compressionQuality: 0.8) {
                        selectedImageData = imageData
                        existingImagePath = nil
                    }
                }
            }
#else
            // macOS file importer
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
