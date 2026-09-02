import CoreGraphics
import CoreVideo
import Foundation
import QuartzCore

/// Owns the three segmenters, decides which one runs, and publishes one result per
/// frame to the main queue. Everything here runs on the capture queue except the
/// setters, which are main-thread and lock-protected.
final class SegmentEngine {
    enum Mode: Int, CaseIterable {
        case face = 1, threshold, motion

        var title: String {
            switch self {
            case .face:      return "eyes + mouth"
            case .threshold: return "threshold"
            case .motion:    return "motion"
            }
        }
        var next: Mode { Mode(rawValue: rawValue % Mode.allCases.count + 1) ?? .face }
    }

    struct Result {
        var segments: [Segment] = []
        /// One tight little image per segment, for the swarm's windows.
        var crops: [SegmentID: CGImage] = [:]
        var width = 0
        var height = 0
        var aspect: CGFloat = 16.0 / 9.0
        var thresholdLevel = 0
        var fps: Double = 0
    }

    /// Delivered on the main queue.
    var onResult: ((Result) -> Void)?

    private let face = FaceSegmenter()
    private let threshold = ThresholdSegmenter()
    private let motion = MotionSegmenter()

    private let lock = NSLock()
    private var _settings = SegmentSettings()
    private var _mode = Mode.face
    private var _wantsImage = false
    private var appliedMode = Mode.face
    private var frameIndex = 0
    /// Vision is the single most expensive thing here and a face does not move far in
    /// 33 ms, so it runs every other frame and the tracked boxes are reused in between.
    /// Vision is the most expensive thing here, so it runs every other frame; the swarm
    /// treats a republished instance as the one it already has a window for.
    private let visionStride = 2
    /// Matches the swarm's window cap — no point cropping for a window that won't exist.
    private static let maxCrops = 24
    private var lastFaceSegments: [Segment] = []
    private var lastFrameTime: CFTimeInterval = 0
    private var smoothedFPS: Double = 0

    var settings: SegmentSettings {
        get { lock.withLock { _settings } }
        set { lock.withLock { _settings = newValue } }
    }

    var mode: Mode {
        get { lock.withLock { _mode } }
        set { lock.withLock { _mode = newValue } }
    }

    /// Mode 2 needs per-segment crops; mode 1 doesn't.
    var wantsImage: Bool {
        get { lock.withLock { _wantsImage } }
        set { lock.withLock { _wantsImage = newValue } }
    }

    /// Cuts one small standalone image per segment straight out of the capture buffer.
    ///
    /// The obvious version — render the whole frame once and hand each window a
    /// `cropping(to:)` view — measured far worse: a cropped CGImage still references the
    /// full 3.5 MB backing, so CoreAnimation re-prepared the entire frame for every window
    /// on every commit (`CA::Render::prepare_image` was the single hottest frame in the
    /// profile). Copying just the crop's own rows costs a few KB per eye instead.
    ///
    /// `noneSkipFirst` ignores the camera's alpha channel, which is not opaque — without it
    /// the windows look like ghosts of the desktop rather than video.
    private static func makeCrops(_ pb: CVPixelBuffer, segments: [Segment],
                                  width: Int, height: Int) -> [SegmentID: CGImage] {
        guard !segments.isEmpty else { return [:] }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return [:] }
        let src = base.assumingMemoryBound(to: UInt8.self)
        let srcStride = CVPixelBufferGetBytesPerRow(pb)
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue)
        let space = CGColorSpaceCreateDeviceRGB()

        var crops: [SegmentID: CGImage] = [:]
        for segment in segments.sorted(by: { $0.rect.area > $1.rect.area }).prefix(SegmentEngine.maxCrops) {
            let rect = FrameMap.pixelRect(segment.rect, width: width, height: height)
            let x = Int(rect.minX), y = Int(rect.minY)
            let w = Int(rect.width), h = Int(rect.height)
            guard w > 0, h > 0, x >= 0, y >= 0, x + w <= width, y + h <= height else { continue }

            let dstStride = w * 4
            var bytes = [UInt8](repeating: 0, count: dstStride * h)
            bytes.withUnsafeMutableBytes { dst in
                guard let out = dst.baseAddress else { return }
                for row in 0..<h {
                    memcpy(out.advanced(by: row * dstStride),
                           src + (y + row) * srcStride + x * 4,
                           dstStride)
                }
            }
            guard let provider = CGDataProvider(data: Data(bytes) as CFData),
                  let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                      bytesPerRow: dstStride, space: space, bitmapInfo: bitmapInfo,
                                      provider: provider, decode: nil, shouldInterpolate: false,
                                      intent: .defaultIntent)
            else { continue }
            crops[segment.id] = image
        }
        return crops
    }

    /// Capture queue.
    func ingest(_ pixelBuffer: CVPixelBuffer) {
        let (settings, mode, wantsImage) = lock.withLock { (_settings, _mode, _wantsImage) }

        if mode != appliedMode {
            appliedMode = mode
            face.reset()
            threshold.reset()
            motion.reset()
        }

        frameIndex += 1
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // The luma grid is only worth building for the blob segmenters.
        let luma = mode == .face ? LumaGrid(width: 0, height: 0, pixels: [])
                                     : LumaGrid.downsample(pixelBuffer)
        let frame = Frame(pixelBuffer: pixelBuffer, width: width, height: height,
                          luma: luma, index: frameIndex)

        var result = Result()
        switch mode {
        case .face:
            if frameIndex % visionStride == 0 {
                lastFaceSegments = face.segments(in: frame, settings: settings)
            }
            result.segments = lastFaceSegments
        case .threshold: result.segments = threshold.segments(in: frame, settings: settings)
        case .motion:    result.segments = motion.segments(in: frame, settings: settings)
        }

        if wantsImage {
            result.crops = SegmentEngine.makeCrops(pixelBuffer, segments: result.segments,
                                                   width: width, height: height)
        }

        let now = CACurrentMediaTime()
        if lastFrameTime > 0 {
            let instant = 1 / max(0.0001, now - lastFrameTime)
            smoothedFPS = smoothedFPS == 0 ? instant : smoothedFPS * 0.9 + instant * 0.1
        }
        lastFrameTime = now

        result.width = width
        result.height = height
        result.aspect = frame.aspect
        result.thresholdLevel = threshold.lastLevel
        result.fps = smoothedFPS

        DispatchQueue.main.async { [weak self] in
            self?.onResult?(result)
        }
    }
}
