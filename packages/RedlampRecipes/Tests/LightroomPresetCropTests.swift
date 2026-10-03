import Foundation
import RedlampEngineAPI
import simd
import Testing
@testable import RedlampRecipes

/// Lightroom's crop in Redlamp's terms, checked against Redlamp's own geometry: the developed
/// frame's corners must land on the corners Lightroom's fields describe.
struct LightroomPresetCropTests {
    private let stored = PixelSize(width: 6000, height: 4000)

    /// `vector` turned clockwise on screen (y down) by `degrees`.
    private func turned(_ vector: SIMD2<Double>, _ degrees: Double) -> SIMD2<Double> {
        let radians = degrees * .pi / 180
        return SIMD2(
            cos(radians) * vector.x - sin(radians) * vector.y,
            sin(radians) * vector.x + cos(radians) * vector.y,
        )
    }

    /// The crop's four corners, 0...1 across the stored pixels, as Lightroom defines them: the
    /// upper-left and lower-right are given, and the crop turns clockwise about its centre.
    private func lightroomCorners(_ crop: LightroomCrop) -> [SIMD2<Double>] {
        let scale = SIMD2(Double(stored.width), Double(stored.height))
        let upperLeft = SIMD2(crop.left, crop.top) * scale
        let lowerRight = SIMD2(crop.right, crop.bottom) * scale
        let centre = (upperLeft + lowerRight) / 2
        let half = turned(lowerRight - upperLeft, -crop.angle) / 2
        return [SIMD2(-1, -1), SIMD2(1, -1), SIMD2(1, 1), SIMD2(-1, 1)].map { corner in
            (centre + turned(half * corner, crop.angle)) / scale
        }
    }

    private func photoSize(_ cameraOrientation: ImageOrientation) -> PixelSize {
        cameraOrientation.swapsAxes ? PixelSize(width: stored.height, height: stored.width) : stored
    }

    @Test func `an upright crop on an upright photo maps one to one`() throws {
        let crop = LightroomCrop(left: 0.1, top: 0.2, right: 0.8, bottom: 0.9)
        let mapped = try #require(crop.redlampCrop(imageSize: stored))
        #expect(mapped.angle == 0)
        #expect(abs(mapped.crop.left - 0.1) < 1e-12 && abs(mapped.crop.top - 0.2) < 1e-12)
        #expect(abs(mapped.crop.right - 0.8) < 1e-12 && abs(mapped.crop.bottom - 0.9) < 1e-12)
    }

    @Test func `a crop on a photo the camera turned turns with it`() throws {
        // A quarter turn clockwise takes a stored point (x, y) to (1 - y, x).
        let crop = LightroomCrop(left: 0.1, top: 0.2, right: 0.5, bottom: 0.6)
        let quarterTurn = ImageOrientation(quarterTurns: 1)
        let mapped = try #require(crop.redlampCrop(imageSize: photoSize(quarterTurn), cameraOrientation: quarterTurn))
        #expect(mapped.angle == 0)
        let expected = CropRect(left: 0.4, top: 0.1, right: 0.8, bottom: 0.5)
        for (value, target) in zip(
            [mapped.crop.left, mapped.crop.top, mapped.crop.right, mapped.crop.bottom],
            [expected.left, expected.top, expected.right, expected.bottom],
        ) {
            #expect(abs(value - target) < 1e-12)
        }
    }

