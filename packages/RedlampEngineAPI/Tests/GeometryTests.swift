import Foundation
import simd
import Testing
@testable import RedlampEngineAPI

/// Crop, straighten, Transform and orientation as one map (LNS-05).
struct GeometryTests {
    private let size = PixelSize(width: 600, height: 400)

    private func expectNear(_ a: SIMD2<Double>?, _ b: SIMD2<Double>, _ note: String = "") {
        guard let a else {
            Issue.record("no point \(note)")
            return
        }
        #expect(simd_distance(a, b) < 1e-9, "\(a) vs \(b) \(note)")
    }

    @Test func `no geometry maps every point to itself`() {
        let map = GeometryMap(imageSize: size)
        #expect(map.isIdentity && map.outputSize == size)
        for point in [SIMD2(0.0, 0.0), SIMD2(0.3, 0.7), SIMD2(1, 1)] {
            expectNear(map.imagePoint(point), point)
        }
    }

    @Test func `a clockwise turn swaps the axes and puts the left edge on top`() {
        let map = GeometryMap(imageSize: size, orientation: ImageOrientation().rotatedClockwise)
        #expect(map.outputSize == PixelSize(width: 400, height: 600))
        // The output's top-left shows the photo's bottom-left.
        expectNear(map.imagePoint(SIMD2(0, 0)), SIMD2(0, 1))
        expectNear(map.imagePoint(SIMD2(1, 0)), SIMD2(0, 0))
    }

    @Test func `turns and flips compose`() {
        let identity = ImageOrientation.identity
        #expect(identity.rotatedClockwise.rotatedClockwise.rotatedClockwise.rotatedClockwise == identity)
        #expect(identity.flippedHorizontally.flippedHorizontally == identity)
        #expect(identity.rotatedClockwise.rotatedCounterclockwise == identity)
        // A horizontal flip of a turned photo mirrors what is on screen.
        let turned = identity.rotatedClockwise
        let flipped = GeometryMap(imageSize: size, orientation: turned.flippedHorizontally)
        let shown = GeometryMap(imageSize: size, orientation: turned)
        for point in [SIMD2(0.1, 0.2), SIMD2(0.8, 0.6)] {
            expectNear(flipped.imagePoint(point), shown.imagePoint(SIMD2(1 - point.x, point.y)) ?? .zero)
        }
        let upsideDown = GeometryMap(imageSize: size, orientation: turned.flippedVertically)
        expectNear(upsideDown.imagePoint(SIMD2(0.1, 0.2)), shown.imagePoint(SIMD2(0.1, 0.8)) ?? .zero)
    }

    @Test func `the output covers the crop`() {
        let crop = CropRect(left: 0.2, top: 0.1, right: 0.7, bottom: 0.6)
        let map = GeometryMap(imageSize: size, crop: crop)
        #expect(map.outputSize == PixelSize(width: 300, height: 200))
        expectNear(map.imagePoint(SIMD2(0, 0)), SIMD2(0.2, 0.1))
        expectNear(map.imagePoint(SIMD2(1, 1)), SIMD2(0.7, 0.6))
        #expect(abs(map.pixelScale - 1) < 1e-6)
    }

    @Test func `straightening turns about the centre`() {
        let map = GeometryMap(imageSize: size, angle: 10)
        expectNear(map.imagePoint(SIMD2(0.5, 0.5)), SIMD2(0.5, 0.5))
        // The photo turns clockwise on screen, so the output's right-hand middle shows a point
        // above the photo's right-hand middle.
        let right = map.imagePoint(SIMD2(1, 0.5)) ?? .zero
        #expect(right.y < 0.5 && right.x < 1)
        #expect(!map.staysInsideImage)
    }

    @Test func `negative vertical widens the top`() {
        var transform = Transform()
        transform.vertical = -50
        let map = GeometryMap(imageSize: size, transform: transform)
        expectNear(map.imagePoint(SIMD2(0.5, 0.5)), SIMD2(0.5, 0.5), "the centre stays")
        // The photo's top corners spread outwards, so the output's top corners show less.
        let topLeft = map.outputPoint(SIMD2(0, 0)) ?? .zero
        let bottomLeft = map.outputPoint(SIMD2(0, 1)) ?? .zero
        #expect(topLeft.x < bottomLeft.x, "top \(topLeft), bottom \(bottomLeft)")
    }

    @Test func `the inverse undoes the map`() {
        var transform = Transform()
        transform.vertical = 30
        transform.horizontal = -20
        transform.rotate = 3
        transform.aspect = 15
        transform.scale = 110
        transform.offsetX = 8
        let map = GeometryMap(
            imageSize: size, orientation: ImageOrientation(quarterTurns: 3, mirrored: true),
            crop: CropRect(left: 0.1, top: 0.15, right: 0.85, bottom: 0.9), angle: -7, transform: transform,
        )
        for point in [SIMD2(0.0, 0.0), SIMD2(0.4, 0.6), SIMD2(1, 1)] {
            let image = map.imagePoint(point) ?? .zero
            expectNear(map.outputPoint(image), point)
        }
    }

    @Test func `constraining to the image keeps the aspect and fills the frame`() {
        let constrained = GeometryMap.constrained(
            .full, imageSize: size, orientation: .identity, angle: 8, transform: Transform(),
        )
        #expect(constrained.width < 1 && abs(constrained.width - constrained.height) < 1e-9)
        expectNear(constrained.center, SIMD2(0.5, 0.5))
        let map = GeometryMap(imageSize: size, crop: constrained, angle: 8)
        #expect(map.staysInsideImage)
        let larger = GeometryMap(imageSize: size, crop: constrained.scaled(by: 1.01), angle: 8)
        #expect(!larger.staysInsideImage, "the largest crop that fits")
    }

    @Test func `lens distortion and its inverse undo each other`() {
        let map = GeometryMap(imageSize: size, angle: 4, lensDistortion: 0.15)
        for point in [SIMD2(0.05, 0.1), SIMD2(0.5, 0.5), SIMD2(0.9, 0.7)] {
            let image = map.imagePoint(point) ?? .zero
            expectNear(map.outputPoint(image), point)
        }
    }

    @Test func `correcting barrel distortion stays inside the photo, pincushion leaves corners empty`() {
        var recipe = EditRecipe()
        recipe[.lensDistortion] = 60
        let barrel = GeometryMap(recipe: recipe, imageSize: size)
        #expect(barrel.staysInsideImage)
        let corner = barrel.imagePoint(SIMD2(0, 0)) ?? .zero
        #expect(corner.x > 0 && corner.y > 0, "the corner shows a point recorded nearer the centre")
        recipe[.lensDistortion] = -60
        #expect(!GeometryMap(recipe: recipe, imageSize: size).staysInsideImage)
        recipe.crop = GeometryMap.constrained(.full, recipe: recipe, imageSize: size)
        #expect(recipe.crop.width < 1)
        #expect(GeometryMap(recipe: recipe, imageSize: size).staysInsideImage)
    }

    @Test func `crop and orientation are kept in the sidecar only when set`() throws {
        var recipe = EditRecipe()
        let plain = try JSONEncoder().encode(recipe)
        #expect(!String(decoding: plain, as: UTF8.self).contains("crop"))
        recipe.crop = CropRect(left: 0.1, top: 0, right: 0.9, bottom: 1)
        recipe.orientation = ImageOrientation(quarterTurns: 1)
        recipe[.cropAngle] = 2.5
        #expect(!recipe.isPristine)
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(recipe))
        #expect(decoded == recipe)
    }
}
