import AppKit
import CoreGraphics
import CoreVideo

/// A rectangle in normalized frame space: origin top-left, y down, un-mirrored.
///
/// Every segmenter emits these and both display modes consume them. Mirroring is a
/// display concern applied by `FrameMap`, never inside a segmenter, and Vision's
/// bottom-left rects are flipped exactly once, in `fromVision`.
struct NormRect: Equatable {
    var x: CGFloat
    var y: CGFloat
    var w: CGFloat
    var h: CGFloat

    static let zero = NormRect(x: 0, y: 0, w: 0, h: 0)

    var midX: CGFloat { x + w / 2 }
    var midY: CGFloat { y + h / 2 }
    var area: CGFloat { max(0, w) * max(0, h) }
    var isEmpty: Bool { w <= 0 || h <= 0 }

    /// The one and only bottom-left → top-left conversion.
    static func fromVision(_ r: CGRect) -> NormRect {
        NormRect(x: r.minX, y: 1 - r.maxY, w: r.width, h: r.height)
    }

    static func bounding(_ points: [CGPoint]) -> NormRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return NormRect(x: minX, y: minY, w: maxX - minX, h: maxY - minY)
    }

    func padded(by fraction: CGFloat) -> NormRect {
        let dx = w * fraction, dy = h * fraction
        return NormRect(x: x - dx, y: y - dy, w: w + 2 * dx, h: h + 2 * dy).clamped()
    }

    /// Grows the box to at least `size` on each axis, keeping the centre put.
    func atLeast(_ size: CGFloat) -> NormRect {
        var r = self
        if r.w < size { r.x -= (size - r.w) / 2; r.w = size }
        if r.h < size { r.y -= (size - r.h) / 2; r.h = size }
        return r.clamped()
    }

    func clamped() -> NormRect {
        let x0 = min(max(0, x), 1), y0 = min(max(0, y), 1)
        let x1 = min(max(0, x + w), 1), y1 = min(max(0, y + h), 1)
        return NormRect(x: x0, y: y0, w: max(0, x1 - x0), h: max(0, y1 - y0))
    }
}

/// 8-bit luminance downsample of a frame, built once and shared by the blob segmenters.
struct LumaGrid {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    var count: Int { width * height }

    /// Box-averages a BGRA pixel buffer down to `targetWidth` columns, preserving aspect.
    static func downsample(_ pb: CVPixelBuffer, targetWidth: Int = 192) -> LumaGrid {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }

        let srcW = CVPixelBufferGetWidth(pb)
        let srcH = CVPixelBufferGetHeight(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb), srcW > 0, srcH > 0 else {
            return LumaGrid(width: 0, height: 0, pixels: [])
        }
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let src = base.assumingMemoryBound(to: UInt8.self)

        // BGRA -> Rec.601 luma, integer only.
        @inline(__always) func luma(_ p: UnsafeMutablePointer<UInt8>) -> Int {
            (29 * Int(p[0]) + 150 * Int(p[1]) + 77 * Int(p[2])) >> 8
        }

        let gw = min(targetWidth, srcW)
        let gh = max(1, Int((Double(gw) * Double(srcH) / Double(srcW)).rounded()))
        var out = [UInt8](repeating: 0, count: gw * gh)

        // Two samples per axis per cell: enough to reject sensor noise, cheap enough to
        // stay in the microseconds at 192x108.
        for gy in 0..<gh {
            let y0 = gy * srcH / gh
            let y1 = max(y0 + 1, (gy + 1) * srcH / gh)
            let ya = y0, yb = min(srcH - 1, (y0 + y1) / 2)
            for gx in 0..<gw {
                let x0 = gx * srcW / gw
                let x1 = max(x0 + 1, (gx + 1) * srcW / gw)
                let xa = x0, xb = min(srcW - 1, (x0 + x1) / 2)
                let rowA = src + ya * stride
                let rowB = src + yb * stride
                var acc = 0
                acc += luma(rowA + xa * 4)
                acc += luma(rowA + xb * 4)
                acc += luma(rowB + xa * 4)
                acc += luma(rowB + xb * 4)
                out[gy * gw + gx] = UInt8(min(255, acc >> 2))
            }
        }
        return LumaGrid(width: gw, height: gh, pixels: out)
    }
}

/// One captured frame plus everything derived from it that more than one consumer needs.
struct Frame {
    let pixelBuffer: CVPixelBuffer?
    let width: Int
    let height: Int
    let luma: LumaGrid
    let index: Int

    var aspect: CGFloat { height > 0 ? CGFloat(width) / CGFloat(height) : 16.0 / 9.0 }
}

/// Normalized frame space → screen space. Both display modes go through here.
enum FrameMap {
    /// The letterboxed rect the video occupies inside `bounds` (aspect-fit, centred) —
    /// matches `AVLayerVideoGravity.resizeAspect`, which is what the preview layer uses.
    static func contentRect(in bounds: CGRect, aspect: CGFloat) -> CGRect {
        guard bounds.width > 0, bounds.height > 0, aspect > 0 else { return bounds }
        var size = CGSize(width: bounds.width, height: bounds.width / aspect)
        if size.height > bounds.height {
            size = CGSize(width: bounds.height * aspect, height: bounds.height)
        }
        return CGRect(x: bounds.midX - size.width / 2,
                      y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// Mode 1: map into an aspect-fitted video rect. Expects a *flipped* view
    /// (top-left origin), so y needs no inversion.
    static func fit(_ r: NormRect, into bounds: CGRect, aspect: CGFloat, mirrored: Bool) -> CGRect {
        let c = contentRect(in: bounds, aspect: aspect)
        let x = mirrored ? 1 - r.x - r.w : r.x
        return CGRect(x: c.minX + x * c.width,
                      y: c.minY + r.y * c.height,
                      width: r.w * c.width,
                      height: r.h * c.height)
    }

    /// Mode 2: stretch the whole frame across one screen, in AppKit's bottom-left
    /// global coordinates.
    static func spread(_ r: NormRect, across screenFrame: CGRect, mirrored: Bool) -> CGRect {
        let x = mirrored ? 1 - r.x - r.w : r.x
        return CGRect(x: screenFrame.minX + x * screenFrame.width,
                      y: screenFrame.maxY - (r.y + r.h) * screenFrame.height,
                      width: r.w * screenFrame.width,
                      height: r.h * screenFrame.height)
    }

    /// Mode 2: the pixel rect to crop out of the full-frame image for a segment.
    /// Always source space — the frame image is un-mirrored, so a mirrored display
    /// flips the *crop* (a layer transform) rather than moving where it is taken from.
    static func pixelRect(_ r: NormRect, width: Int, height: Int) -> CGRect {
        let px = (r.x * CGFloat(width)).rounded(.down)
        let py = (r.y * CGFloat(height)).rounded(.down)
        let pw = max(1, (r.w * CGFloat(width)).rounded())
        let ph = max(1, (r.h * CGFloat(height)).rounded())
        return CGRect(x: px, y: py, width: pw, height: ph)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
    }
}