    @Test func `a turned crop's corners land on Lightroom's, whatever the orientations`() throws {
        let crop = LightroomCrop(left: 0.1, top: 0.15, right: 0.85, bottom: 0.9, angle: 5)
        let orientations = [
            ImageOrientation(), ImageOrientation(quarterTurns: 1), ImageOrientation(quarterTurns: 2),
            ImageOrientation(quarterTurns: 3), ImageOrientation(mirrored: true),
            ImageOrientation(quarterTurns: 1, mirrored: true),
        ]
        for camera in orientations {
            for edit in [ImageOrientation(), ImageOrientation(quarterTurns: 3), ImageOrientation(mirrored: true)] {
                let imageSize = photoSize(camera)
                let mapped = try #require(
                    crop.redlampCrop(imageSize: imageSize, cameraOrientation: camera, orientation: edit),
                )
                let map = GeometryMap(imageSize: imageSize, orientation: edit, crop: mapped.crop, angle: mapped.angle)
                let developed = try [SIMD2(0.0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)].map { corner in
                    try #require(map.imagePoint(corner))
                }
                let expected = lightroomCorners(crop).map { point in
                    let oriented = camera.matrix * SIMD3(point.x, point.y, 1)
                    return SIMD2(oriented.x, oriented.y)
                }
                for corner in expected {
                    #expect(
                        developed.contains { simd_distance($0, corner) < 1e-9 },
                        "camera \(camera), edit \(edit): \(corner) isn't a corner of \(developed)",
                    )
                }
            }
        }
    }

    @Test func `the crop turns clockwise over the photo, as Lightroom's does`() throws {
        let crop = LightroomCrop(left: 0.1, top: 0.15, right: 0.85, bottom: 0.9, angle: 5)
        let mapped = try #require(crop.redlampCrop(imageSize: stored))
        #expect(abs(mapped.angle + 5) < 1e-12)
        let map = GeometryMap(imageSize: stored, crop: mapped.crop, angle: mapped.angle)
        let scale = SIMD2(Double(stored.width), Double(stored.height))
        let upperLeft = try #require(map.imagePoint(SIMD2(0, 0))) * scale
        let upperRight = try #require(map.imagePoint(SIMD2(1, 0))) * scale
        // The top edge in the photo's pixels, y down: positive angles are clockwise.
        let edge = upperRight - upperLeft
        #expect(abs(atan2(edge.y, edge.x) * 180 / .pi - 5) < 1e-9)
        #expect(simd_distance(upperLeft / scale, SIMD2(0.1, 0.15)) < 1e-9)
    }

    @Test func `corners that don't make a crop give none`() {
        #expect(LightroomCrop(left: 0.8, top: 0.2, right: 0.1, bottom: 0.9).redlampCrop(imageSize: stored) == nil)
        #expect(LightroomCrop(left: 0.1, top: 0.5, right: 0.8, bottom: 0.5).redlampCrop(imageSize: stored) == nil)
    }

    @Test(arguments: PresetXMP.Form.allCases)
    func `a preset's crop is read beside the recipe, which doesn't hold it`(form: PresetXMP.Form) throws {
        let imported = try LightroomPreset.convert(PresetXMP.preset([
            ("HasCrop", "True"), ("CropTop", "0.15"), ("CropLeft", "0.1"), ("CropBottom", "0.9"), ("CropRight", "0.85"),
            ("CropAngle", "5"), ("CropConstrainToWarp", "1"), ("CropWidth", "1800"), ("CropUnit", "0"),
            ("Exposure2012", "+0.25"),
        ], form: form))
        #expect(imported.crop == LightroomCrop(
            left: 0.1, top: 0.15, right: 0.85, bottom: 0.9, angle: 5, constrainsToImage: true,
        ))
        #expect(imported.recipe.includes == [.tone])
        for setting in [
            "HasCrop",
            "CropTop",
            "CropLeft",
            "CropBottom",
            "CropRight",
            "CropAngle",
            "CropConstrainToWarp",
        ] {
            #expect(imported.report.outcome(setting) == .ignored)
            #expect(imported.report.note(setting) == LightroomPreset.Note.crop)
        }
        #expect(imported.report.note("CropWidth") == LightroomPreset.Note.cropSize)
        #expect(imported.report.note("CropUnit") == LightroomPreset.Note.cropSize)

        let none = try LightroomPreset.convert(PresetXMP.preset([
            ("HasCrop", "False"), ("CropTop", "0"), ("CropLeft", "0"), ("CropBottom", "1"), ("CropRight", "1"),
            ("Exposure2012", "+0.25"),
        ], form: form))
        #expect(none.crop == nil)
    }
}
