import AVFoundation
import SwiftUI
import UIKit

@MainActor
final class InAppCameraModel: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    enum Status: Equatable {
        case starting
        case running
        case failed(String)
    }

    @Published private(set) var status: Status = .starting
    @Published private(set) var capturedImage: UIImage?
    @Published private(set) var isCapturing = false
    @Published private(set) var captureError: String?

    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "vuuro.inAppCamera.session")
    private var device: AVCaptureDevice?
    private var configured = false
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?

    weak var previewLayer: AVCaptureVideoPreviewLayer? {
        didSet { setUpRotation() }
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    if granted {
                        self.configureAndRun()
                    } else {
                        self.status = .failed(vuuroLocalized("Camera access is off. Turn it on in Settings to take a photo."))
                    }
                }
            }
        default:
            status = .failed(vuuroLocalized("Camera access is off. Turn it on in Settings to take a photo."))
        }
    }

    func stop() {
        rotationObservation?.invalidate()
        rotationObservation = nil
        let session = self.session
        sessionQueue.async {
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    func retake() {
        capturedImage = nil
        captureError = nil
    }

    func capture() {
        guard !isCapturing, status == .running else { return }
        isCapturing = true
        captureError = nil
        if let connection = output.connection(with: .video), let coordinator = rotationCoordinator {
            let angle = coordinator.videoRotationAngleForHorizonLevelCapture
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        }
        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = .balanced
        output.capturePhoto(with: settings, delegate: self)
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation()
        let message = error?.localizedDescription
        Task { @MainActor in
            self.isCapturing = false
            if let message {
                DiagnosticsLog.shared.record("In-app camera capture failed: \(message)", category: .error)
                self.captureError = vuuroLocalized("The photo could not be taken. Try again.")
                return
            }
            guard let data, let image = UIImage(data: data) else {
                DiagnosticsLog.shared.record("In-app camera returned no image data", category: .error)
                self.captureError = vuuroLocalized("The photo could not be taken. Try again.")
                return
            }
            self.capturedImage = image
        }
    }

    private func configureAndRun() {
        if !configured {
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                status = .failed(vuuroLocalized("This device has no back camera."))
                return
            }
            let input: AVCaptureDeviceInput
            do {
                input = try AVCaptureDeviceInput(device: device)
            } catch {
                DiagnosticsLog.shared.record("In-app camera input failed: \(error.localizedDescription)", category: .error)
                status = .failed(vuuroLocalized("The camera didn't start. Close any other app using the camera, then try again."))
                return
            }
            session.beginConfiguration()
            session.sessionPreset = .photo
            guard session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration()
                status = .failed(vuuroLocalized("The camera didn't start. Close any other app using the camera, then try again."))
                return
            }
            session.addInput(input)
            session.addOutput(output)
            output.maxPhotoQualityPrioritization = .balanced
            session.commitConfiguration()
            self.device = device
            configured = true
            setUpRotation()
        }
        let session = self.session
        sessionQueue.async {
            if !session.isRunning {
                session.startRunning()
            }
            Task { @MainActor in
                if self.status == .starting {
                    self.status = .running
                }
            }
        }
    }

    private func setUpRotation() {
        guard let device, let previewLayer, rotationCoordinator == nil else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        applyPreviewAngle(coordinator.videoRotationAngleForHorizonLevelPreview)
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            Task { @MainActor in
                self?.applyPreviewAngle(angle)
            }
        }
    }

    private func applyPreviewAngle(_ angle: CGFloat) {
        guard let connection = previewLayer?.connection, connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }
}

final class CameraPreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer? { layer as? AVCaptureVideoPreviewLayer }
}

struct CameraPreview: UIViewRepresentable {
    let camera: InAppCameraModel

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.backgroundColor = .black
        view.previewLayer?.session = camera.session
        view.previewLayer?.videoGravity = .resizeAspect
        camera.previewLayer = view.previewLayer
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {}
}

struct CameraPickerView: View {
    let onImageCaptured: (UIImage) -> Void
    let onDismiss: () -> Void

