import CoreGraphics
import Foundation

/// Segments the frame by luminance: everything brighter (or darker, inverted) than a
/// level becomes foreground, and each connected region is a tracked blob.
final class ThresholdSegmenter {
    private let numberer = InstanceNumberer()
    private(set) var lastLevel = 0

    func reset() { numberer.reset() }

    func segments(in frame: Frame, settings: SegmentSettings) -> [Segment] {
        let grid = frame.luma
        guard grid.count > 0 else { return [] }

        let level = settings.autoThreshold ? ThresholdSegmenter.otsu(grid.pixels) : settings.thresholdLevel
        lastLevel = level

        let cutoff = UInt8(min(255, max(0, level)))
        var mask = [UInt8](repeating: 0, count: grid.count)
        if settings.invertThreshold {
            for i in 0..<grid.count where grid.pixels[i] < cutoff { mask[i] = 1 }
        } else {
            for i in 0..<grid.count where grid.pixels[i] > cutoff { mask[i] = 1 }
        }

        let minPixels = max(4, Int(settings.minAreaFraction * CGFloat(grid.count)))
        let blobs = ConnectedComponents.label(mask: mask, width: grid.width, height: grid.height,
                                              minPixels: minPixels, maxCount: settings.maxSegments)
        return blobs.map { blob in
            Segment(id: SegmentID(kind: .blob, number: numberer.take()),
                    rect: blob.box,
                    score: Float(blob.pixels) / Float(grid.count))
        }
    }

    /// Otsu's method — picks the level that best splits the histogram into two classes.
    static func otsu(_ pixels: [UInt8]) -> Int {
        guard !pixels.isEmpty else { return 128 }
        var histogram = [Int](repeating: 0, count: 256)
        for p in pixels { histogram[Int(p)] += 1 }

        let total = pixels.count
        var sum = 0.0
        for i in 0..<256 { sum += Double(i * histogram[i]) }

        var sumB = 0.0, weightB = 0, best = 0.0, level = 128
        for i in 0..<256 {
            weightB += histogram[i]
            if weightB == 0 { continue }
            let weightF = total - weightB
            if weightF == 0 { break }
            sumB += Double(i * histogram[i])
            let meanB = sumB / Double(weightB)
            let meanF = (sum - sumB) / Double(weightF)
            let variance = Double(weightB) * Double(weightF) * (meanB - meanF) * (meanB - meanF)
            if variance > best {
                best = variance
                level = i
            }
        }
        return level
    }
}
