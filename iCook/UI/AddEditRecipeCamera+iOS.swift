#if os(iOS)
import SwiftUI
import Combine
import UIKit
@preconcurrency import AVFoundation

// MARK: - iOS Camera
// iOS Camera Support
// Enhanced iOS 17+ Camera Implementation with Multi-Camera Support

struct CameraInfo: Identifiable, Hashable {
    let id: String
    let device: AVCaptureDevice
    let position: AVCaptureDevice.Position
    let zoomLabel: String
    let zoomFactor: CGFloat?
    let zoomSortValue: CGFloat

    init(
        device: AVCaptureDevice,
        zoomLabel: String,
        zoomSortValue: CGFloat,
        zoomFactor: CGFloat? = nil
    ) {
        self.id = "\(device.uniqueID)|\(zoomLabel)"
        self.device = device
        self.position = device.position
        self.zoomLabel = zoomLabel
        self.zoomFactor = zoomFactor
        self.zoomSortValue = zoomSortValue
    }

    static func backUltra(_ device: AVCaptureDevice) -> CameraInfo {
        CameraInfo(device: device, zoomLabel: "0.5x", zoomSortValue: 0.5)
    }

    static func backWide(_ device: AVCaptureDevice) -> CameraInfo {
        CameraInfo(device: device, zoomLabel: "1x", zoomSortValue: 1.0)
    }

    static func front(_ device: AVCaptureDevice) -> CameraInfo {
        CameraInfo(device: device, zoomLabel: "1x", zoomSortValue: 1.0)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: CameraInfo, rhs: CameraInfo) -> Bool {
        lhs.id == rhs.id
    }
}

struct CameraView: View {
    let onImageCaptured: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var cameraManager = CameraManager()
    
    var body: some View {
        NavigationStack {
            ZStack {
                // Camera preview
                CameraPreview(session: cameraManager.session, cameraManager: cameraManager)
                    .ignoresSafeArea()
                
                VStack {
                    // Top controls
                    HStack {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.headline)
                                .frame(width: 44, height: 44)
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.4))
                        )
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.6), lineWidth: 1)
                        )
                        
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    
                    Spacer()
                    
                    cameraLensButtons
                    
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
        }
    }
}

// MARK: - Lens Selector Buttons
private extension CameraView {
    @ViewBuilder
    var cameraLensButtons: some View {
        let currentPosition = cameraManager.currentCamera?.position
        let options = cameraManager.availableCameras.filter { $0.position == currentPosition }
        if options.count > 1 {
            HStack(spacing: 12) {
                ForEach(options) { cameraInfo in
                    Button {
                        cameraManager.switchToCamera(cameraInfo)
                    } label: {
                        Text(cameraInfo.zoomLabel)
                            .font(.headline)
                            .frame(width: 44, height: 44)
                            .background(
                                Capsule()
                                    .fill(cameraManager.currentCamera?.id == cameraInfo.id ? Color.black.opacity(0.4) : Color.black.opacity(0.2))
                            )
                            .overlay(
                                Capsule()
                                    .stroke(Color.white.opacity(0.6), lineWidth: cameraManager.currentCamera?.id == cameraInfo.id ? 2 : 1)
                            )
                    }
                    .foregroundColor(.white)
                }
            }
            .padding(.horizontal, 8)
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
                .builtInTrueDepthCamera,
            ],
            mediaType: .video,
            position: .unspecified
        )

        var discovered: [CameraInfo] = []
        
        let backUltra = discoverySession.devices.first(where: {
            $0.position == .back && $0.deviceType == .builtInUltraWideCamera
        })
        let backWide = discoverySession.devices.first(where: {
            $0.position == .back && $0.deviceType == .builtInWideAngleCamera
        }) ?? discoverySession.devices.first(where: { $0.position == .back })

        if let backUltra {
            discovered.append(.backUltra(backUltra))
        }
        if let backWide {
            discovered.append(.backWide(backWide))
        }

        let frontDevices = discoverySession.devices.filter { $0.position == .front }
        if let primaryFront = frontDevices.first(where: { $0.deviceType == .builtInTrueDepthCamera }) ??
            frontDevices.first(where: { $0.deviceType == .builtInWideAngleCamera }) ??
            frontDevices.first {
            let frontInfo = CameraInfo.front(primaryFront)
            discovered.append(frontInfo)
            printD("Camera front selected: device=\(primaryFront.uniqueID), type=\(primaryFront.deviceType.rawValue), label=\(frontInfo.zoomLabel)")
        }

        availableCameras = discovered.sorted { lhs, rhs in
            if lhs.position != rhs.position {
                return lhs.position == .back
            }
            if lhs.zoomSortValue != rhs.zoomSortValue {
                return lhs.zoomSortValue < rhs.zoomSortValue
            }
            return lhs.zoomLabel < rhs.zoomLabel
        }