    @StateObject private var camera = InAppCameraModel()
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var isLandscape: Bool { verticalSizeClass == .compact }

    private var failureMessage: String? {
        if case .failed(let message) = camera.status { return message }
        return nil
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image = camera.capturedImage {
                layout(content: reviewImage(image), controls: reviewControls(image))
            } else if let message = failureMessage {
                failedView(message)
            } else {
                layout(content: livePreview, controls: liveControls)
            }
        }
        .statusBarHidden()
        .rotationUnlocked()
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        .accessibilityIdentifier("inAppCamera")
    }

    @ViewBuilder
    private func layout<Content: View, Controls: View>(content: Content, controls: Controls) -> some View {
        if isLandscape {
            HStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                controls
                    .frame(width: 116)
                    .frame(maxHeight: .infinity)
            }
        } else {
            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                controls
                    .frame(height: 132)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var livePreview: some View {
        ZStack {
            CameraPreview(camera: camera)
            if camera.status == .starting {
                ProgressView().tint(.white)
            }
            if let error = camera.captureError {
                VStack {
                    Spacer()
                    Text(error)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.7), in: Capsule())
                        .padding(.bottom, 12)
                }
            }
        }
    }

    private func reviewImage(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .accessibilityIdentifier("inAppCamera.review")
    }

    @ViewBuilder
    private var liveControls: some View {
        if isLandscape {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                shutterButton
                Spacer(minLength: 0)
                cancelButton
                    .padding(.bottom, 16)
            }
        } else {
            HStack(spacing: 0) {
                cancelButton
                    .frame(width: 96)
                Spacer(minLength: 0)
                shutterButton
                Spacer(minLength: 0)
                Color.clear
                    .frame(width: 96, height: 1)
            }
            .padding(.horizontal, 12)
        }
    }

    @ViewBuilder
    private func reviewControls(_ image: UIImage) -> some View {
        if isLandscape {
            VStack(spacing: 16) {
                Spacer(minLength: 0)
                usePhotoButton(image)
                retakeButton
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
        } else {
            HStack(spacing: 0) {
                retakeButton
                Spacer(minLength: 0)
                usePhotoButton(image)
            }
            .padding(.horizontal, 24)
        }
    }

    private var shutterButton: some View {
        Button {
            camera.capture()
        } label: {
            ZStack {
                Circle()
                    .stroke(Color.white, lineWidth: 4)
                    .frame(width: 72, height: 72)
                Circle()
                    .fill(Color.white)
                    .frame(width: 58, height: 58)
                    .scaleEffect(camera.isCapturing ? 0.85 : 1)
                if camera.isCapturing {
                    ProgressView().tint(.black)
                }
            }
            .animation(.easeOut(duration: 0.1), value: camera.isCapturing)
        }
        .buttonStyle(.plain)
        .disabled(camera.isCapturing || camera.status != .running)
        .accessibilityLabel(Text(vuuroLocalized("Take photo")))
        .accessibilityIdentifier("inAppCamera.shutter")
    }

    private var cancelButton: some View {
        Button {
            onDismiss()
        } label: {
            Text(vuuroLocalized("Cancel"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("inAppCamera.cancel")
    }

    private var retakeButton: some View {
        Button {
            camera.retake()
        } label: {
            Text(vuuroLocalized("Retake"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("inAppCamera.retake")
    }

    private func usePhotoButton(_ image: UIImage) -> some View {
        Button {
            onImageCaptured(image)
            onDismiss()
        } label: {
            Text(vuuroLocalized("Use photo"))
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.black)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(VuuroColor.lime, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("inAppCamera.usePhoto")
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.system(size: 28))
                .foregroundStyle(VuuroColor.accent)
            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button(vuuroLocalized("Open Settings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                .tint(.white)
                Button(vuuroLocalized("Close")) {
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(VuuroColor.accent)
            }
        }
        .padding(32)
        .frame(maxWidth: 420)
        .accessibilityIdentifier("inAppCamera.failed")
    }
}
