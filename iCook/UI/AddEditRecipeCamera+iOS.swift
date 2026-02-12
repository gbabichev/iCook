#if os(iOS)
import SwiftUI
import Combine
import UIKit
@preconcurrency import AVFoundation

// MARK: - iOS Camera
// iOS Camera Support
// Enhanced iOS 17+ Camera Implementation with Multi-Camera Support

struct CameraInfo: Identifiable, Hashable {
    let id = UUID()
    let device: AVCaptureDevice
    let displayName: String
    let position: AVCaptureDevice.Position
    let zoomLabel: String
    let zoomFactor: CGFloat?
    let isVirtualZoom: Bool
    let zoomSortValue: CGFloat
    
    init(device: AVCaptureDevice, inferredZoomFactor: CGFloat?) {
        self.device = device
        self.position = device.position
        self.zoomFactor = nil
        self.isVirtualZoom = false
        
        let basePosition = position == .front ? "Front" : "Back"
        if let normalizedZoom = Self.preferredPhysicalZoom(for: device.deviceType, inferred: inferredZoomFactor) {
            let label = Self.formatZoomLabel(normalizedZoom)
            self.zoomLabel = label
            self.displayName = "\(basePosition) \(label)"
            self.zoomSortValue = normalizedZoom
        } else {
            switch device.deviceType {
            case .builtInUltraWideCamera:
                self.zoomLabel = "0.5x"
                self.displayName = "\(basePosition) 0.5x"
                self.zoomSortValue = 0.5
            case .builtInWideAngleCamera:
                self.zoomLabel = "1x"
                self.displayName = "\(basePosition) 1x"
                self.zoomSortValue = 1.0
            case .builtInTelephotoCamera:
                self.zoomLabel = "1x"
                self.displayName = "\(basePosition) 1x (Tele)"
                self.zoomSortValue = 1.0
            case .builtInDualCamera:
                self.zoomLabel = "1x"
                self.displayName = "\(basePosition) 1x (Dual)"
                self.zoomSortValue = 1.0
            case .builtInDualWideCamera:
                self.zoomLabel = "0.5/1x"
                self.displayName = "\(basePosition) 0.5/1x"
                self.zoomSortValue = 1.0
            case .builtInTripleCamera:
                self.zoomLabel = "0.5/1/2x"
                self.displayName = "\(basePosition) 0.5/1/2x"
                self.zoomSortValue = 1.0
            case .builtInTrueDepthCamera:
                self.zoomLabel = "1x"
                self.displayName = "\(basePosition) 1x"
                self.zoomSortValue = 1.0
            default:
                self.zoomLabel = "1x"
                self.displayName = "\(basePosition) 1x"
                self.zoomSortValue = 1.0
            }
        }
    }
    
    init(device: AVCaptureDevice, zoomFactor: CGFloat, displayZoomFactor: CGFloat) {
        self.device = device
        self.position = device.position
        self.zoomFactor = zoomFactor
        self.isVirtualZoom = true
        
        let basePosition = position == .front ? "Front" : "Back"
        let label = Self.formatZoomLabel(displayZoomFactor)
        self.zoomLabel = label
        self.displayName = "\(basePosition) \(label)"
        self.zoomSortValue = displayZoomFactor
    }
    
    fileprivate static func formatZoomLabel(_ factor: CGFloat) -> String {
        let rounded = (Double(factor) * 10).rounded() / 10
        if rounded.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(rounded))x"
        }
        return "\(rounded)x"
    }

    private static func preferredPhysicalZoom(for type: AVCaptureDevice.DeviceType, inferred: CGFloat?) -> CGFloat? {
        switch type {
        case .builtInUltraWideCamera:
            // Keep Apple's native UX label regardless of per-format FOV drift.
            return 0.5
        case .builtInWideAngleCamera, .builtInTrueDepthCamera:
            return 1.0
        case .builtInTelephotoCamera:
            guard let inferred, inferred.isFinite else { return nil }
            // Some devices report a telephoto type but FoV is effectively ~1x.
            // Treat those as 1x so they don't shadow synthetic/native 2x entries.
            if inferred < 1.35 { return 1.0 }
            let base = inferred
            let canonical: [CGFloat] = [2.0, 2.5, 3.0, 4.0, 5.0, 6.0]
            if let nearest = canonical.min(by: { abs($0 - base) < abs($1 - base) }),
               abs(nearest - base) <= 0.5 {
                return nearest
            }
            return CGFloat((Double(base) * 10).rounded() / 10)
        default:
            // Composite virtual cameras should keep combined labels (0.5/1x, etc.).
            return nil
        }
    }
}