        currentCamera = availableCameras.first(where: { $0.position == .back && abs($0.zoomSortValue - 1.0) < 0.01 }) ??
            availableCameras.first(where: { $0.position == .back }) ??
            availableCameras.first

        let backOptions = availableCameras
            .filter { $0.position == .back }
            .map(\.zoomLabel)
            .joined(separator: ", ")
        let backMapping = availableCameras
            .filter { $0.position == .back }
            .sorted { $0.zoomSortValue < $1.zoomSortValue }
            .map { "\($0.zoomLabel){\($0.device.uniqueID)|type=\($0.device.deviceType.rawValue)}" }
            .joined(separator: ", ")
        let frontOptions = availableCameras
            .filter { $0.position == .front }
            .map(\.zoomLabel)
            .joined(separator: ", ")
        printD("Camera options finalized: back=[\(backOptions)] front=[\(frontOptions)]")
        printD("Camera options mapping: back=[\(backMapping)]")
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
                resetZoom(on: currentCamera.device)
            }
            
            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
            }
        } catch {
            printD("Error setting up camera: \(error)")
        }
    }
    
    func switchToCamera(_ cameraInfo: CameraInfo) {
        let currentID = currentCamera?.device.uniqueID ?? "none"
        let targetID = cameraInfo.device.uniqueID
        let currentType = currentCamera?.device.deviceType.rawValue ?? "none"
        let targetType = cameraInfo.device.deviceType.rawValue
        printD("Camera switch requested: \(currentCamera?.zoomLabel ?? "none")[\(currentID)|\(currentType)] -> \(cameraInfo.zoomLabel)[\(targetID)|\(targetType)], zoomFactor=\(String(describing: cameraInfo.zoomFactor))")

        var didReplaceInput = false
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        do {
            if videoDeviceInput?.device.uniqueID != cameraInfo.device.uniqueID {
                guard try replaceActiveInput(with: cameraInfo.device) else {
                    printD("Camera switch failed: unable to activate target device \(cameraInfo.device.uniqueID)")
                    return
                }
                didReplaceInput = true
                rotationCoordinator = nil
                if !cameraInfo.device.hasFlash && flashMode != .off {
                    flashMode = .off
                }
            }

            let activeDevice = videoDeviceInput?.device ?? cameraInfo.device
            resetZoom(on: activeDevice)
            currentCamera = cameraInfo
        } catch {
            printD("Error switching camera: \(error)")
        }

        if didReplaceInput {
            NotificationCenter.default.post(name: .cameraDeviceChanged, object: cameraInfo)
        }
    }

    private func resetZoom(on device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            let minZoom = max(1.0, device.minAvailableVideoZoomFactor)
            let maxZoom = device.activeFormat.videoMaxZoomFactor
            let clamped = max(minZoom, min(1.0, maxZoom))
            device.videoZoomFactor = clamped
            printD("Camera resetZoom: device=\(device.uniqueID), type=\(device.deviceType.rawValue), clamped=\(clamped), min=\(minZoom), max=\(maxZoom)")
            device.unlockForConfiguration()
        } catch {
            printD("Error resetting zoom: \(error)")
        }
    }

    private func replaceActiveInput(with device: AVCaptureDevice) throws -> Bool {
        let previousInput = videoDeviceInput
        if let previousInput {
            session.removeInput(previousInput)
        }

        let newInput = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(newInput) else {
            printD("Camera replace input failed canAddInput=false for device=\(device.uniqueID)")
            if let previousInput, session.canAddInput(previousInput) {
                session.addInput(previousInput)
                printD("Camera replace input restored previous device=\(previousInput.device.uniqueID)")
            }
            return false
        }

        session.addInput(newInput)
        videoDeviceInput = newInput
        printD("Camera replace input succeeded device=\(device.uniqueID)")
        return true
    }

    func flipToOppositePosition() {
        guard let current = currentCamera else { return }
        
        let targetPosition: AVCaptureDevice.Position = current.position == .back ? .front : .back
        
        // Find the first camera of the opposite position (prefer native-feeling 1x).
        if let targetCamera = availableCameras.first(where: { $0.position == targetPosition && abs($0.zoomSortValue - 1.0) < 0.01 }) ??
            availableCameras.first(where: { $0.position == targetPosition && $0.device.deviceType == .builtInWideAngleCamera }) ??
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

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        if let previewLayer = layer as? AVCaptureVideoPreviewLayer {
            return previewLayer
        }
        return AVCaptureVideoPreviewLayer()
    }
}

#endif
