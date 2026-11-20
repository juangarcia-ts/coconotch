import AVFoundation
import CocoNotchCore
import SwiftUI

extension NotchWidget {
    static let camera = NotchWidget(
        id: "camera",
        title: String(localized: "Camera"),
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
    ).devices.filter { !$0.isSuspended }  // A closed lid suspends the built-in camera, which then shows only black.
}

private func resolveCameraID(pickedID: String, cameras: [AVCaptureDevice]) -> String? {
    getCameraID(
        pickedID: pickedID,
        defaultID: AVCaptureDevice.default(for: .video)?.uniqueID,
        availableIDs: cameras.map(\.uniqueID))
}

/// Owns the capture session. Starting and stopping block, so they run in order on a queue of their own.
nonisolated private final class CameraSession: @unchecked Sendable {
    static let shared = CameraSession()
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "CocoNotch.camera")
    // A rebuilt view can start before the old one stops, so the session runs while anyone still uses it.
    private var userCount = 0

    func start(deviceID: String, isMirrored: Bool) {
        queue.async {
            self.userCount += 1
            self.show(deviceID: deviceID, isMirrored: isMirrored)
        }
    }

    /// Brings a stalled session back, such as after the camera is unplugged and plugged in again.
    func keepShowing(deviceID: String, isMirrored: Bool) {
        queue.async {
            if self.userCount > 0 { self.show(deviceID: deviceID, isMirrored: isMirrored) }
        }
    }

    private func show(deviceID: String, isMirrored: Bool) {
        let current = self.session.inputs.first as? AVCaptureDeviceInput
        // A camera that reconnects comes back as a new device, so the old input stays black.
        if current?.device.uniqueID != deviceID || current?.device.isConnected != true {
            self.session.beginConfiguration()
            self.session.inputs.forEach(self.session.removeInput)
            if let device = AVCaptureDevice(uniqueID: deviceID),
                let input = try? AVCaptureDeviceInput(device: device), self.session.canAddInput(input)
            {
                self.session.addInput(input)
            }
            self.session.commitConfiguration()
        }
        // Includes every preview layer's connection, so each view gets the setting.
        for connection in self.session.connections where connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = isMirrored
        }
        // Does nothing while running; restarts a session a runtime error stopped.
        self.session.startRunning()
    }

    func stop() {
        queue.async {
            self.userCount -= 1
            if self.userCount == 0 { self.session.stopRunning() }
        }
    }
}

private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        // A layer can only live in one view, so each preview gets its own.
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
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
    private let camera = CameraSession.shared
    @State private var status = AVCaptureDevice.authorizationStatus(for: .video)
    // Nil until the first look, so "No camera found" doesn't flash on open.
    @State private var cameras: [AVCaptureDevice]?

    var body: some View {
        Group {
            switch status {
            case .authorized where cameras?.isEmpty != true:
                CameraPreview(session: camera.session)
                    .background(.black)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .topTrailing) {
                        if let cameras, cameras.count > 1 {
                            CameraPicker(cameras: cameras).labelsHidden().controlSize(.small).fixedSize().padding(8)
                        }
                    }
                    .frame(maxWidth: 360)
            case .authorized:
                WidgetPrompt(
                    systemImage: NotchWidget.camera.systemImage, message: String(localized: "No camera found."))
            case .notDetermined:
                ProgressView()
            default:
                WidgetPrompt(
                    systemImage: NotchWidget.camera.systemImage,
                    message: String(localized: "CocoNotch can't use the camera. You can allow it in System Settings.")
                ) {
                    Button("Open Privacy Settings") { openPrivacySettings("Privacy_Camera") }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        // Runs while the view is on screen; the notch closing cancels it, which stops the session and the light.
        .task(id: "\(pickedID) \(isMirrored)") {
            if status == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                status = AVCaptureDevice.authorizationStatus(for: .video)
            }
            guard status == .authorized else { return }
            var startedID: String?
            // ponytail: polls for plugged and unplugged cameras; use AVCaptureDevice connect notifications if it costs.
            while !Task.isCancelled {
                let found = listCameras()
                cameras = found
                let id = resolveCameraID(pickedID: pickedID, cameras: found)
                if id != startedID {
                    if startedID != nil { camera.stop() }
                    if let id { camera.start(deviceID: id, isMirrored: isMirrored) }
                    startedID = id
                } else if let id {
                    camera.keepShowing(deviceID: id, isMirrored: isMirrored)
                }
                try? await Task.sleep(for: .seconds(2))
            }
            if startedID != nil { camera.stop() }
        }
    }
}

private struct CameraPicker: View {
    let cameras: [AVCaptureDevice]
    @AppStorage(pickedIDKey) private var pickedID = ""

    var body: some View {
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

private struct CameraSettings: View {
    @AppStorage(isMirroredKey) private var isMirrored = true
    @State private var cameras: [AVCaptureDevice] = []

    var body: some View {
        Form {
            Section("Preview") {
                Toggle("Mirror the preview", isOn: $isMirrored)
                if cameras.count > 1 { CameraPicker(cameras: cameras) }
            }
        }
        .formStyle(.grouped)
        .onAppear { cameras = listCameras() }
    }
}
