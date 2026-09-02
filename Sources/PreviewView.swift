import AppKit
import AVFoundation
import IOSurface

/// One line of status text on a dark bar, with a slider for the active segmenter's knob.
/// Used at the bottom of the overlay and as the whole content of the control strip in swarm
/// mode — the strip is the only UI in swarm mode, so the slider has to live in both.
final class HUDView: NSView {
    var text: String = "" { didSet { needsDisplay = true } }
    var drawsBackground = true

    /// Called with 0…1 as the slider moves.
    var onSlider: ((Double) -> Void)?

    private let slider = NSSlider(value: 0.5, minValue: 0, maxValue: 1,
                                  target: nil, action: nil)

    /// The slider is only shown for segmenters that have something to tune.
    var showsSlider = false {
        didSet {
            slider.isHidden = !showsSlider
            needsLayout = true
            needsDisplay = true
        }
    }

    /// Set from outside when the value changes by key, so the two stay in step.
    var sliderValue: Double {
        get { slider.doubleValue }
        set { if !slider.isHidden { slider.doubleValue = newValue } }
    }

    override var isFlipped: Bool { true }

    static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        slider.controlSize = .small
        slider.isContinuous = true
        slider.isHidden = true
        slider.target = self
        slider.action = #selector(sliderMoved)
        addSubview(slider)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func sliderMoved() {
        onSlider?(slider.doubleValue)
    }

    override func layout() {
        super.layout()
        let width: CGFloat = 130
        slider.frame = NSRect(x: bounds.maxX - width - 10,
                              y: (bounds.height - 18) / 2,
                              width: width, height: 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        if drawsBackground {
            NSColor(calibratedWhite: 0.05, alpha: 0.85).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 0), xRadius: 6, yRadius: 6).fill()
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: HUDView.font,
            .foregroundColor: NSColor(calibratedRed: 0.3, green: 1, blue: 0.45, alpha: 1),
        ]
        // Leave room for the slider so a long status line never runs underneath it.
        let limit = showsSlider ? bounds.width - 150 : bounds.width - 20
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        string.draw(with: NSRect(x: 10, y: (bounds.height - size.height) / 2,
                                 width: max(20, limit), height: size.height),
                    options: [.usesLineFragmentOrigin])
    }
}

/// Mode 1: green rectangles and labels over the live video.
final class OverlayView: NSView {
    var segments: [Segment] = [] { didSet { needsDisplay = true } }
    var aspect: CGFloat = 16.0 / 9.0
    var mirrored = true
    var showLabels = true { didSet { needsDisplay = true } }
    var status: String? { didSet { needsDisplay = true } }

    private static let green = NSColor(calibratedRed: 0.25, green: 1, blue: 0.4, alpha: 1)

    override var isFlipped: Bool { true }      // top-left origin, same as NormRect

    override func draw(_ dirtyRect: NSRect) {
        if let status {
            drawCentered(status)
            return
        }

        OverlayView.green.setStroke()
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.black,
        ]

        for segment in segments {
            let rect = FrameMap.fit(segment.rect, into: bounds, aspect: aspect, mirrored: mirrored)
            guard rect.width > 1, rect.height > 1 else { continue }
            let path = NSBezierPath(rect: rect.insetBy(dx: -1, dy: -1))
            path.lineWidth = 2
            path.stroke()

            guard showLabels else { continue }
            let string = NSAttributedString(string: segment.label, attributes: labelAttributes)
            let size = string.size()
            var chip = NSRect(x: rect.minX - 1, y: rect.minY - size.height - 3,
                              width: size.width + 8, height: size.height + 2)
            if chip.minY < 0 { chip.origin.y = rect.minY + 1 }      // box is at the top edge
            OverlayView.green.setFill()
            NSBezierPath(roundedRect: chip, xRadius: 2, yRadius: 2).fill()
            string.draw(at: NSPoint(x: chip.minX + 4, y: chip.minY + 1))
            OverlayView.green.setStroke()
        }
    }

    private func drawCentered(_ message: String) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let string = NSAttributedString(string: message, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor(calibratedRed: 0.3, green: 1, blue: 0.45, alpha: 1),
            .paragraphStyle: paragraph,
        ])
        let size = string.boundingRect(with: NSSize(width: bounds.width - 40, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin])
        string.draw(with: NSRect(x: 20, y: bounds.midY - size.height / 2, width: bounds.width - 40, height: size.height),
                    options: [.usesLineFragmentOrigin])
    }
}

/// The live video plus its overlay and HUD bar — the whole of mode 1.
final class CameraStage: NSView {
    let overlay = OverlayView()
    let hud = HUDView()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    /// A Syphon feed has no capture session to hang a preview layer off, but it does hand us
    /// the shared IOSurface — which CoreAnimation can display directly.
    private let surfaceLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        surfaceLayer.contentsGravity = .resizeAspect      // matches the preview layer's letterbox
        surfaceLayer.isHidden = true
        layer?.addSublayer(surfaceLayer)
        addSubview(overlay)
        addSubview(hud)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func attach(session: AVCaptureSession, mirrored: Bool) {
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspect
        preview.frame = bounds
        layer?.insertSublayer(preview, at: 0)
        previewLayer = preview
        setMirrored(mirrored)
    }

    func setMirrored(_ mirrored: Bool) {
        overlay.mirrored = mirrored
        guard let connection = previewLayer?.connection else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        if connection.isVideoMirroringSupported { connection.isVideoMirrored = mirrored }
    }

    /// True when frames come from Syphon rather than a camera.
    func setUsingSurface(_ usingSurface: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer?.isHidden = usingSurface
        surfaceLayer.isHidden = !usingSurface
        if !usingSurface { surfaceLayer.contents = nil }
        CATransaction.commit()
    }

    func show(surface: IOSurfaceRef) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surfaceLayer.contents = surface
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surfaceLayer.frame = bounds
        previewLayer?.frame = bounds
        CATransaction.commit()
        overlay.frame = bounds
        hud.frame = NSRect(x: 12, y: 10, width: max(0, bounds.width - 24), height: 26)
    }
}
