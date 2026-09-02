import AppKit
import QuartzCore

/// One detected segment, living as its own titled macOS window and showing the single frame
/// it was cut from. Panels are recycled rather than closed and recreated — at 30 frames a
/// second of brand-new instances, churning real windows that fast is far more expensive than
/// re-dressing one that already exists.
final class SegmentPanel: NSPanel {
    private let imageLayer = CALayer()
    private let borderLayer = CALayer()
    private static let green = NSColor(calibratedRed: 0.25, green: 1, blue: 0.4, alpha: 1)

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 160, height: 120),
                   styleMask: [.titled, .closable, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        // Above the Dock and the menu bar: the canvas is the *whole* screen, not the part
        // system UI leaves over. Still non-activating and click-through, so nothing traps
        // the user behind them.
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) - 1)
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 120))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        content.layer?.masksToBounds = true
        contentView = content

        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .linear
        borderLayer.borderWidth = 2
        borderLayer.borderColor = SegmentPanel.green.cgColor
        borderLayer.backgroundColor = NSColor.clear.cgColor
        content.layer?.addSublayer(imageLayer)
        content.layer?.addSublayer(borderLayer)
    }

    /// Become a different blob: new title, new snapshot, new place on screen. `rect` is where
    /// the *video* belongs, so the title bar sits above it and the crop lands exactly where
    /// the segment was in the frame.
    func adopt(title: String, image: CGImage?, contentRect rect: CGRect, mirrored: Bool) {
        self.title = title
        setFrame(frameRect(forContentRect: rect), display: false)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = CGRect(origin: .zero, size: contentView?.bounds.size ?? rect.size)
        imageLayer.frame = bounds
        borderLayer.frame = bounds
        imageLayer.transform = mirrored ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity
        imageLayer.contents = image
        CATransaction.commit()

        orderFrontRegardless()      // the newest blob lands on top of the pile
    }
}

/// Mode 2: the desktop is the camera frame. Every detection, on every frame, becomes its own
/// window holding that frame — so the desktop piles up with everything the camera has seen,
/// oldest recycled away once the pile is full.
final class SegmentSwarm {
    private var panels: [SegmentPanel] = []     // oldest first
    /// Instances already given a window. Segments can be republished across frames (Vision
    /// runs at half rate and its results are reused), and a repeat is the same instance, not
    /// a new one.
    private var spawned: Set<SegmentID> = []

    var mirrored = true
    /// How many windows the collage holds before the oldest is recycled.
    var maxBlobs = 100

    private let minWidth: CGFloat = 120     // a titled window can't be narrower than its bar
    private let minHeight: CGFloat = 28

    var panelCount: Int { panels.count }

    func update(segments: [Segment], crops: [SegmentID: CGImage], screenFrame: CGRect) {
        for segment in segments where !spawned.contains(segment.id) {
            spawned.insert(segment.id)
            if spawned.count > 8192 { spawned = [segment.id] }

            var rect = FrameMap.spread(segment.rect, across: screenFrame, mirrored: mirrored)
            if rect.width < minWidth {
                rect.origin.x -= (minWidth - rect.width) / 2
                rect.size.width = minWidth
            }
            if rect.height < minHeight {
                rect.origin.y -= (minHeight - rect.height) / 2
                rect.size.height = minHeight
            }

            let panel = panels.count >= maxBlobs ? panels.removeFirst() : SegmentPanel()
            panel.adopt(title: segment.label, image: crops[segment.id],
                        contentRect: rect, mirrored: mirrored)
            panels.append(panel)
        }
    }

    func clear() {
        for panel in panels {
            panel.orderOut(nil)
            panel.close()
        }
        panels.removeAll()
        spawned.removeAll()
    }
}
