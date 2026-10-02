import CoreGraphics
import Foundation
import RedlampEngineAPI
import Vision

/// Face parts as polygons from Vision's landmarks, rasterised in mask space.
enum FaceParts {
    static func mask(
        _ part: PersonPart,
        landmarks: VNFaceLandmarks2D,
        size: PixelSize,
        people: GrayMask?,
        pixels: RGBImage?,
    ) -> GrayMask? {
        let face = Face(landmarks, size: size)
        return switch part {
        case .lips: face.lips()
        case .eyebrows: face.eyebrows()
        case .iris: face.iris()
        case .eyeSclera: face.sclera()
        case .faceSkin: face.skin(people: people)
        case .teeth: pixels.flatMap(face.teeth)
        case .entirePerson, .bodySkin, .hair, .facialHair, .clothes: nil
        }
    }

    /// One face's landmark regions, in image points of `size` (bottom-left origin).
    private struct Face {
        let size: PixelSize
        let contour: [CGPoint]
        let eyes: [[CGPoint]]
        let pupils: [CGPoint]
        let brows: [[CGPoint]]
        let outerLips: [CGPoint]
        let innerLips: [CGPoint]
        /// The scale of strokes and the iris.
        let eyeWidth: CGFloat

        init(_ landmarks: VNFaceLandmarks2D, size: PixelSize) {
            self.size = size
            let imageSize = CGSize(width: size.width, height: size.height)
            func polygon(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
                region?.pointsInImage(imageSize: imageSize) ?? []
            }
            contour = polygon(landmarks.faceContour)
            eyes = [polygon(landmarks.leftEye), polygon(landmarks.rightEye)].filter { $0.count >= 3 }
            pupils = [polygon(landmarks.leftPupil), polygon(landmarks.rightPupil)].compactMap(\.first)
            brows = [polygon(landmarks.leftEyebrow), polygon(landmarks.rightEyebrow)].filter { $0.count >= 2 }
            outerLips = polygon(landmarks.outerLips)
            innerLips = polygon(landmarks.innerLips)
            eyeWidth = eyes.map { points in
                (points.map(\.x).max() ?? 0) - (points.map(\.x).min() ?? 0)
            }.max() ?? 0
        }

        var irisRadius: CGFloat {
            eyeWidth * 0.22
        }

        func irisDiscs(_ context: CGContext) {
            for pupil in pupils {
                context.fillEllipse(in: CGRect(
                    x: pupil.x - irisRadius, y: pupil.y - irisRadius, width: irisRadius * 2, height: irisRadius * 2,
                ))
            }
        }

        func browStrokes(_ context: CGContext) {
            context.setLineWidth(max(eyeWidth * 0.18, 2))
            context.setLineCap(.round)
            context.setLineJoin(.round)
            brows.forEach { FaceParts.stroke(context, $0) }
        }

        func lips() -> GrayMask? {
            guard outerLips.count >= 3 else { return nil }
            return FaceParts.draw(size) { context in
                FaceParts.fill(context, outerLips)
                context.setBlendMode(.clear)
                FaceParts.fill(context, innerLips)
            }
        }

        func eyebrows() -> GrayMask? {
            brows.isEmpty ? nil : FaceParts.draw(size, browStrokes)
        }

        func iris() -> GrayMask? {
            guard !pupils.isEmpty, irisRadius > 0,
                  let discs = FaceParts.draw(size, irisDiscs),
                  let eyeShapes = FaceParts.draw(size, { context in eyes.forEach { FaceParts.fill(context, $0) } })
            else { return nil }
            return discs.intersection(eyeShapes)
        }

        func sclera() -> GrayMask? {
            guard !eyes.isEmpty else { return nil }
            return FaceParts.draw(size) { context in
                eyes.forEach { FaceParts.fill(context, $0) }
                context.setBlendMode(.clear)
                irisDiscs(context)
            }
        }

        /// The face outline (closed above the brows for the forehead), within the person, less
        /// the eyes, brows and lips.
        func skin(people: GrayMask?) -> GrayMask? {
            guard contour.count >= 3, let first = contour.first, let last = contour.last else { return nil }
            let browTop = brows.joined().map(\.y).max() ?? contour.map(\.y).max() ?? 0
            let forehead = browTop + eyeWidth * 0.9
            let outline = contour + [CGPoint(x: last.x, y: forehead), CGPoint(x: first.x, y: forehead)]
            let face = FaceParts.draw(size) { context in
                FaceParts.fill(context, outline)
                context.setBlendMode(.clear)
                eyes.forEach { FaceParts.fill(context, $0) }
                FaceParts.fill(context, outerLips)
                browStrokes(context)
            }
            guard let face, let people else { return face }
            return face.intersection(people)
        }

        /// Bright, pale pixels inside the lips.
        func teeth(_ pixels: RGBImage) -> GrayMask? {
            guard innerLips.count >= 3, let mouth = FaceParts.draw(
                size,
                { context in FaceParts.fill(context, innerLips) },
            ) else { return nil }
            var teeth = mouth.pixels
            for index in teeth.indices where teeth[index] > 0 {
                let rgb = pixels.rgb(index % size.width, index / size.width)
                let bright = rgb.max()
                if bright <= 0.45 || rgb.max() - rgb.min() >= 0.25 * bright {
                    teeth[index] = 0
                }
            }
            return GrayMask(width: size.width, height: size.height, pixels: teeth)
        }
    }

    /// Draws white shapes on black with CoreGraphics. Vision's image points have a bottom-left
    /// origin, as CoreGraphics does, and a bitmap context's memory starts with the top row, so
    /// the pixels come out top-left first, in mask space.
    private static func draw(_ size: PixelSize, _ body: (CGContext) -> Void) -> GrayMask? {
        var pixels = [UInt8](repeating: 0, count: size.width * size.height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: size.width, height: size.height, bitsPerComponent: 8,
                bytesPerRow: size.width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue,
            ) else { return false }
            context.setFillColor(gray: 1, alpha: 1)
            context.setStrokeColor(gray: 1, alpha: 1)
            body(context)
            return true
        }
        guard drawn else { return nil }
        // CGContext's memory starts with the top row, so the bitmap is already top-left first.
        return GrayMask(width: size.width, height: size.height, pixels: pixels)
    }

    private static func fill(_ context: CGContext, _ points: [CGPoint]) {
        guard points.count >= 3 else { return }
        context.beginPath()
        context.addLines(between: points)
        context.closePath()
        context.fillPath()
    }

    private static func stroke(_ context: CGContext, _ points: [CGPoint]) {
        guard points.count >= 2 else { return }
        context.beginPath()
        context.addLines(between: points)
        context.strokePath()
    }
}
