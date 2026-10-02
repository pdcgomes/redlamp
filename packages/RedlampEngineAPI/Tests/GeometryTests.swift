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

    @Test func `guided upright finds the correction that makes the guides vertical`() {
        // A frame that needs Vertical −40: two building edges that are vertical once corrected.
        var truth = Transform()
        truth.vertical = -40
        let map = GeometryMap(imageSize: size, transform: truth)
        let guides = [0.25, 0.75].map { x in
            let top = map.imagePoint(SIMD2(x, 0.15)) ?? .zero
            let bottom = map.imagePoint(SIMD2(x, 0.85)) ?? .zero
            return GuideLine(start: ImagePoint(x: top.x, y: top.y), end: ImagePoint(x: bottom.x, y: bottom.y))
        }
        let solved = Transform().guided(by: guides, imageSize: size, orientation: .identity)
        #expect(abs(solved.vertical + 40) < 0.5, "vertical \(solved.vertical)")
        #expect(abs(solved.horizontal) < 0.5 && abs(solved.rotate) < 0.05, "\(solved.horizontal), \(solved.rotate)")
    }

    @Test func `guided upright levels a tilted horizon with Rotate`() {
        let radians = 3.0 * .pi / 180
        let horizon = GuideLine(
            start: ImagePoint(x: 0.1, y: 0.5 - 0.4 * tan(radians) * 1.5),
            end: ImagePoint(x: 0.9, y: 0.5 + 0.4 * tan(radians) * 1.5),
        )
        let solved = Transform().guided(by: [horizon], imageSize: size, orientation: .identity)
        let map = GeometryMap(imageSize: size, transform: solved)
        let a = map.outputPoint(SIMD2(horizon.start.x, horizon.start.y)) ?? .zero
        let b = map.outputPoint(SIMD2(horizon.end.x, horizon.end.y)) ?? .zero
        #expect(abs((b.y - a.y) * 400) < 0.5, "the horizon is level: \((b.y - a.y) * 400) px")
    }

    /// Edges of a scene shot so that `truth` corrects it: verticals and horizontals once corrected,
    /// where the photo shows them, plus shorter roof lines when asked.
    private func sceneLines(_ truth: Transform, roofs: Bool = false) -> [DetectedLine] {
        let map = GeometryMap(imageSize: size, transform: truth)
        func line(_ a: SIMD2<Double>, _ b: SIMD2<Double>, strength: Double) -> DetectedLine {
            let pa = map.imagePoint(a) ?? .zero, pb = map.imagePoint(b) ?? .zero
            return DetectedLine(
                line: GuideLine(start: ImagePoint(x: pa.x, y: pa.y), end: ImagePoint(x: pb.x, y: pb.y)),
                strength: strength,
            )
        }
        var lines = [0.2, 0.4, 0.6, 0.8].map { x in line(SIMD2(x, 0.2), SIMD2(x, 0.8), strength: 200) }
        lines += [0.25, 0.45, 0.65, 0.85].map { y in line(SIMD2(0.15, y), SIMD2(0.85, y), strength: 200) }
        if roofs {
            lines.append(line(SIMD2(0.3, 0.2), SIMD2(0.5, 0.12), strength: 80))
            lines.append(line(SIMD2(0.5, 0.12), SIMD2(0.7, 0.2), strength: 80))
        }
        return lines
    }

    @Test func `Full upright recovers tilt, turn and roll, ignoring roof lines`() throws {
        var truth = Transform()
        truth.vertical = -30
        truth.horizontal = 20
        truth.rotate = 2
        let solved = try #require(Transform().upright(
            .full, lines: sceneLines(truth, roofs: true), imageSize: size, orientation: .identity,
        ))
        #expect(abs(solved.vertical + 30) < 1 && abs(solved.horizontal - 20) < 1, "\(solved)")
        #expect(abs(solved.rotate - 2) < 0.1, "\(solved.rotate)")
    }

    @Test func `Vertical upright corrects verticals and roll but not turn`() throws {
        var truth = Transform()
        truth.vertical = -30
        truth.rotate = -1.5
        var start = Transform()
        start.horizontal = 15
        start.scale = 110
        let solved = try #require(start.upright(
            .vertical,
            lines: sceneLines(truth),
            imageSize: size,
            orientation: .identity,
        ))
        #expect(abs(solved.vertical + 30) < 1 && abs(solved.rotate + 1.5) < 0.1, "\(solved)")
        #expect(solved.horizontal == 0, "Upright replaces the earlier correction")
        #expect(solved.scale == 110, "and keeps the other sliders")
    }

    @Test func `Level upright only rotates`() throws {
        var truth = Transform()
        truth.rotate = 3
        let solved = try #require(Transform().upright(
            .level,
            lines: sceneLines(truth),
            imageSize: size,
            orientation: .identity,
        ))
        #expect(abs(solved.rotate - 3) < 0.05 && solved.vertical == 0 && solved.horizontal == 0, "\(solved)")
    }

    @Test func `Auto upright leaves strong perspective partly in place`() throws {
        func kept(_ transform: Transform) -> Double {
            var recipe = EditRecipe()
            recipe[.transformVertical] = transform.vertical
            recipe[.transformHorizontal] = transform.horizontal
            recipe[.transformRotate] = transform.rotate
            let crop = GeometryMap.constrained(.full, recipe: recipe, imageSize: size)
            return crop.width * crop.height
        }
        for (truth, eased) in [(-10.0, false), (-60, true)] {
            var transform = Transform()
            transform.vertical = truth
            let lines = sceneLines(transform)
            let full = try #require(Transform().upright(.full, lines: lines, imageSize: size, orientation: .identity))
            let auto = try #require(Transform().upright(.auto, lines: lines, imageSize: size, orientation: .identity))
            #expect(abs(full.vertical - truth) < 1.5, "full \(full.vertical)")
            if eased {
                #expect(abs(auto.vertical - (-30 + 0.5 * (full.vertical + 30))) < 1e-9, "auto \(auto.vertical)")
                #expect(kept(auto) >= 0.8 - 1e-3, "auto keeps \(kept(auto)) of the frame")
            } else {
                #expect(auto == full, "a mild correction stays whole")
            }
        }
    }

    @Test func `upright ignores lines that don't agree on a correction`() {
        // Short edges in every direction, as foliage gives: no correction is agreed.
        var random = SplitMix(seed: 5)
        let lines = (0 ..< 40).map { _ in
            let (x, y, angle) = (random.unit() * 0.8 + 0.1, random.unit() * 0.8 + 0.1, (random.unit() - 0.5) * 0.9)
            let (dx, dy) = (0.03 * sin(angle), 0.04 * cos(angle))
            return DetectedLine(
                line: GuideLine(start: ImagePoint(x: x, y: y), end: ImagePoint(x: x + dx, y: y + dy)),
                strength: 25,
            )
        }
        #expect(Transform().upright(.auto, lines: lines, imageSize: size, orientation: .identity) == nil)
    }

    @Test func `upright needs enough edges`() {
        let short = DetectedLine(
            line: GuideLine(start: ImagePoint(x: 0.5, y: 0.4), end: ImagePoint(x: 0.5, y: 0.45)),
            strength: 10,
        )
        #expect(Transform().upright(.auto, lines: [short], imageSize: size, orientation: .identity) == nil)
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

/// A small deterministic generator for test data.
private struct SplitMix {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func unit() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
}
