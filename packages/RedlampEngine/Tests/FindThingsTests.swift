import Foundation
import RedlampEngineAPI
import RedlampMasking
import Testing
@testable import RedlampEngine

/// The D7500 sample (`mise run fixtures-shoots`), whose drive has a red car parked on it.
enum FindSample {
    static let url = DustSamples.files("shoots/scenes").first { $0.lastPathComponent.contains("D7500") }
    /// The red car's middle, in the photo as shown.
    static let car = ImagePoint(x: 0.28, y: 0.62)
}

/// Things named in words (RM-08): OWLv2 boxes them, and Segment Anything cuts each box's mask.
/// Needs the models downloaded and the D7500 sample.
@Suite(.enabled(if: EngineSmokeTests.canRender && MaskRenderTests.isInstalled("owlv2-base") && FindSample.url != nil))
struct FindThingsTests {
    @Test func `the car is found where it's parked, and nothing outside the photo`() async throws {
        let engine = try RedlampEngine()
        _ = try await engine.open(#require(FindSample.url))
        let things = await engine.thingsToFind()
        #expect(things.contains("car") && things.contains("trash") && things.count == 13, "\(things)")
        let found = try await engine.findThings(Set(things), threshold: 0.25)
        let car = try #require(found.first { $0.thing == "car" }, "\(found)")
        #expect(car.score > 0.3)
        #expect(car.box.x < FindSample.car.x && FindSample.car.x < car.box.x + car.box.width, "\(car.box)")
        #expect(car.box.y < FindSample.car.y && FindSample.car.y < car.box.y + car.box.height, "\(car.box)")
        #expect(found.allSatisfy { $0.box.x >= 0 && $0.box.y >= 0 && $0.box.x + $0.box.width <= 1.0001 })
        #expect(found.map(\.score) == found.map(\.score).sorted(by: >))
        #expect(try await engine.findThings(["bird"], threshold: 0.25).allSatisfy { $0.thing == "bird" })
    }

    @Test(.enabled(if: MaskRenderTests.samIsInstalled))
    func `a found thing's box gives Segment Anything its whole outline`() async throws {
        let engine = try RedlampEngine()
        _ = try await engine.open(#require(FindSample.url))
        let car = try #require(try await engine.findThings(["car"], threshold: 0.25).first)
        let mask = try #require(try await engine.computeMasks(MaskRequest(kind: .objects, box: car.box)).first)
        let gray = try #require(mask.bitmap.png.flatMap(GrayMask.decode))
        func coverage(_ point: ImagePoint) -> UInt8 {
            gray[Int(point.x * Double(gray.width)), Int(point.y * Double(gray.height))]
        }
        #expect(coverage(FindSample.car) > 200)
        #expect(coverage(ImagePoint(x: 0.9, y: 0.1)) < 30, "the sky")
        #expect(coverage(ImagePoint(x: 0.75, y: 0.62)) < 30, "the garage door")
        let box = car.box.width * car.box.height
        #expect(
            gray.coveredFraction > box * 0.4 && gray.coveredFraction < box * 1.1,
            "\(gray.coveredFraction) of \(box)",
        )
    }
}
