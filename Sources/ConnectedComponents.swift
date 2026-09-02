import CoreGraphics

/// One labelled region of a binary mask.
struct Blob {
    var box: NormRect
    var pixels: Int
}

/// 8-connected component labelling over a small binary grid. Shared by the threshold
/// and motion segmenters so there is exactly one labeller to get right — and one to test.
enum ConnectedComponents {
    /// `mask` is 1 for foreground, 0 for background. Returns the largest components,
    /// biggest first, as normalized boxes (top-left origin, y down).
    static func label(mask: [UInt8], width: Int, height: Int, minPixels: Int, maxCount: Int) -> [Blob] {
        guard width > 0, height > 0, mask.count >= width * height else { return [] }

        var visited = [Bool](repeating: false, count: width * height)
        var blobs: [Blob] = []
        var stack: [Int] = []
        stack.reserveCapacity(width * height / 4)

        for start in 0..<(width * height) where mask[start] != 0 && !visited[start] {
            visited[start] = true
            stack.removeAll(keepingCapacity: true)
            stack.append(start)

            var minX = width, maxX = 0, minY = height, maxY = 0, count = 0

            while let index = stack.popLast() {
                let x = index % width
                let y = index / width
                count += 1
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }

                for dy in -1...1 {
                    let ny = y + dy
                    if ny < 0 || ny >= height { continue }
                    for dx in -1...1 {
                        let nx = x + dx
                        if nx < 0 || nx >= width || (dx == 0 && dy == 0) { continue }
                        let n = ny * width + nx
                        if mask[n] != 0 && !visited[n] {
                            visited[n] = true
                            stack.append(n)
                        }
                    }
                }
            }

            guard count >= minPixels else { continue }
            // Cell edges, not centres: a one-cell blob still has real extent.
            let box = NormRect(x: CGFloat(minX) / CGFloat(width),
                               y: CGFloat(minY) / CGFloat(height),
                               w: CGFloat(maxX - minX + 1) / CGFloat(width),
                               h: CGFloat(maxY - minY + 1) / CGFloat(height))
            blobs.append(Blob(box: box, pixels: count))
        }

        blobs.sort { $0.pixels > $1.pixels }
        if blobs.count > maxCount { blobs.removeLast(blobs.count - maxCount) }
        return blobs
    }

    /// 3x3 erode — removes isolated speckle before labelling.
    static func erode(_ mask: [UInt8], width: Int, height: Int) -> [UInt8] {
        morph(mask, width: width, height: height, keepIf: { $0 == 9 })
    }

    /// 3x3 dilate — glues the fragments of one moving thing back together.
    static func dilate(_ mask: [UInt8], width: Int, height: Int) -> [UInt8] {
        morph(mask, width: width, height: height, keepIf: { $0 > 0 })
    }

    private static func morph(_ mask: [UInt8], width: Int, height: Int, keepIf: (Int) -> Bool) -> [UInt8] {
        guard width > 0, height > 0 else { return mask }
        var out = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                var hits = 0
                for dy in -1...1 {
                    let ny = min(height - 1, max(0, y + dy))
                    for dx in -1...1 {
                        let nx = min(width - 1, max(0, x + dx))
                        if mask[ny * width + nx] != 0 { hits += 1 }
                    }
                }
                out[y * width + x] = keepIf(hits) ? 1 : 0
            }
        }
        return out
    }
}
