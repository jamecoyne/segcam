import AppKit
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Vision

// A throwaway main() over the real segmenter sources — the same trick pulse and
// system_probe use, so the maths is verifiable as text without a camera or a window.

setvbuf(stdout, nil, _IOLBF, 0)

var failures = 0

func check(_ condition: Bool, _ description: String) {
    print(condition ? "  PASS  \(description)" : "  FAIL  \(description)")
    if !condition { failures += 1 }
}

func header(_ title: String) {
    print("\n=== \(title) ===")
}

/// BGRA pixel buffer; `paint(x, y)` returns 0…255 grey for each pixel, row 0 at the top.
func makeBuffer(width: Int, height: Int, paint: (Int, Int) -> UInt8) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes: [String: Any] = [
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
    ]
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                        attributes as CFDictionary, &buffer)
    guard let pb = buffer else { fatalError("could not allocate a pixel buffer") }
    CVPixelBufferLockBaseAddress(pb, [])
    let stride = CVPixelBufferGetBytesPerRow(pb)
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<height {
        let row = base + y * stride
        for x in 0..<width {
            let value = paint(x, y)
            let p = row + x * 4
            p[0] = value; p[1] = value; p[2] = value; p[3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, [])
    return pb
}

func frame(_ pb: CVPixelBuffer, index: Int) -> Frame {
    Frame(pixelBuffer: pb,
          width: CVPixelBufferGetWidth(pb),
          height: CVPixelBufferGetHeight(pb),
          luma: LumaGrid.downsample(pb, targetWidth: 96),
          index: index)
}

func square(_ x: Int, _ y: Int, _ rect: (x: Int, y: Int, w: Int, h: Int)) -> Bool {
    x >= rect.x && x < rect.x + rect.w && y >= rect.y && y < rect.y + rect.h
}

/// Prints the segments as an ASCII map so the geometry is readable, not just numeric.
func asciiMap(_ segments: [Segment], cols: Int = 48, rows: Int = 14) {
    var grid = [[Character]](repeating: [Character](repeating: ".", count: cols), count: rows)
    for (i, segment) in segments.enumerated() {
        let mark: Character = String(i + 1).last ?? "#"
        let x0 = Int(segment.rect.x * CGFloat(cols)), x1 = Int((segment.rect.x + segment.rect.w) * CGFloat(cols)) - 1
        let y0 = Int(segment.rect.y * CGFloat(rows)), y1 = Int((segment.rect.y + segment.rect.h) * CGFloat(rows)) - 1
        for y in max(0, y0)...max(0, min(rows - 1, y1)) {
            for x in max(0, x0)...max(0, min(cols - 1, x1)) {
                let edge = y == max(0, y0) || y == min(rows - 1, y1) || x == max(0, x0) || x == min(cols - 1, x1)
                grid[y][x] = edge ? mark : grid[y][x]
            }
        }
    }
    for row in grid { print("  |" + String(row) + "|") }
}

func describe(_ segments: [Segment]) -> String {
    segments.map { s in
        String(format: "%@[%.2f %.2f %.2fx%.2f]", s.label, s.rect.x, s.rect.y, s.rect.w, s.rect.h)
    }.joined(separator: " ")
}

// MARK: - 1. Threshold: a square moving across a dark field

header("threshold — one square crossing the frame, 320x180 (every frame is a new instance)")
let thresholdSegmenter = ThresholdSegmenter()
var settings = SegmentSettings()
settings.thresholdLevel = 128
settings.minAreaFraction = 0.002

var thresholdIDs: [Int] = []
var firstRect = NormRect.zero
for step in 0..<10 {
    let box = (x: 20 + step * 20, y: 24, w: 60, h: 40)
    let pb = makeBuffer(width: 320, height: 180) { x, y in square(x, y, box) ? 240 : 25 }
    let segments = thresholdSegmenter.segments(in: frame(pb, index: step), settings: settings)
    thresholdIDs.append(contentsOf: segments.map(\.id.number))
    if step == 0 { firstRect = segments.first?.rect ?? .zero }
    if step % 3 == 0 {
        print("  frame \(step): \(describe(segments))")
        asciiMap(segments)
    }
    if step == 9 {
        check(segments.count == 1, "one blob at the end of the run (got \(segments.count))")
    }
}
// There is deliberately no tracking: a thing standing in front of the camera is a brand new
// blob on every frame, which is what makes the desktop collage accumulate.
check(thresholdIDs == Array(1...thresholdIDs.count),
      "every frame mints a fresh ID, none reused (saw \(thresholdIDs.first ?? 0)…\(thresholdIDs.last ?? 0))")
check(Set(thresholdIDs).count == thresholdIDs.count, "no ID appears twice across the run")
check(firstRect.y < 0.3, "square painted at rows 24…64 lands near the TOP: y=\(String(format: "%.2f", firstRect.y))")
check(firstRect.x < 0.3, "square painted at cols 20…80 lands on the LEFT: x=\(String(format: "%.2f", firstRect.x))")
check(abs(firstRect.h - 40.0 / 180.0) < 0.05, "height is about 40/180: \(String(format: "%.2f", firstRect.h))")

// MARK: - 2. Two blobs: distinct IDs, merge, split

header("threshold — two squares merge and split")
let mergeSegmenter = ThresholdSegmenter()
var seenPerFrame: [Int] = []
var idsBeforeMerge: [Int] = []
for step in 0..<9 {
    let gap = max(0, 70 - step * 18)
    let a = (x: 40, y: 40, w: 50, h: 50)
    let b = (x: 40 + 50 + gap, y: 40, w: 50, h: 50)
    let pb = makeBuffer(width: 320, height: 180) { x, y in
        (square(x, y, a) || square(x, y, b)) ? 240 : 25
    }
    let segments = mergeSegmenter.segments(in: frame(pb, index: step), settings: settings)
    seenPerFrame.append(segments.count)
    if step == 0 { idsBeforeMerge = segments.map(\.id.number).sorted() }
    print("  gap \(String(format: "%3d", gap)): \(segments.count) → \(describe(segments))")
}
check(idsBeforeMerge == [1, 2], "two separated squares get two IDs in one frame (got \(idsBeforeMerge))")
check(seenPerFrame.contains(1), "they merge into a single blob when they touch")

// MARK: - 3. Motion

header("motion — still scene, then a moving square, then stillness again")
let motionSegmenter = MotionSegmenter()
var motionSettings = SegmentSettings()
motionSettings.motionSensitivity = 18
motionSettings.minAreaFraction = 0.002

var stillCount = -1
var movingIDs = Set<Int>()
for step in 0..<70 {
    let moving = step >= 6 && step < 16
    let x = moving ? 30 + (step - 6) * 22 : 30
    let box = (x: x, y: 60, w: 55, h: 55)
    let show = step >= 6
    let pb = makeBuffer(width: 320, height: 180) { px, py in
        (show && square(px, py, box)) ? 235 : 30
    }
    let segments = motionSegmenter.segments(in: frame(pb, index: step), settings: motionSettings)
    if step == 5 { stillCount = segments.count }
    if moving { segments.forEach { movingIDs.insert($0.id.number) } }
    if [5, 8, 12, 20, 40, 69].contains(step) {
        print("  frame \(String(format: "%2d", step)) \(moving ? "moving" : "still "): \(segments.count) → \(describe(segments))")
        if !segments.isEmpty { asciiMap(segments) }
    }
    if step == 69 {
        // A background model that adapts at 0.06/frame takes about a second and a half to
        // swallow a stopped object — that lag is the feature, not a bug.
        check(segments.isEmpty, "a motionless object is eventually absorbed (got \(segments.count))")
    }
}
check(stillCount == 0, "nothing moves, nothing is segmented (got \(stillCount))")
check(movingIDs.count > 5, "the moving square is segmented, with a new ID per frame (\(movingIDs.count) instances)")

// MARK: - 4. Otsu

header("threshold — Otsu auto level")
var histogramPixels = [UInt8](repeating: 40, count: 5000)
histogramPixels.append(contentsOf: [UInt8](repeating: 200, count: 5000))
let level = ThresholdSegmenter.otsu(histogramPixels)
print("  bimodal 40/200 → level \(level)")
check(level >= 40 && level < 200, "Otsu splits the two modes (any level in [40,200) separates them)")

// MARK: - 4b. Motion sensitivity mapping (what the slider drives)

header("motion — sensitivity slider mapping")
var knob = SegmentSettings()
knob.motionSensitivityFraction = 1.0
let mostSensitive = knob.motionSensitivity
knob.motionSensitivityFraction = 0.0
let leastSensitive = knob.motionSensitivity
knob.motionSensitivityFraction = 0.5
print("  1.0 -> threshold \(mostSensitive), 0.0 -> \(leastSensitive), 0.5 -> \(knob.motionSensitivity)")
check(mostSensitive < leastSensitive,
      "sliding right lowers the difference threshold, i.e. more sensitive")
check(mostSensitive == SegmentSettings.motionThresholdRange.lowerBound
        && leastSensitive == SegmentSettings.motionThresholdRange.upperBound,
      "the ends of the slider are the ends of the range")
knob.motionSensitivity = 60
check(abs(knob.motionSensitivityFraction - (1 - 58.0 / 118.0)) < 0.01,
      "reading back a threshold gives the matching slider position")

// MARK: - 5. Swarm crop orientation (the contract mode 2 depends on)

header("swarm — CGImage crop orientation")
let quadrant = makeBuffer(width: 320, height: 180) { x, y in (x < 160 && y < 90) ? 250 : 20 }
let ciContext = CIContext(options: [.cacheIntermediates: false])
let ci = CIImage(cvPixelBuffer: quadrant)
let full = ciContext.createCGImage(ci, from: ci.extent)!

func meanBrightness(_ image: CGImage) -> Double {
    let w = 8, h = 8
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    let space = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    var total = 0.0
    for i in stride(from: 0, to: bytes.count, by: 4) {
        total += (Double(bytes[i]) + Double(bytes[i + 1]) + Double(bytes[i + 2])) / 3
    }
    return total / Double(w * h)
}

let topLeft = NormRect(x: 0, y: 0, w: 0.5, h: 0.5)
let bottomRight = NormRect(x: 0.5, y: 0.5, w: 0.5, h: 0.5)
let topLeftCrop = full.cropping(to: FrameMap.pixelRect(topLeft, width: full.width, height: full.height))!
let bottomRightCrop = full.cropping(to: FrameMap.pixelRect(bottomRight, width: full.width, height: full.height))!
print(String(format: "  top-left crop mean %.0f, bottom-right crop mean %.0f",
             meanBrightness(topLeftCrop), meanBrightness(bottomRightCrop)))
check(meanBrightness(topLeftCrop) > 200, "NormRect(0,0) crops the painted TOP-LEFT quadrant")
check(meanBrightness(bottomRightCrop) < 60, "NormRect(0.5,0.5) crops the dark bottom-right quadrant")

// MARK: - 6. Screen mapping

header("swarm — normalized rect to screen rect")
let screenFrame = CGRect(x: 0, y: 0, width: 1600, height: 1000)
let mapped = FrameMap.spread(NormRect(x: 0, y: 0, w: 0.25, h: 0.5), across: screenFrame, mirrored: false)
let mirroredMap = FrameMap.spread(NormRect(x: 0, y: 0, w: 0.25, h: 0.5), across: screenFrame, mirrored: true)
print("  unmirrored \(mapped)  mirrored \(mirroredMap)")
check(mapped.minX == 0 && mapped.maxY == 1000, "top-left of the frame maps to the top-left of the screen")
check(mirroredMap.minX == 1200 && mirroredMap.maxY == 1000, "mirroring moves it to the top-right")

// MARK: - 7. Optional: the Vision path against a still image

let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--image"), flag + 1 < arguments.count {
    let path = arguments[flag + 1]
    header("eyes + mouth — \(path)")
    if let image = NSImage(contentsOfFile: path),
       let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        let faceRequest = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up)
        try? handler.perform([faceRequest])
        let segmenter = FaceSegmenter()
        let segments = segmenter.build(faces: faceRequest.results ?? [],
                                       imageSize: CGSize(width: cg.width, height: cg.height))
        print("  \(cg.width)x\(cg.height) → \(segments.count) segments")
        for segment in segments.sorted(by: { $0.label < $1.label }) {
            print(String(format: "    %-10s x %.3f  y %.3f  w %.3f  h %.3f  score %.2f",
                         (segment.label as NSString).utf8String!, segment.rect.x, segment.rect.y,
                         segment.rect.w, segment.rect.h, segment.score))
        }
        asciiMap(segments)
        check(!segments.isEmpty, "found something in the image")
    } else {
        print("  could not read \(path)")
        failures += 1
    }
}

print("\n\(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")")
exit(failures == 0 ? 0 : 1)