struct CameraView: View {
    let onImageCaptured: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var cameraManager = CameraManager()
    @State private var showingCameraSelector = false // kept for backward compatibility, unused now
    
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
            .confirmationDialog("Select Camera", isPresented: $showingCameraSelector) {
                ForEach(cameraManager.availableCameras) { cameraInfo in
                    Button {
                        cameraManager.switchToCamera(cameraInfo)
                    } label: {
                        HStack {
                            Text(cameraInfo.zoomLabel)
                                .fontWeight(.semibold)
                            Text(cameraInfo.displayName)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                Button("Cancel", role: .cancel) { }
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
                .builtInTelephotoCamera,
                .builtInTrueDepthCamera,
                .builtInDualCamera,
                .builtInDualWideCamera,
                .builtInTripleCamera
            ],
            mediaType: .video,
            position: .unspecified
        )

        let preferredBackVirtualTypes: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInDualCamera
        ]
        let virtualBackDevice = discoverySession.devices.first(where: {
            $0.position == .back && preferredBackVirtualTypes.contains($0.deviceType)
        })

        var discovered: [CameraInfo] = []

        if let virtualBackDevice {
            let backWide = discoverySession.devices.first(where: {
                $0.position == .back && $0.deviceType == .builtInWideAngleCamera
            })
            let backUltra = discoverySession.devices.first(where: {
                $0.position == .back && $0.deviceType == .builtInUltraWideCamera
            })
            let usePhysicalDualWideProfile =
                virtualBackDevice.deviceType == .builtInDualWideCamera &&
                virtualBackDevice.minAvailableVideoZoomFactor >= 1.0 &&
                backWide != nil

            if usePhysicalDualWideProfile {
                var backInfos: [CameraInfo] = []
                if let backUltra {
                    backInfos.append(CameraInfo(device: backUltra, inferredZoomFactor: 0.5))
                }
                if let backWide {
                    backInfos.append(CameraInfo(device: backWide, inferredZoomFactor: 1.0))
                    let showDualWideTwoX = shouldShowDualWideTwoXShortcut(
                        virtualBackDevice: virtualBackDevice,
                        wideDevice: backWide
                    )
                    if showDualWideTwoX, backWide.activeFormat.videoMaxZoomFactor >= 2.0 {
                        backInfos.append(CameraInfo(device: backWide, zoomFactor: 2.0, displayZoomFactor: 2.0))
                    }
                    let wideSecondary = backWide.activeFormat.secondaryNativeResolutionZoomFactors
                    let virtualSecondary = virtualBackDevice.activeFormat.secondaryNativeResolutionZoomFactors
                    printD("Camera dual-wide 2x shortcut: enabled=\(showDualWideTwoX), wideSecondary=\(wideSecondary), virtualSecondary=\(virtualSecondary)")
                }

                var dedupByLabel: [String: CameraInfo] = [:]
                for info in backInfos.sorted(by: { $0.zoomSortValue < $1.zoomSortValue }) where dedupByLabel[info.zoomLabel] == nil {
                    dedupByLabel[info.zoomLabel] = info
                }
                discovered.append(contentsOf: dedupByLabel.values)
                printD("Camera physical dual-wide mode active: wide=\(backWide?.uniqueID ?? "none"), ultra=\(backUltra?.uniqueID ?? "none"), labels=[\(dedupByLabel.keys.sorted().joined(separator: ", "))]")
            } else {
                let backPresets = backZoomPresets(
                    for: virtualBackDevice,
                    wideReferenceDevice: backWide,
                    ultraReferenceDevice: backUltra
                )
                let backInfos: [CameraInfo] = backPresets.map { preset in
                    CameraInfo(
                        device: virtualBackDevice,
                        zoomFactor: preset.targetZoom,
                        displayZoomFactor: preset.displayZoom
                    )
                }

                // Keep one item per display label.
                var dedupByLabel: [String: CameraInfo] = [:]
                for info in backInfos.sorted(by: { $0.zoomSortValue < $1.zoomSortValue }) where dedupByLabel[info.zoomLabel] == nil {
                    dedupByLabel[info.zoomLabel] = info
                }
                discovered.append(contentsOf: dedupByLabel.values)
                let presetSummary = backPresets
                    .map { "\(CameraInfo.formatZoomLabel($0.displayZoom))=>\($0.targetZoom)" }
                    .joined(separator: ", ")
                printD("Camera virtual back mode active: device=\(virtualBackDevice.uniqueID), type=\(virtualBackDevice.deviceType.rawValue), presets=[\(presetSummary)]")
            }
        } else {
            // Fallback for devices without a virtual back camera.
            let backWideFOV = discoverySession.devices.first(where: {
                $0.position == .back && $0.deviceType == .builtInWideAngleCamera
            })?.activeFormat.videoFieldOfView

            let backPhysical = discoverySession.devices
                .filter { $0.position == .back }
                .map { device -> CameraInfo in
                    let inferredZoom: CGFloat?
                    if let backWideFOV, device.activeFormat.videoFieldOfView > 0 {
                        inferredZoom = CGFloat(backWideFOV / device.activeFormat.videoFieldOfView)
                    } else {
                        inferredZoom = nil
                    }
                    return CameraInfo(device: device, inferredZoomFactor: inferredZoom)
                }

            var dedupBack: [String: CameraInfo] = [:]
            for info in backPhysical where !info.zoomLabel.contains("/") {
                if dedupBack[info.zoomLabel] == nil {
                    dedupBack[info.zoomLabel] = info
                }
            }
            discovered.append(contentsOf: dedupBack.values)
            printD("Camera virtual back unavailable; using physical back devices count=\(dedupBack.count)")
        }

        let frontDevices = discoverySession.devices.filter { $0.position == .front }
        if let primaryFront = frontDevices.first(where: { $0.deviceType == .builtInTrueDepthCamera }) ??
            frontDevices.first(where: { $0.deviceType == .builtInWideAngleCamera }) ??
            frontDevices.first {
            let frontInfo = CameraInfo(device: primaryFront, inferredZoomFactor: 1.0)
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
            .map { "\($0.zoomLabel){\($0.device.uniqueID)|type=\($0.device.deviceType.rawValue)|virtual=\($0.isVirtualZoom)|zoom=\(String(describing: $0.zoomFactor))}" }
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
                configureWidestFormatIfNeeded(for: currentCamera.device)
            }
            
            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
            }
        } catch {
            print("Error setting up camera: \(error)")
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
            applyZoom(cameraInfo.zoomFactor, to: activeDevice)
            currentCamera = cameraInfo
        } catch {
            print("Error switching camera: \(error)")
        }

        if didReplaceInput {
            NotificationCenter.default.post(name: .cameraDeviceChanged, object: cameraInfo)
        }
    }

    private struct BackZoomPreset {
        let displayZoom: CGFloat
        let targetZoom: CGFloat
    }

    private func shouldShowDualWideTwoXShortcut(
        virtualBackDevice: AVCaptureDevice,
        wideDevice: AVCaptureDevice
    ) -> Bool {
        let epsilon: CGFloat = 0.2
        let hasWideSecondary2x = wideDevice.activeFormat.secondaryNativeResolutionZoomFactors
            .contains(where: { abs($0 - 2.0) <= epsilon })
        let hasVirtualSecondary2x = virtualBackDevice.activeFormat.secondaryNativeResolutionZoomFactors
            .contains(where: { abs($0 - 2.0) <= epsilon })
        return hasWideSecondary2x || hasVirtualSecondary2x
    }

    private func backZoomPresets(
        for virtualBackDevice: AVCaptureDevice,
        wideReferenceDevice: AVCaptureDevice?,
        ultraReferenceDevice: AVCaptureDevice?
    ) -> [BackZoomPreset] {
        let switchOvers = virtualBackDevice.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        let wideAnchorZoom = switchOvers.filter { $0 > 1.0 }.min()
        let hasUltraWideConstituent = virtualBackDevice.constituentDevices.contains {
            $0.deviceType == .builtInUltraWideCamera
        }
        let minZoom = max(0.5, virtualBackDevice.minAvailableVideoZoomFactor)
        let maxZoom = virtualBackDevice.activeFormat.videoMaxZoomFactor
        let upscaleThreshold = virtualBackDevice.activeFormat.videoZoomFactorUpscaleThreshold
        let qualityMaxZoom = upscaleThreshold > 1.0 ? min(maxZoom, upscaleThreshold) : maxZoom
        let boostedMaxZoom = min(maxZoom, qualityMaxZoom)
        let epsilon: CGFloat = 0.01
        let maxDisplayedZoom: CGFloat = 8.0

        // Convert device zoom factor space into displayed lens labels.
        // Some virtual devices start at an ultra-wide baseline (display 0.5x at target 1.0).
        var displayMultiplier: CGFloat = 1.0
        let virtualFOV = virtualBackDevice.activeFormat.videoFieldOfView
        let wideFOV = wideReferenceDevice?.activeFormat.videoFieldOfView
        let ultraFOV = ultraReferenceDevice?.activeFormat.videoFieldOfView
        var baselineMode = "wide"

        if let wideReferenceDevice,
           wideReferenceDevice.activeFormat.videoFieldOfView > 0,
           virtualBackDevice.activeFormat.videoFieldOfView > 0 {
            let ratio = CGFloat(
                wideReferenceDevice.activeFormat.videoFieldOfView /
                virtualBackDevice.activeFormat.videoFieldOfView
            )
            displayMultiplier = ratio
            if abs(displayMultiplier - 0.5) < 0.2 {
                displayMultiplier = 0.5
                baselineMode = "ultra"
            } else if abs(displayMultiplier - 1.0) < 0.2 {
                displayMultiplier = 1.0
                baselineMode = "wide"
            }
        }

        if let wideFOV, let ultraFOV {
            let deltaWide = abs(virtualFOV - wideFOV)
            let deltaUltra = abs(virtualFOV - ultraFOV)
            if deltaUltra + 1.0 < deltaWide {
                displayMultiplier = 0.5
                baselineMode = "ultra"
            } else if deltaWide + 1.0 < deltaUltra {
                displayMultiplier = 1.0
                baselineMode = "wide"
            }
        }

        if baselineMode != "ultra",
           hasUltraWideConstituent,
           let wideAnchorZoom,
           wideAnchorZoom > 1.1,
           wideAnchorZoom < 2.4,
           virtualFOV > 0,
           let wideFOV,
           wideFOV > 0 {
            // Fall back to switch-over scaling only when FOV also hints an ultra baseline.
            let fovRatio = CGFloat(wideFOV / virtualFOV)
            if fovRatio < 0.75 {
                let switchBasedMultiplier = 1.0 / wideAnchorZoom
                if switchBasedMultiplier >= 0.25, switchBasedMultiplier <= 1.0 {
                    displayMultiplier = switchBasedMultiplier
                    baselineMode = "ultra-switch"
                }
            }
        }

        if virtualBackDevice.deviceType == .builtInDualWideCamera,
           hasUltraWideConstituent,
           minZoom >= 1.0,
           displayMultiplier <= 0.55 {
            // Some dual-wide devices report an ultra-style baseline in metadata while
            // effective zoom behavior is already normalized around 1x at target=1.0.
            // Normalize to avoid 1x->2.0 and 2x->4.0 overshoot.
            displayMultiplier = 1.0
            baselineMode = "dualwide-normalized"
        }

        printD("Camera virtual zoom thresholds: switchOvers=\(switchOvers), wideAnchor=\(String(describing: wideAnchorZoom)), hasUltraWide=\(hasUltraWideConstituent), virtualFOV=\(virtualFOV), wideFOV=\(String(describing: wideFOV)), ultraFOV=\(String(describing: ultraFOV)), baselineMode=\(baselineMode), minZoom=\(minZoom), maxZoom=\(maxZoom), qualityMax=\(qualityMaxZoom), displayMultiplier=\(displayMultiplier)")

        var candidateTargets: [CGFloat] = [1.0]
        candidateTargets.append(contentsOf: switchOvers.filter { $0 > 1.0 })

        // Seed native-like display stops even when switch-over metadata is sparse.
        // On dual-wide baselines, 0.5x/1x/2x should still exist.
        let canonicalDisplays: [CGFloat] = (hasUltraWideConstituent || displayMultiplier <= 0.75) ? [0.5, 1.0, 2.0] : [1.0, 2.0]
        for display in canonicalDisplays {
            let target = displayMultiplier > 0 ? (display / displayMultiplier) : display
            if target <= (maxZoom + epsilon) {
                candidateTargets.append(max(minZoom, target))
            }
        }

        if let strongestOptical = switchOvers.filter({ $0 > 1.0 }).max() {
            var boosted = strongestOptical * 2.0
            while boosted <= (boostedMaxZoom + epsilon),
                  boosted * displayMultiplier <= (maxDisplayedZoom + epsilon) {
                candidateTargets.append(boosted)
                boosted *= 2.0
            }
        }

        var seenDisplayTenths: Set<Int> = []
        var presets = candidateTargets
            .map { target -> BackZoomPreset? in
                guard target >= (minZoom - epsilon), target <= (maxZoom + epsilon) else {
                    return nil
                }
                let display = CGFloat((Double(target * displayMultiplier) * 10).rounded() / 10)
                guard display > 0, display <= (maxDisplayedZoom + epsilon) else {
                    return nil
                }
                let key = Int((display * 10).rounded())
                if seenDisplayTenths.contains(key) {
                    return nil
                }
                seenDisplayTenths.insert(key)
                return BackZoomPreset(displayZoom: display, targetZoom: target)
            }
            .compactMap { $0 }
            .sorted { lhs, rhs in
                if lhs.displayZoom != rhs.displayZoom {
                    return lhs.displayZoom < rhs.displayZoom
                }
                return lhs.targetZoom < rhs.targetZoom
            }
        
        if presets.isEmpty {
            let fallbackTarget = max(minZoom, min(1.0, maxZoom))
            let fallbackDisplay = CGFloat((Double(fallbackTarget * displayMultiplier) * 10).rounded() / 10)
            presets = [BackZoomPreset(displayZoom: max(0.5, fallbackDisplay), targetZoom: fallbackTarget)]
        }

        // Keep a 0.5x affordance for ultra-wide virtual stacks even when target space starts at 1.0.
        if hasUltraWideConstituent,
           !presets.contains(where: { abs($0.displayZoom - 0.5) < epsilon }) {
            presets.insert(BackZoomPreset(displayZoom: 0.5, targetZoom: minZoom), at: 0)
        }

        // Ensure unique display labels after any synthetic insertion.
        var dedupByDisplay: [Int: BackZoomPreset] = [:]
        for preset in presets {
            let key = Int((preset.displayZoom * 10).rounded())
            if dedupByDisplay[key] == nil {
                dedupByDisplay[key] = preset
            }
        }
        presets = dedupByDisplay.values.sorted { lhs, rhs in
            if lhs.displayZoom != rhs.displayZoom {
                return lhs.displayZoom < rhs.displayZoom
            }
            return lhs.targetZoom < rhs.targetZoom
        }

        return presets
    }

    private func applyZoom(_ zoomFactor: CGFloat?, to device: AVCaptureDevice) {
        let target = zoomFactor ?? 1.0
        do {
            try device.lockForConfiguration()
            let minZoom = max(0.5, device.minAvailableVideoZoomFactor)
            let maxZoom = device.activeFormat.videoMaxZoomFactor
            let clamped = max(minZoom, min(target, maxZoom))
            device.videoZoomFactor = clamped
            printD("Camera applyZoom: device=\(device.uniqueID), type=\(device.deviceType.rawValue), target=\(target), clamped=\(clamped), min=\(minZoom), max=\(maxZoom)")
            device.unlockForConfiguration()
        } catch {
            print("Error setting zoom: \(error)")
        }
    }

    private func configureWidestFormatIfNeeded(for device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            let currentFOV = device.activeFormat.videoFieldOfView
            if let widest = device.formats.max(by: { lhs, rhs in
                lhs.videoFieldOfView < rhs.videoFieldOfView
            }), widest != device.activeFormat {
                device.activeFormat = widest
                let updatedFOV = device.activeFormat.videoFieldOfView
                printD("Camera format normalized: device=\(device.uniqueID), type=\(device.deviceType.rawValue), fov=\(currentFOV)->\(updatedFOV)")
            }
            device.unlockForConfiguration()
        } catch {
            printD("Camera format normalization failed: device=\(device.uniqueID), error=\(error.localizedDescription)")
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
        configureWidestFormatIfNeeded(for: device)
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

// Add this extension for the notification
extension Notification.Name {
    static let cameraDeviceChanged = Notification.Name("cameraDeviceChanged")
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

#endif
