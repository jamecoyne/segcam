import CoreGraphics
import Foundation
import Vision

/// Vision-backed segmenter: eyes and mouth.
///
/// Faces are detected only for their landmarks — the face box itself is not a segment, and
/// nothing is tracked between frames. Every frame's face is a new instance, so `eye.L#412`,
/// `eye.R#412` and `mouth#412` are one face in one frame and the next frame gets fresh
/// numbers.
final class FaceSegmenter {
    private let sequence = VNSequenceRequestHandler()
    private let faceRequest = VNDetectFaceLandmarksRequest()
    private let numberer = InstanceNumberer()
    private let maxFaces = 4

    func reset() { numberer.reset() }

    func segments(in frame: Frame, settings: SegmentSettings) -> [Segment] {
        guard let buffer = frame.pixelBuffer else { return [] }
        do {
            try sequence.perform([faceRequest], on: buffer, orientation: .up)
        } catch {
            return []
        }
        return build(faces: faceRequest.results ?? [],
                     imageSize: CGSize(width: frame.width, height: frame.height))
    }

    /// Split out from `segments(in:)` so the CLI harness can drive it from a still image.
    func build(faces: [VNFaceObservation], imageSize: CGSize) -> [Segment] {
        var out: [Segment] = []
        for face in faces.prefix(maxFaces) {
            guard let landmarks = face.landmarks else { continue }
            let number = numberer.take()

            // Landmark points hug the lid and lip line, so an unpadded box reads as too tight.
            if let region = landmarks.leftEye {
                out.append(Segment(id: SegmentID(kind: .eyeLeft, number: number),
                                   rect: box(region, imageSize: imageSize).padded(by: 0.4).atLeast(0.02),
                                   score: face.confidence))
            }
            if let region = landmarks.rightEye {
                out.append(Segment(id: SegmentID(kind: .eyeRight, number: number),
                                   rect: box(region, imageSize: imageSize).padded(by: 0.4).atLeast(0.02),
                                   score: face.confidence))
            }
            if let region = landmarks.outerLips {
                out.append(Segment(id: SegmentID(kind: .mouth, number: number),
                                   rect: box(region, imageSize: imageSize).padded(by: 0.15).atLeast(0.03),
                                   score: face.confidence))
            }
        }
        return out
    }

    /// Vision landmark points are image-space, origin bottom-left — flipped here, once.
    private func box(_ region: VNFaceLandmarkRegion2D, imageSize: CGSize) -> NormRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let points = region.pointsInImage(imageSize: imageSize).map {
            CGPoint(x: $0.x / imageSize.width, y: 1 - $0.y / imageSize.height)
        }
        return NormRect.bounding(points).clamped()
    }
}
