import AVFoundation
import CoreVideo
import Foundation
import os

/// Webcam capture. Adapted from ~/give-it-2-me/Sources/Camera.swift — same permission flow,
/// but it hands the whole pixel buffer to the segmenter instead of averaging it down to a
/// colour grid, and it can be pointed at any attached camera including an iPhone over
/// Continuity Camera.
final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "segcam.capture")
    private let output = AVCaptureVideoDataOutput()

    /// Camera choice is worth a real log line: it is the one thing that fails quietly (an
    /// iPhone that is asleep, a device already in use) and it can be read back with
    /// `log show --predicate 'subsystem == "com.jamecoyne.segcam"'`.
    private static let log = Logger(subsystem: "com.jamecoyne.segcam", category: "camera")

    /// The chosen camera, remembered by unique ID rather than by index: the list changes
    /// underfoot when an iPhone wakes up or wanders off, so an index means nothing.
    private(set) var currentDeviceID: String?

    /// Called on the capture queue with each frame.
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// Called on the main queue with a human-readable status, or nil when running.
    var onStatus: ((String?) -> Void)?
    /// Called on the main queue when cameras appear, vanish, or the choice changes.
    var onDevicesChanged: (() -> Void)?

    var deviceName: String {
        (session.inputs.first as? AVCaptureDeviceInput)?.device.localizedName ?? "no camera"
    }

    /// Every camera macOS will hand us: built-in, USB/external, and iPhones over Continuity
    /// Camera. Virtual cameras (OBS and friends) show up as `.external`.
    static func availableDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video, position: .unspecified
        ).devices
    }

    override init() {
        super.init()
        // An iPhone becomes available when it wakes and disappears when it walks away, so the
        // camera list is live, not something to read once at launch.
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                self?.devicesChanged(disconnected: note.object as? AVCaptureDevice)
            }
        }
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            onStatus?("Waiting for camera permission…")
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    granted
                        ? self.configureAndRun()
                        : self.onStatus?("Camera access denied.\nEnable it in System Settings › Privacy & Security › Camera.")
                }
            }
        default:
            onStatus?("Camera access denied.\nEnable it in System Settings › Privacy & Security › Camera.")
        }
    }

    func stop() {
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    // MARK: - Choosing a camera

    /// Switch to a specific camera.
    func select(_ device: AVCaptureDevice) {
        currentDeviceID = device.uniqueID
        // Waking an iPhone takes a beat, so say so rather than showing a frozen frame.
        onStatus?("Switching to \(device.localizedName)…")
        queue.async { [weak self] in
            guard let self else { return }
            let ok = swapInput(to: device)
            DispatchQueue.main.async {
                self.onStatus?(ok ? nil : "Could not open \(device.localizedName).")
                self.onDevicesChanged?()
            }
        }
    }

    /// Next camera in the list, starting from whichever one is actually in use.
    func cycleDevice() {
        let devices = Camera.availableDevices()
        guard devices.count > 1 else { return }
        let current = devices.firstIndex { $0.uniqueID == currentDeviceID } ?? 0
        select(devices[(current + 1) % devices.count])
    }

    /// Choose a camera *before* the session starts, so the app can open on the iPhone
    /// rather than opening on the built-in one and visibly switching.
    @discardableResult
    func preferDevice(matching text: String) -> Bool {
        let needle = text.lowercased()
        guard let match = Camera.availableDevices().first(where: {
            $0.localizedName.lowercased().contains(needle)
        }) else { return false }
        currentDeviceID = match.uniqueID
        return true
    }

    /// Pick the first camera whose name contains `text` (case-insensitive) — "iphone" is
    /// enough to land on a Continuity Camera. Returns false if nothing matched.
    @discardableResult
    func selectDevice(matching text: String) -> Bool {
        let needle = text.lowercased()
        guard let match = Camera.availableDevices().first(where: {
            $0.localizedName.lowercased().contains(needle)
        }) else { return false }
        select(match)
        return true
    }

    private func devicesChanged(disconnected: AVCaptureDevice?) {
        let names = Camera.availableDevices().map(\.localizedName).joined(separator: ", ")
        Camera.log.notice("cameras available: \(names, privacy: .public)")
        // If the camera we were using just walked away, fall back to whatever is left rather
        // than sitting on a dead session.
        if let disconnected, disconnected.uniqueID == currentDeviceID,
           let fallback = Camera.availableDevices().first {
            select(fallback)
            return
        }
        onDevicesChanged?()
    }

    // MARK: - Session

    /// The built-in camera happily delivers ~47 fps, which is 55% more segmenting, cropping
    /// and window making than anyone can see. 30 is plenty for this.
    private static func capFrameRate(_ device: AVCaptureDevice, fps: Int32 = 30) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        let wanted = CMTime(value: 1, timescale: fps)
        // Never ask for a rate the active format can't do — an iPhone's formats are not the
        // built-in camera's.
        if let range = device.activeFormat.videoSupportedFrameRateRanges.first,
           CMTimeCompare(wanted, range.minFrameDuration) >= 0 {
            device.activeVideoMinFrameDuration = wanted
        }
        device.unlockForConfiguration()
    }

    /// Capture queue. Returns false if the camera could not be opened.
    private func swapInput(to device: AVCaptureDevice) -> Bool {
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }

        var opened = false
        if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
            opened = true
            // Presets are per-device: an iPhone may not offer the same ones as the built-in.
            session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
        }
        session.commitConfiguration()

        if opened {
            // After the commit, not inside it: committing re-negotiates the active format and
            // drops the frame duration.
            Camera.capFrameRate(device)
            let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            Camera.log.notice("using camera \(device.localizedName, privacy: .public) \(dimensions.width)x\(dimensions.height)")
        } else {
            Camera.log.error("could not open camera \(device.localizedName, privacy: .public)")
        }
        return opened
    }

    private func configureAndRun() {
        let devices = Camera.availableDevices()
        guard let device = devices.first(where: { $0.uniqueID == currentDeviceID }) ?? devices.first else {
            onStatus?("No camera found.")
            return
        }
        currentDeviceID = device.uniqueID

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true      // slow frames get dropped, never queued
        output.setSampleBufferDelegate(self, queue: queue)
        session.beginConfiguration()
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()

        queue.async { [weak self] in
            guard let self else { return }
            let ok = swapInput(to: device)
            session.startRunning()
            Camera.capFrameRate(device)
            DispatchQueue.main.async {
                self.onStatus?(ok ? nil : "Could not open \(device.localizedName).")
                self.onDevicesChanged?()
            }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixels)
    }
}
