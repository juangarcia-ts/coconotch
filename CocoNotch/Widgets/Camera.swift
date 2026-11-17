import AVFoundation
import CocoNotchCore
import SwiftUI

extension NotchWidget {
    static let camera = NotchWidget(
        id: "camera",
        title: "Camera",
        systemImage: "web.camera",
        makeView: { AnyView(CameraView()) },
        makeSettings: { AnyView(CameraSettings()) }
    )
}

private let pickedIDKey = "camera.deviceID"
private let isMirroredKey = "camera.isMirrored"

private func listCameras() -> [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(
        deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified
    ).devices
}

private func resolveCameraID(pickedID: String, cameras: [AVCaptureDevice]) -> String? {
    getCameraID(
        pickedID: pickedID,
        defaultID: AVCaptureDevice.default(for: .video)?.uniqueID,
        availableIDs: cameras.map(\.uniqueID))
}

/// Owns the capture session. Starting and stopping block, so they run in order on a queue of their own.
nonisolated private final class CameraSession: @unchecked Sendable {
    let previewLayer: AVCaptureVideoPreviewLayer
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "CocoNotch.camera")

    init() {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
    }

    func start(deviceID: String, isMirrored: Bool) {
        queue.async {
            self.session.beginConfiguration()
            self.session.inputs.forEach(self.session.removeInput)
            if let device = AVCaptureDevice(uniqueID: deviceID),
                let input = try? AVCaptureDeviceInput(device: device), self.session.canAddInput(input)
            {
                self.session.addInput(input)
            }
            self.session.commitConfiguration()
            if let connection = self.previewLayer.connection, connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = isMirrored
            }
            self.session.startRunning()
        }
    }

    func stop() {
        queue.async { self.session.stopRunning() }
    }
}

private struct CameraPreview: NSViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // Set before wantsLayer, so the view hosts this layer and keeps it sized to its bounds.
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct CameraView: View {
    @AppStorage(pickedIDKey) private var pickedID = ""
    @AppStorage(isMirroredKey) private var isMirrored = true
    @State private var camera = CameraSession()
    @State private var status = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var hasCamera = true

    var body: some View {
        Group {
            switch status {
            case .authorized where hasCamera:
                CameraPreview(layer: camera.previewLayer)
                    .background(.black)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: 360)
            case .authorized:
                message("No camera found.")
            case .notDetermined:
                ProgressView()
            default:
                VStack(spacing: 10) {
                    message("CocoNotch can't use the camera. You can allow it in System Settings.")
                    Button("Open Privacy Settings") {
                        if let url = URL(
                            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
                        {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        // The notch closing removes this view, which cancels the task and stops the session, so the light goes off.
        .task(id: "\(pickedID) \(isMirrored)") {
            if status == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                status = AVCaptureDevice.authorizationStatus(for: .video)
            }
            guard status == .authorized, !Task.isCancelled else { return }
            guard let id = resolveCameraID(pickedID: pickedID, cameras: listCameras()) else {
                hasCamera = false
                return
            }
            hasCamera = true
            camera.start(deviceID: id, isMirrored: isMirrored)
        }
        .onDisappear { camera.stop() }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 360)
    }
}

private struct CameraSettings: View {
    @AppStorage(pickedIDKey) private var pickedID = ""
    @AppStorage(isMirroredKey) private var isMirrored = true
    @State private var cameras: [AVCaptureDevice] = []

    var body: some View {
        Form {
            Section("Preview") {
                Toggle("Mirror the preview", isOn: $isMirrored)
                if cameras.count > 1 {
                    Picker(
                        "Camera",
                        selection: Binding(
                            get: { resolveCameraID(pickedID: pickedID, cameras: cameras) ?? "" },
                            set: { pickedID = $0 })
                    ) {
                        ForEach(cameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { cameras = listCameras() }
    }
}
