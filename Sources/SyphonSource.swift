import CoreVideo
import Foundation
import IOSurface
import os

/// A Syphon server someone is publishing — TouchDesigner's Syphon Spout Out TOP, Resolume,
/// OBS, anything.
struct SyphonServerInfo: Equatable {
    let uuid: String
    let appName: String
    let feedName: String
    let description: [String: String]

    /// "TouchDesigner — Syphon Spout Out", or just the app name if the feed is unnamed.
    var displayName: String {
        feedName.isEmpty ? appName : "\(appName) — \(feedName)"
    }

    static func == (a: SyphonServerInfo, b: SyphonServerInfo) -> Bool { a.uuid == b.uuid }
}

/// Reads frames from a Syphon server as if it were a camera.
///
/// Syphon shares GPU surfaces, and `SyphonClientBase`'s subclassing category hands over the
/// live `IOSurface` directly — which `CVPixelBufferCreateWithIOSurface` wraps with no copy at
/// all, so the segmenters see exactly the same BGRA buffer shape they get from a webcam and
/// nothing else in the app has to know where the frame came from.
final class SyphonSource {
    private static let log = Logger(subsystem: "com.jamecoyne.segcam", category: "syphon")

    /// Called on the capture queue with each frame.
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// Called on the main queue with a human-readable status, or nil when running.
    var onStatus: ((String?) -> Void)?
    /// Called on the main queue when servers appear or retire.
    var onServersChanged: (() -> Void)?
    /// Called on the main queue with the live surface, for the overlay preview.
    var onSurface: ((IOSurfaceRef) -> Void)?

    private(set) var current: SyphonServerInfo?
    private var client: SyphonClientBase?
    private let queue = DispatchQueue(label: "segcam.syphon")
    private let lock = NSLock()
    private var busy = false
    private var observers: [NSObjectProtocol] = []

    var isRunning: Bool { client != nil }
    var sourceName: String { current?.displayName ?? "no syphon feed" }

    init() {
        // Servers come and go as patches are opened and closed, so the list is live.
        for name in [NSNotification.Name.SyphonServerAnnounce, .SyphonServerRetire] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                self?.serversChanged()
            })
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    static func servers() -> [SyphonServerInfo] {
        let raw = (SyphonServerDirectory.shared().servers as? [[String: Any]]) ?? []
        return raw.compactMap { entry in
            guard let uuid = entry[SyphonServerDescriptionUUIDKey] as? String else { return nil }
            return SyphonServerInfo(
                uuid: uuid,
                appName: entry[SyphonServerDescriptionAppNameKey] as? String ?? "Syphon",
                feedName: entry[SyphonServerDescriptionNameKey] as? String ?? "",
                description: entry.compactMapValues { $0 as? String })
        }
    }

    /// Connect to a specific feed. Safe to call repeatedly; the old client is torn down first.
    func connect(to info: SyphonServerInfo) {
        // Reconnecting to the feed we are already reading would tear down a live client for
        // no reason — and tearing one down while its messaging thread is mid-callback
        // segfaults inside Syphon.
        guard current != info else { return }
        stop()
        guard let raw = ((SyphonServerDirectory.shared().servers as? [[String: Any]]) ?? [])
            .first(where: { $0[SyphonServerDescriptionUUIDKey] as? String == info.uuid })
        else {
            onStatus?("Syphon feed \"\(info.displayName)\" is not published any more.")
            return
        }

        current = info
        onStatus?("Connecting to \(info.displayName)…")
        let client = SyphonClientBase(serverDescription: raw, options: nil) { [weak self] _ in
            self?.frameAvailable()
        }
        self.client = client
        SyphonSource.log.notice("connected to syphon server \(info.displayName, privacy: .public)")
        onStatus?(nil)
        // Deliberately no onServersChanged here: this is called *from* that callback, and
        // re-entering it is what caused the double-connect crash.
    }

    func stop() {
        client?.stop()
        client = nil
        current = nil
    }

    private func frameAvailable() {
        // Syphon can publish faster than we can segment; drop rather than queue up.
        lock.lock()
        let skip = busy
        if !skip { busy = true }
        lock.unlock()
        guard !skip else { return }

        queue.async { [weak self] in
            guard let self else { return }
            defer {
                lock.lock()
                busy = false
                lock.unlock()
            }
            // `newSurface` is a +1 CF return, and it is the very surface TouchDesigner
            // rendered into — no copy, no GPU readback.
            guard let surface = client?.newSurface().takeRetainedValue() else { return }
            guard let buffer = SyphonSource.wrap(surface) else { return }
            onFrame?(buffer)
            DispatchQueue.main.async { [weak self] in self?.onSurface?(surface) }
        }
    }

    /// Wraps a Syphon surface as a pixel buffer the rest of the app can treat like a camera
    /// frame.
    ///
    /// `CVPixelBufferCreateWithIOSurface` is the obvious call and it does not work here:
    /// Syphon's surfaces carry **no pixel format** (`IOSurfaceGetPixelFormat` is 0), so
    /// CoreVideo rejects them with kCVReturnInvalidArgument whether or not BGRA is passed in
    /// the attributes. Syphon's contract says the surface is always BGRA8, so wrap its bytes
    /// directly and say so — still zero-copy, since the buffer points at the surface's own
    /// memory. The surface stays locked and retained until the buffer is released.
    private static func wrap(_ surface: IOSurfaceRef) -> CVPixelBuffer? {
        guard IOSurfaceLock(surface, .readOnly, nil) == kIOReturnSuccess else { return nil }
        guard let base = IOSurfaceGetBaseAddress(surface) as UnsafeMutableRawPointer? else {
            IOSurfaceUnlock(surface, .readOnly, nil)
            return nil
        }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreateWithBytes(
            kCFAllocatorDefault,
            IOSurfaceGetWidth(surface),
            IOSurfaceGetHeight(surface),
            kCVPixelFormatType_32BGRA,
            base,
            IOSurfaceGetBytesPerRow(surface),
            // Careful: the first parameter is the refCon, the second is the base address.
            // Reading them the wrong way round unlocks a garbage pointer and segfaults.
            { refCon, _ in
                guard let refCon else { return }
                let surface = Unmanaged<IOSurfaceRef>.fromOpaque(refCon).takeRetainedValue()
                IOSurfaceUnlock(surface, .readOnly, nil)
            },
            Unmanaged.passRetained(surface).toOpaque(),
            nil,
            &buffer)

        guard status == kCVReturnSuccess, let buffer else {
            IOSurfaceUnlock(surface, .readOnly, nil)
            log.error("could not wrap syphon surface: \(status)")
            return nil
        }
        return buffer
    }

    private func serversChanged() {
        let names = SyphonSource.servers().map(\.displayName).joined(separator: ", ")
        SyphonSource.log.notice("syphon servers: \(names.isEmpty ? "none" : names, privacy: .public)")

        // If the feed we were reading just went away, say so rather than showing a stale frame.
        if let current, !SyphonSource.servers().contains(current) {
            stop()
            onStatus?("Syphon feed \"\(current.displayName)\" stopped publishing.")
        }
        onServersChanged?()
    }
}
