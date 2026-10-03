import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampServices

/// Choosing a user's lens profile for a photo (LNS-04): by camera and lens, from the Lens Profiles
/// folder, and only for a raw whose file carries no correction of its own.
struct LCPProfileLibraryTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "lens-profiles-\(UUID().uuidString)")

    /// A Nikon Z 6 raw shot with its 24-70 mm zoom at 24 mm and f/4, named as LibRaw names them.
    static let info = ImageInfo(
        url: URL(fileURLWithPath: "/DSC_0001.NEF"), pixelSize: PixelSize(width: 6000, height: 4000), isRaw: true,
        sensorDescription: "Bayer RGGB", make: "Nikon", model: "Z 6", lens: "NIKKOR Z 24-70mm f/4 S", aperture: 4,
        focalLength: 24,
    )

    @discardableResult
    private func write(_ specs: [SyntheticLCP.Spec], to name: String = "Nikon/Z 6 24-70.lcp") throws -> URL {
        let url = directory.appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SyntheticLCP.file(specs).write(to: url)
        return url
    }

    private func correction(
        _ info: ImageInfo = LCPProfileLibraryTests.info, in library: LCPProfileLibrary? = nil,
    ) -> LensCorrection? {
        (library ?? LCPProfileLibrary(directory: directory))
            .correction(for: info, sensorSize: PixelSize(width: 6000, height: 4000), orientation: 0)
    }

    private static func decoded(
        _ info: ImageInfo, lens: LensCorrection?, layout: DecodedImage.Layout = .linearRGB,
    ) -> DecodedImage {
        var image = DecodedImage(
            width: 6000, height: 4000, layout: layout, samples: [], blackLevels: [0, 0, 0], whiteLevel: 1,
            asShotMultipliers: SIMD3(1, 1, 1), cameraToSRGB: [1, 0, 0, 0, 1, 0, 0, 0, 1], xyzToCamera: nil,
            orientation: 0, baselineExposure: 0, info: info,
        )
        image.lensCorrection = lens
        return image
    }

    @Test func `matches the camera and the lens however EXIF and LibRaw spell them`() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try write([SyntheticLCP.Spec()])
        let lens = try #require(correction())
        #expect(lens.source == .profile && lens.correctsColorFringes && !lens.vignetting.isEmpty)
    }

    @Test func `falls back to the lens's display name`() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        var spec = SyntheticLCP.Spec()
        spec.lens = "24.0-70.0 mm f/4.0"
        try write([spec])
        #expect(correction() != nil)
    }

    @Test func `the lens name the file reports wins over a display name`() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        var byDisplayName = SyntheticLCP.Spec()
        byDisplayName.lens = "24.0-70.0 mm f/4.0"
        byDisplayName.vignette = nil
        try write([byDisplayName], to: "a.lcp")
        try write([SyntheticLCP.Spec()], to: "b.lcp")
        #expect(correction()?.vignetting.isEmpty == false)
    }

    @Test func `another lens, camera or make, or a profile made from JPEGs, gives no correction`() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        var jpeg = SyntheticLCP.Spec()
        jpeg.lens = "NIKKOR Z 50mm f/1.8 S"
        jpeg.prettyName = "Nikon NIKKOR Z 50mm f/1.8 S"
        jpeg.focalLength = 50
        jpeg.raw = false
        try write([SyntheticLCP.Spec()])
        try write([jpeg], to: "Nikon/Z 6 50 JPEG.lcp")
        var info = Self.info
        info.lens = "NIKKOR Z 24-120mm f/4 S"
        #expect(correction(info) == nil)
        info.lens = "NIKKOR Z 50mm f/1.8 S"
        info.focalLength = 50
        #expect(correction(info) == nil)
        info = Self.info
        info.model = "Z 7"
        #expect(correction(info) == nil)
        info = Self.info
        info.make = "Canon"
        #expect(correction(info) == nil)
        info = Self.info
        info.lens = nil
        #expect(correction(info) == nil)
    }

    @Test func `a correction the file carries wins over the user's profile`() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try write([SyntheticLCP.Spec()])
        let library = LCPProfileLibrary(directory: directory)
        let builtIn = LensCorrection(
            source: .sony, center: SIMD2(0.5, 0.5), radii: [0, 1], distortion: [], vignetting: [1, 1.5],
        )
        #expect(LensCorrectionReader
            .correction(for: Self.decoded(Self.info, lens: builtIn), profiles: library) == builtIn)
        #expect(LensCorrectionReader.correction(for: Self.decoded(Self.info, lens: nil), profiles: library)?
            .source == .profile)
        #expect(LensCorrectionReader.correction(for: Self.decoded(Self.info, lens: nil), profiles: nil) == nil)
        let bitmap = Self.decoded(Self.info, lens: nil, layout: .linearSRGBHalf)
        #expect(LensCorrectionReader.correction(for: bitmap, profiles: library) == nil)
    }

    @Test func `the profile corrections switch and its amounts govern the user's profile as a built-in one`() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try write([SyntheticLCP.Spec()])
        let lens = try #require(correction())
        var recipe = EditRecipe()
        #expect(GeometryMap.profile(lens, recipe: recipe) == lens.scaled(distortion: 1, vignetting: 1))
        #expect(!GeometryMap(recipe: recipe, imageSize: PixelSize(width: 6000, height: 4000), lens: lens).isIdentity)
        recipe[.lensProfileDistortion] = 50
        recipe[.lensProfileVignetting] = 0
        #expect(GeometryMap.profile(lens, recipe: recipe) == lens.scaled(distortion: 0.5, vignetting: 0))
        recipe[.lensProfile] = 0
        #expect(GeometryMap.profile(lens, recipe: recipe) == nil)
        recipe[.lensProfile] = 1
        recipe.processVersion = 4
        #expect(GeometryMap.profile(lens, recipe: recipe) == nil)
    }

    @Test func `profiles are read from subfolders, again when a file's date changes, and dropped when removed`() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try write([SyntheticLCP.Spec()])
        let modified = Date(timeIntervalSince1970: 1_790_000_000)
        func date(_ date: Date) throws {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        try date(modified)
        let library = LCPProfileLibrary(directory: directory)
        #expect(correction(in: library) != nil)
        var other = SyntheticLCP.Spec()
        other.lens = "NIKKOR Z 24-120mm f/4 S"
        other.prettyName = "Nikon NIKKOR Z 24-120mm f/4 S"
        try write([other])
        try date(modified)
        #expect(correction(in: library) != nil, "the same date: the profile already read")
        try date(modified + 10)
        #expect(correction(in: library) == nil, "a new date: read again")
        try write([SyntheticLCP.Spec()])
        try date(modified + 20)
        #expect(correction(in: library) != nil)
        try FileManager.default.removeItem(at: url)
        #expect(correction(in: library) == nil)
    }

    @Test func `a missing folder holds no profiles`() {
        let library = LCPProfileLibrary(directory: directory.appending(path: "Lens Profiles"))
        #expect(correction(in: library) == nil && library.issues.isEmpty)
    }

    @Test func `a fisheye profile is skipped and reported, as is a file that isn't a profile`() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        var fisheye = SyntheticLCP.Spec()
        fisheye.fisheye = true
        try write([fisheye])
        try Data("<x:xmpmeta".utf8).write(to: directory.appending(path: "Nikon/broken.lcp"))
        let library = LCPProfileLibrary(directory: directory)
        #expect(correction(in: library) == nil)
        let issues = library.issues.values.flatMap(\.self).sorted()
        #expect(issues == [
            "Synthetic (Nikon NIKKOR Z 24-70mm f/4 S) at 24 mm: fisheye profiles aren't supported yet",
            "not an XML file",
        ])
    }

    // MARK: - Raw files

    private static func fixture(_ prefix: String) -> URL? {
        DecodeRegressionTests.fixtures.first { $0.lastPathComponent.hasPrefix(prefix) }
    }

    @Test(.enabled(if: !DecodeRegressionTests.fixtures.isEmpty))
    func `without a matching profile every photo opens with the correction it decoded with`() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        var leica = SyntheticLCP.Spec()
        leica.make = "LEICA CAMERA AG"
        leica.model = "LEICA M11"
        leica.cameraName = "Leica M11"
        leica.lens = "Summilux-M 1:1.4/35 ASPH."
        leica.prettyName = "Leica Summilux-M 35mm f/1.4 ASPH."
        try write([leica], to: "Leica/M11 Summilux 35.lcp")
        let library = LCPProfileLibrary(directory: directory)
        for url in DecodeRegressionTests.fixtures {
            let image = try ImageDecoder.decode(url)
            let opened = LensCorrectionReader.correction(for: image, profiles: library)
            #expect(opened == (image.isRaw ? image.lensCorrection : nil), "\(url.lastPathComponent)")
        }
    }

    @Test(.enabled(if: fixture("DSC_0750") != nil && fixture("_DSC0009") != nil))
    func `a user's profile corrects a raw that carries none, and Sony's own correction wins`() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let nikon = try ImageDecoder.decode(#require(Self.fixture("DSC_0750")))
        let sony = try ImageDecoder.decode(#require(Self.fixture("_DSC0009")))
        var forNikon = SyntheticLCP.Spec()
        forNikon.lens = try #require(nikon.info.lens, "LibRaw names the Nikon's lens")
        forNikon.focalLength = nikon.info.focalLength ?? 24
        var forSony = SyntheticLCP.Spec()
        forSony.make = "SONY"
        forSony.model = "ILCE-7M3"
        forSony.cameraName = "Sony A7 III"
        forSony.lens = try #require(sony.info.lens, "LibRaw names the Sony's lens")
        forSony.focalLength = sony.info.focalLength ?? 24
        try write([forNikon], to: "nikon.lcp")
        try write([forSony], to: "sony.lcp")
        let library = LCPProfileLibrary(directory: directory)
        #expect(nikon.lensCorrection == nil)
        let corrected = try #require(LensCorrectionReader.correction(for: nikon, profiles: library))
        #expect(corrected.source == .profile && corrected.correctsColorFringes && !corrected.vignetting.isEmpty)
        #expect(LensCorrectionReader.correction(for: sony, profiles: library) == sony.lensCorrection)
        #expect(sony.lensCorrection?.source == .sony)
    }
}
