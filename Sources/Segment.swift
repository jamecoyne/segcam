import CoreGraphics
import Foundation

enum SegmentKind: String, CaseIterable {
    case eyeLeft, eyeRight, mouth, blob, motion

    var displayName: String {
        switch self {
        case .eyeLeft:  return "eye.L"
        case .eyeRight: return "eye.R"
        case .mouth:    return "mouth"
        case .blob:     return "blob"
        case .motion:   return "motion"
        }
    }
}

/// Kind + number. Unique across the whole app, so it can key the swarm's window map.
struct SegmentID: Hashable {
    let kind: SegmentKind
    let number: Int
}

struct Segment {
    let id: SegmentID
    var rect: NormRect
    var score: Float

    var label: String { "\(id.kind.displayName)#\(id.number)" }
}

/// Numbers segments. There is deliberately **no tracking across frames**: every frame is a
/// fresh set of instances, so a thing standing still in front of the camera produces a new
/// numbered segment — and a new window — on every single frame. That is what makes the
/// desktop collage pile up.
final class InstanceNumberer {
    private var next = 1

    func reset() { next = 1 }

    /// One number for this detection (or this group of related detections, like the eyes
    /// and mouth of one face).
    func take() -> Int {
        defer { next += 1 }
        return next
    }
}

/// Tunables shared by the segmenters. Copied under lock on the main thread and handed
/// to the segmenters by value, so the capture queue never reads a torn setting.
struct SegmentSettings {
    /// The motion segmenter's knob is a difference *threshold*, where smaller means twitchier.
    /// Everything user-facing talks in sensitivity instead, so the slider and the keys both
    /// move the way the label reads: right, or `]`, means more sensitive.
    static let motionThresholdRange = 2...120

    var motionSensitivityFraction: Double {
        get {
            let span = Double(SegmentSettings.motionThresholdRange.upperBound
                                - SegmentSettings.motionThresholdRange.lowerBound)
            let offset = Double(motionSensitivity - SegmentSettings.motionThresholdRange.lowerBound)
            return 1 - offset / span
        }
        set {
            let clamped = min(1, max(0, newValue))
            let span = Double(SegmentSettings.motionThresholdRange.upperBound
                                - SegmentSettings.motionThresholdRange.lowerBound)
            motionSensitivity = SegmentSettings.motionThresholdRange.lowerBound
                + Int(((1 - clamped) * span).rounded())
        }
    }

    var thresholdLevel: Int = 170
    var invertThreshold = false
    var autoThreshold = false
    var motionSensitivity: Int = 18
    var motionAdaptation: Float = 0.06
    var minAreaFraction: CGFloat = 0.0025
    var maxSegments: Int = 16
}
