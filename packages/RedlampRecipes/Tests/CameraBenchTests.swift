import CoreGraphics
import Foundation
import RedlampEngine
import RedlampEngineAPI
import RedlampServices
import Testing
@testable import RedlampRecipes

/// The camera bench (CAM-14): no false alarms on the verified cameras, and each fault it's
/// meant to catch caught by its own check, through the real decode and rendering.
@Suite(.serialized)
struct CameraBenchTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    static func raws(in folder: String) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: root.appending(path: folder), includingPropertiesForKeys: nil,
        )) ?? []
        return files.filter(SupportedFormats.isRaw).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The verified cameras' samples: the development fixtures and the camera coverage set.
    static let verified = raws(in: "tests/fixtures/raw") + raws(in: "tests/fixtures/cameras")
    static let canRender = (try? RedlampEngine()) != nil

    static func sample(_ name: String) -> URL? {
        verified.first { $0.lastPathComponent == name }
    }

    static func bench(_ fault: FaultyDecoder.Fault? = nil) throws -> CameraBench {
        let decoder: any ImageDecoding = fault.map { FaultyDecoder(fault: $0) } ?? InProcessDecoder()
        return try CameraBench(engine: RedlampEngine(decoder: decoder))
    }

    static func verdict(_ photo: CameraBenchPhoto, _ id: String) -> BenchVerdict? {
        photo.checks.first { $0.id == id }?.verdict
    }

    /// A sample's results through a decoder with `fault`.
    static func photo(_ name: String, _ fault: FaultyDecoder.Fault) async throws -> CameraBenchPhoto {
        let url = try #require(sample(name))
        let result = try await bench(fault).run(url)
        return try #require(result).photo
    }

    // MARK: - No false alarms

    @Test(.enabled(if: canRender && !verified.isEmpty), arguments: verified)
    func `no check fails on a verified camera's sample`(url: URL) async throws {
        let result = try #require(await Self.bench().run(url))
        let failed = result.photo.checks.filter { $0.verdict == .fail }.map { "\($0.id): \($0.summary)" }
        #expect(failed.isEmpty, "\(url.lastPathComponent): \(failed)")
        #expect(result.photo.fileHash.count == 64)
        #expect(result.photo.mode.key.hasPrefix(result.photo.identity.normalizedMake ?? "?"))
    }

    // MARK: - Faults, through the real decode and rendering

    static let faultSamples = ["_DSC0009.ARW", "Canon_EOS_R6_RAW_ISO_100_nocrop_nodual.CR3"]

    @Test(.enabled(if: canRender && sample(faultSamples[0]) != nil), arguments: faultSamples)
    func `a photo turned the wrong way is caught by the orientation check`(name: String) async throws {
        let photo = try await Self.photo(name, .turned)
        #expect(Self.verdict(photo, "preview.orientation") == .fail)
    }

    @Test(.enabled(if: canRender && sample(faultSamples[0]) != nil), arguments: faultSamples)
    func `a shifted CFA phase is caught by the cast check`(name: String) async throws {
        let photo = try await Self.photo(name, .cfaPhase)
        #expect(
            Self.verdict(photo, "preview.cast") == .fail,
            "\(photo.checks.map { "\($0.id) \($0.verdict) \($0.measurements)" })",
        )
    }

    @Test(.enabled(if: canRender && sample(faultSamples[0]) != nil), arguments: faultSamples)
    func `a black level stated too high is caught by the black check`(name: String) async throws {
        let photo = try await Self.photo(name, .blackRaised)
        #expect(Self.verdict(photo, "decode.black") == .fail)
    }

    @Test(.enabled(if: canRender && sample(faultSamples[0]) != nil), arguments: faultSamples)
    func `a white level stated too high is caught by the exposure check`(name: String) async throws {
        let photo = try await Self.photo(name, .whiteRaised)
        #expect(
            Self.verdict(photo, "preview.exposure") == .fail,
            "\(photo.checks.map { "\($0.id) \($0.measurements)" })",
        )
    }

    @Test(.enabled(if: canRender && sample(faultSamples[0]) != nil), arguments: faultSamples)
    func `a channel off by a third is caught by the cast check`(name: String) async throws {
        let photo = try await Self.photo(name, .channelCast)
        #expect(Self.verdict(photo, "preview.cast") == .fail, "\(photo.checks.map { "\($0.id) \($0.measurements)" })")
    }

    // MARK: - Decode checks on stated measurements

    static let healthy = DecodeMeasurements(
        black: 512, opticalBlack: 512.4, opticalBlackNoise: 1.6, darkPercentile: 509, nominalWhite: 16383, white: 16383,
        clippedShare: 0.002, darkEdges: DarkEdges(), colorMatrix: [
            0.74,
            -0.24,
            -0.06,
            -0.54,
            1.32,
            0.25,
            -0.1,
            0.18,
            0.66,
        ],
    )
    static let identity = RawFileIdentity(
        make: "Sony", model: "ILCE-7M3", normalizedMake: "Sony", normalizedModel: "ILCE-7M3", format: "ARW",
        decoder: "sony_arw2_load_raw", bitsPerSample: 14, sensor: "Bayer RGGB", rawSize: PixelSize(
            width: 6048,
            height: 4024,
        ),
        imageSize: PixelSize(width: 6024, height: 4024), iso: 100, asShotMultipliers: [2.2, 1, 1.75],
    )

    @Test func `healthy measurements pass every decode check`() {
        let checks = CameraBenchChecks.decode(Self.healthy, identity: Self.identity)
        #expect(checks.map(\.verdict) == [.pass, .pass, .pass, .pass])
    }

    @Test func `masked margins away from the stated black fail the black check`() {
        var measured = Self.healthy
        measured.opticalBlack = 540
        #expect(CameraBenchChecks.black(measured).verdict == .fail)
    }

    @Test func `a missing colour matrix fails the colour check`() {
        var measured = Self.healthy
        measured.colorMatrix = nil
        #expect(CameraBenchChecks.colour(measured, identity: Self.identity).verdict == .fail)
    }

    @Test func `a white level at the black level fails the white check`() {
        var measured = Self.healthy
        measured.white = 520
        #expect(CameraBenchChecks.white(measured).verdict == .fail)
    }

    @Test func `a dark strip fails the edge check`() {
        var measured = Self.healthy
        measured.darkEdges = DarkEdges(bottom: 24)
        let check = CameraBenchChecks.edges(measured)
        #expect(check.verdict == .fail)
        #expect(check.summary.contains("24 along the bottom"))
    }

    @Test func `a refused High Efficiency NEF names its tracker row`() {
        let identity = RawFileIdentity(make: "Nikon", model: "Z 8", format: "NEF", refusal: "Unsupported file format")
        let check = CameraBenchChecks.refused(identity, error: EngineError.unsupportedFile("DSC_0001.NEF"))
        #expect(check.verdict == .fail)
        #expect(check.tracker == "CAM-12")
    }

    // MARK: - Modes and choosing photos

    @Test func `a camera mode is its camera, decoder, bits and frame`() {
        let mode = CameraMode(identity: Self.identity)
        #expect(mode.key == "Sony|ILCE-7M3|sony_arw2_load_raw|14|6024x4024")
        #expect(mode.camera == "Sony ILCE-7M3")
        #expect(mode.label == "14-bit compressed ARW, 6024 × 4024")
    }

    @Test func `photos are chosen per mode, the conditions still needed first`() {
        func candidate(
            _ name: String,
            iso: Double,
            orientation: Int = 0,
            model: String = "ILCE-7M3",
        ) -> CameraBenchSelection.Candidate {
            var identity = Self.identity
            identity.iso = iso
            identity.orientation = orientation
            identity.model = model
            identity.normalizedModel = model
            return CameraBenchSelection.Candidate(url: URL(fileURLWithPath: "/photos/\(name).ARW"), identity: identity)
        }
        let candidates = (0 ..< 20).map { candidate("a\($0)", iso: 400) }
            + [
                candidate("high", iso: 6400),
                candidate("upright", iso: 400, orientation: 6),
                candidate("other", iso: 100, model: "ILCE-7M4"),
            ]
        let groups = CameraBenchSelection.choose(candidates, perMode: 3, needs: [
            CameraMode(identity: candidates[0].identity).key: [.highISO, .portrait],
        ])
        #expect(groups.count == 2)
        let a7iii = groups.first { $0.mode.camera == "Sony ILCE-7M3" }
        #expect(a7iii?.candidates == 22)
        #expect(a7iii?.chosen.count == 3)
        #expect(a7iii?.chosen.prefix(2).map(\.lastPathComponent) == ["high.ARW", "upright.ARW"])
    }

    @Test func `conditions follow the photo's ISO, orientation, clipping and light`() {
        var identity = Self.identity
        identity.iso = 6400
        identity.orientation = 5
        let met = BenchCondition.met(by: identity, measurements: Self.healthy, temperature: 3200)
        #expect(Set(met) == [.highISO, .portrait, .clippedHighlights, .warmLight])
    }
}

