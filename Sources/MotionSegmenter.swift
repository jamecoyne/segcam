import CoreGraphics
import Foundation

/// Segments things that are moving: a slowly adapting background model, a difference
/// threshold, then morphology to turn a spray of changed cells into solid objects.
final class MotionSegmenter {
    private var background: [Float] = []
    private var gridWidth = 0
    private var gridHeight = 0
    private let numberer = InstanceNumberer()

    func reset() {
        background.removeAll()
        gridWidth = 0
        gridHeight = 0
        numberer.reset()
    }

    func segments(in frame: Frame, settings: SegmentSettings) -> [Segment] {
        let grid = frame.luma
        guard grid.count > 0 else { return [] }

        if gridWidth != grid.width || gridHeight != grid.height || background.count != grid.count {
            gridWidth = grid.width
            gridHeight = grid.height
            background = grid.pixels.map(Float.init)
            return []                                   // first frame is only a reference
        }

        let tau = Float(max(1, settings.motionSensitivity))
        let alpha = max(0.001, min(0.5, settings.motionAdaptation))
        var mask = [UInt8](repeating: 0, count: grid.count)
        for i in 0..<grid.count {
            let value = Float(grid.pixels[i])
            if abs(value - background[i]) > tau { mask[i] = 1 }
            background[i] += (value - background[i]) * alpha
        }

        // One erode kills sensor speckle, two dilates glue an object back together
        // (a moving arm shows up as changed *edges*, not a filled shape).
        mask = ConnectedComponents.erode(mask, width: grid.width, height: grid.height)
        mask = ConnectedComponents.dilate(mask, width: grid.width, height: grid.height)
        mask = ConnectedComponents.dilate(mask, width: grid.width, height: grid.height)

        let minPixels = max(4, Int(settings.minAreaFraction * CGFloat(grid.count)))
        let blobs = ConnectedComponents.label(mask: mask, width: grid.width, height: grid.height,
                                              minPixels: minPixels, maxCount: settings.maxSegments)
        return blobs.map { blob in
            Segment(id: SegmentID(kind: .motion, number: numberer.take()),
                    rect: blob.box,
                    score: Float(blob.pixels) / Float(grid.count))
        }
    }
}
