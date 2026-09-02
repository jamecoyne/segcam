import AVFoundation
import AppKit
import Foundation

let appName = "segcam"

/// Borderless windows can't become key unless they say so — and the control strip has to
/// stay key in swarm mode, or there is no way to press `h` and come back.
final class StripWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum Display { case overlay, swarm }

    private var window: NSWindow!
    private var stage: CameraStage!
    private var strip: StripWindow!
    private let stripHUD = HUDView()

    private let camera = Camera()
    private let syphon = SyphonSource()
    private let engine = SegmentEngine()
    private let swarm = SegmentSwarm()

    private var keyMonitor: Any?
    private var cameraMenu: NSMenu?
    /// A `--syphon` request that hasn't found its feed yet. The server directory is populated
    /// by announcements that arrive after launch, so an immediate lookup finds nothing.
    private var pendingFeed: String?
    private var display: Display = .overlay
    private var mirrored = true
    private var showLabels = true
    private var settings = SegmentSettings()
    private var lastResult = SegmentEngine.Result()

    func applicationDidFinishLaunching(_ notification: Notification) {
        stage = CameraStage(frame: NSRect(x: 0, y: 0, width: 960, height: 600))

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = appName
        window.contentView = stage
        window.setFrameAutosaveName("SegcamWindow")
        window.center()
        window.makeKeyAndOrderFront(nil)

        buildStrip()
        buildMenu()

        for hud in [stage.hud, stripHUD] {
            hud.onSlider = { [weak self, weak hud] value in
                guard let self else { return }
                mutate { $0.motionSensitivityFraction = value }
                syncControls(except: hud)      // never write back to the one being dragged
            }
        }

        engine.settings = settings
        engine.onResult = { [weak self] result in self?.consume(result) }
        camera.onFrame = { [engine] buffer in engine.ingest(buffer) }
        camera.onStatus = { [weak self] status in
            guard let self else { return }
            stage.overlay.status = status
            refreshHUD()
        }
        camera.onDevicesChanged = { [weak self] in
            self?.rebuildCameraMenu()
            self?.refreshHUD()
        }
        syphon.onServersChanged = { [weak self] in
            guard let self else { return }
            // Clear the request *before* trying it: useSyphon connects, which can call back
            // into here, and a still-set request would connect a second time.
            if let wanted = pendingFeed {
                pendingFeed = nil
                if !useSyphon(matching: wanted) { pendingFeed = wanted }
            }
            rebuildCameraMenu()
            refreshHUD()
        }
        syphon.onStatus = { [weak self] status in
            guard let self else { return }
            stage.overlay.status = status
            refreshHUD()
        }
        syphon.onFrame = { [engine] buffer in engine.ingest(buffer) }
        syphon.onSurface = { [weak self] surface in self?.stage.show(surface: surface) }
        // Source is decided before anything starts: `--camera iphone` opens on the iPhone
        // rather than opening on the built-in one and visibly switching, and `--syphon …`
        // never touches the webcam at all — no camera permission prompt, and the camera is
        // left free for whatever is producing the feed.
        let arguments = CommandLine.arguments
        let feedRequest = arguments.firstIndex(of: "--syphon").flatMap {
            $0 + 1 < arguments.count ? arguments[$0 + 1] : nil
        }
        stage.attach(session: camera.session, mirrored: mirrored)
        if let feedRequest, useSyphon(matching: feedRequest) {
            // Running on a Syphon feed; the camera stays untouched.
        } else if let feedRequest {
            // Give the directory a moment to hear about servers that are already publishing,
            // then fall back to the camera rather than sitting on an empty screen.
            pendingFeed = feedRequest
            stage.overlay.status = "Looking for Syphon feed \"\(feedRequest)\"…"
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, pendingFeed != nil else { return }
                pendingFeed = nil
                stage.overlay.status = nil
                camera.start()
            }
        } else {
            if let flag = arguments.firstIndex(of: "--camera"), flag + 1 < arguments.count {
                camera.preferDevice(matching: arguments[flag + 1])
            }
            camera.start()
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
        syncControls()
        NSApp.activate(ignoringOtherApps: true)
        applyLaunchArguments()
    }

    /// `open segcam.app --args --swarm --mode 3 --max-blobs 40` — handy for driving the app
    /// from a script without taking over the keyboard.
    private func applyLaunchArguments() {
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--mode"), flag + 1 < arguments.count,
           let raw = Int(arguments[flag + 1]), let mode = SegmentEngine.Mode(rawValue: raw) {
            setMode(mode)
        }
        if let flag = arguments.firstIndex(of: "--max-blobs"), flag + 1 < arguments.count,
           let count = Int(arguments[flag + 1]), count > 0 {
            swarm.maxBlobs = count
        }
        if arguments.contains("--swarm") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.setDisplay(.swarm)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        syphon.stop()
        camera.stop()
        swarm.clear()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    // MARK: - Frames

    private func consume(_ result: SegmentEngine.Result) {
        lastResult = result
        stage.overlay.aspect = result.aspect
        stage.overlay.segments = result.segments

        if display == .swarm {
            let screenFrame = (strip.screen ?? NSScreen.main ?? NSScreen.screens.first)?.frame ?? .zero
            swarm.update(segments: result.segments, crops: result.crops, screenFrame: screenFrame)
        }
        refreshHUD()
    }

    // MARK: - Display modes

    private func setDisplay(_ next: Display) {
        guard next != display else { return }
        display = next
        engine.wantsImage = (next == .swarm)

        switch next {
        case .overlay:
            swarm.clear()
            strip.orderOut(nil)
            window.makeKeyAndOrderFront(nil)
        case .swarm:
            swarm.mirrored = mirrored
            window.orderOut(nil)
            positionStrip()
            strip.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        refreshHUD()
    }

    private func buildStrip() {
        strip = StripWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 30),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        strip.isOpaque = false
        strip.backgroundColor = .clear
        strip.hasShadow = true
        strip.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        strip.hidesOnDeactivate = false
        strip.isMovableByWindowBackground = true
        strip.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        strip.contentView = stripHUD
    }

    private func positionStrip() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let size = NSSize(width: 620, height: 30)
        strip.setFrame(NSRect(x: screen.visibleFrame.midX - size.width / 2,
                              y: screen.visibleFrame.minY + 12,
                              width: size.width, height: size.height), display: true)
    }

    private func refreshHUD() {
        var parts: [String] = [engine.mode.title]
        switch engine.mode {
        case .threshold:
            var detail = "level \(lastResult.thresholdLevel)"
            if settings.autoThreshold { detail += " auto" }
            if settings.invertThreshold { detail += " inv" }
            parts.append(detail)
        case .motion:
            parts.append("sens \(Int((settings.motionSensitivityFraction * 100).rounded()))%")
        case .face:
            break
        }
        parts.append("\(lastResult.segments.count) seg")
        if display == .swarm { parts.append("\(swarm.panelCount) blobs") }
        parts.append(String(format: "%.0f fps", lastResult.fps))
        parts.append(sourceName)
        parts.append(display == .overlay ? "h → desktop" : "h → overlay · c clears")

        let text = parts.joined(separator: "  ·  ")
        stage.hud.text = text
        stripHUD.text = text
        window.title = "\(appName) — \(sourceName)"
    }

    // MARK: - Input

    private func handle(_ event: NSEvent) -> Bool {
        guard !event.modifierFlags.contains(.command) else { return false }

        if event.keyCode == 48 {                                   // tab
            setMode(engine.mode.next)
            return true
        }
        if event.keyCode == 53 {                                   // esc
            setDisplay(.overlay)
            return true
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "h": setDisplay(display == .overlay ? .swarm : .overlay)
        case "1": setMode(.face)
        case "2": setMode(.threshold)
        case "3": setMode(.motion)
        case "[": adjustPrimary(-5)
        case "]": adjustPrimary(+5)
        case "-": mutate { $0.minAreaFraction = max(0.0005, $0.minAreaFraction / 1.3) }
        case "=", "+": mutate { $0.minAreaFraction = min(0.2, $0.minAreaFraction * 1.3) }
        case "i": mutate { $0.invertThreshold.toggle() }
        case "a": mutate { $0.autoThreshold.toggle() }
        case "m":
            mirrored.toggle()
            stage.setMirrored(mirrored)
            swarm.mirrored = mirrored
        case "l":
            showLabels.toggle()
            stage.overlay.showLabels = showLabels
        case "c":
            swarm.clear()
        case "d":
            camera.cycleDevice()        // the HUD and menu refresh via onDevicesChanged
        default:
            return false
        }
        refreshHUD()
        return true
    }

    private func setMode(_ mode: SegmentEngine.Mode) {
        engine.mode = mode
        swarm.clear()                       // IDs restart, so the old windows are meaningless
        syncControls()
        refreshHUD()
    }

    /// Keeps both bars' sliders in step with the settings. Not called from `refreshHUD` —
    /// that runs every frame, and writing to a slider mid-drag fights the mouse.
    private func syncControls(except source: HUDView? = nil) {
        let showsSlider = engine.mode == .motion
        for hud in [stage.hud, stripHUD] {
            hud.showsSlider = showsSlider
            if hud !== source { hud.sliderValue = settings.motionSensitivityFraction }
        }
        refreshHUD()
    }

    /// `[` and `]` move whichever knob the active segmenter actually has.
    private func adjustPrimary(_ delta: Int) {
        switch engine.mode {
        case .threshold:
            mutate {
                $0.autoThreshold = false
                $0.thresholdLevel = min(254, max(1, $0.thresholdLevel + delta))
            }
        case .motion:
            // `]` means more sensitive, the same direction the slider moves.
            let step = delta > 0 ? 0.05 : -0.05
            mutate { $0.motionSensitivityFraction += step }
            syncControls()
        case .face:
            break
        }
    }

    private func mutate(_ change: (inout SegmentSettings) -> Void) {
        change(&settings)
        engine.settings = settings
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let cameraItem = NSMenuItem()
        let menu = NSMenu(title: "Camera")
        cameraItem.submenu = menu
        cameraMenu = menu
        main.addItem(cameraItem)

        NSApp.mainMenu = main
        rebuildCameraMenu()
    }

    /// The camera list is live — an iPhone appears when it wakes and vanishes when it walks
    /// away — so the menu is rebuilt whenever that changes rather than filled in once.
    private func rebuildCameraMenu() {
        guard let cameraMenu else { return }
        cameraMenu.removeAllItems()

        let devices = Camera.availableDevices()
        if devices.isEmpty {
            let empty = NSMenuItem(title: "No cameras found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            cameraMenu.addItem(empty)
        }
        var shortcut = 0
        for device in devices {
            shortcut += 1
            let item = NSMenuItem(title: device.localizedName,
                                  action: #selector(selectCamera(_:)),
                                  keyEquivalent: shortcut < 10 ? String(shortcut) : "")
            item.target = self
            item.representedObject = device.uniqueID
            item.state = (!syphon.isRunning && device.uniqueID == camera.currentDeviceID) ? .on : .off
            cameraMenu.addItem(item)
        }

        cameraMenu.addItem(.separator())
        let feeds = SyphonSource.servers()
        if feeds.isEmpty {
            let empty = NSMenuItem(title: "No Syphon feeds", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            cameraMenu.addItem(empty)
        }
        for feed in feeds {
            shortcut += 1
            let item = NSMenuItem(title: feed.displayName,
                                  action: #selector(selectSyphon(_:)),
                                  keyEquivalent: shortcut < 10 ? String(shortcut) : "")
            item.target = self
            item.representedObject = feed.uuid
            item.state = syphon.current == feed ? .on : .off
            cameraMenu.addItem(item)
        }

        cameraMenu.addItem(.separator())
        let next = NSMenuItem(title: "Next Camera", action: #selector(nextCamera), keyEquivalent: "d")
        next.target = self
        cameraMenu.addItem(next)
    }

    @objc private func selectCamera(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let device = Camera.availableDevices().first(where: { $0.uniqueID == id })
        else { return }
        useCamera(device)
    }

    @objc private func selectSyphon(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? String,
              let feed = SyphonSource.servers().first(where: { $0.uuid == uuid })
        else { return }
        useSyphon(feed)
    }

    private func useCamera(_ device: AVCaptureDevice) {
        syphon.stop()
        stage.setUsingSurface(false)
        camera.select(device)
        camera.start()          // no-op if the session is already running
        rebuildCameraMenu()
    }

    private func useSyphon(_ feed: SyphonServerInfo) {
        // Free the webcam while a Syphon feed is driving, so TouchDesigner (or anything else)
        // can have it.
        camera.stop()
        stage.setUsingSurface(true)
        // A Syphon feed is somebody else's image, not a selfie — mirroring it would be wrong.
        mirrored = false
        stage.setMirrored(false)
        swarm.mirrored = false
        syphon.connect(to: feed)
        rebuildCameraMenu()
    }

    @discardableResult
    private func useSyphon(matching text: String) -> Bool {
        let needle = text.lowercased()
        guard let feed = SyphonSource.servers().first(where: {
            $0.displayName.lowercased().contains(needle)
        }) else { return false }
        useSyphon(feed)
        return true
    }

    private var sourceName: String { syphon.isRunning ? syphon.sourceName : camera.deviceName }

    @objc private func nextCamera() {
        camera.cycleDevice()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