/// Decodes as LibRaw does, then introduces one fault, as a decoder bug would.
struct FaultyDecoder: ImageDecoding {
    enum Fault {
        /// The orientation a quarter turn off.
        case turned
        /// The colour filter pattern read one column off (RGGB as GRBG).
        case cfaPhase
        /// The black level stated 4% of the range too high.
        case blackRaised
        /// The white level stated three stops too high.
        case whiteRaised
        /// Green photosites a third too dark.
        case channelCast
    }

    let fault: Fault

    func decode(_ url: URL) throws -> DecodedImage {
        let image = try ImageDecoder.decode(url)
        guard case let .mosaic(pattern) = image.layout, pattern.width == 2 else { return image }
        var info = image.info
        var layout = image.layout
        var samples = image.samples
        var black = image.blackLevels
        var white = image.whiteLevel
        var orientation = image.orientation
        switch fault {
        case .turned:
            orientation = orientation == 6 ? 0 : 6
            let swapped = orientation == 5 || orientation == 6
            info.pixelSize = swapped ? PixelSize(width: image.height, height: image.width)
                : PixelSize(width: image.width, height: image.height)
        case .cfaPhase:
            let c = pattern.colors
            layout = .mosaic(CFAPattern(width: 2, height: 2, colors: [c[1], c[0], c[3], c[2]]))
            black = [black[1], black[0], black[3], black[2]]
        case .blackRaised:
            black = black.map { $0 + 0.04 * (white - $0) }
            info.diagnostics?.measurements.black = Double(black.reduce(0, +) / Float(black.count))
        case .whiteRaised:
            white *= 8
            info.diagnostics?.measurements.white = Double(white)
        case .channelCast:
            for y in 0 ..< image.height {
                for x in 0 ..< image.width where pattern.color(x: x, y: y) == 1 {
                    let index = y * image.width + x
                    let level = black[(y % 2) * 2 + x % 2]
                    samples[index] = UInt16(max(0, level + (Float(samples[index]) - level) * 0.67))
                }
            }
        }
        var faulty = DecodedImage(
            width: image.width, height: image.height, layout: layout, samples: samples, blackLevels: black,
            whiteLevel: white, asShotMultipliers: image.asShotMultipliers, cameraToSRGB: image.cameraToSRGB,
            xyzToCamera: image.xyzToCamera, orientation: orientation, baselineExposure: image.baselineExposure,
            info: info,
        )
        faulty.noiseProfile = image.noiseProfile
        faulty.gainMaps = image.gainMaps
        faulty.dngColor = image.dngColor
        faulty.dngProfile = image.dngProfile
        faulty.lensCorrection = image.lensCorrection
        faulty.banding = image.banding
        return faulty
    }
}
