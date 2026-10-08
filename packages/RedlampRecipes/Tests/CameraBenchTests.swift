import CoreGraphics
import Foundation
import RedlampEngine
import RedlampEngineAPI
import Synchronization
import Testing
@testable import RedlampRecipes
@testable import RedlampServices

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

    // MARK: - Through the decode service (DATA-17)

    /// A listener in this process that answers as the decode service does, through a real
    /// connection, counting the bench's own reads: identifying files and their camera previews.
    final class BenchService: NSObject, DecodeServiceProtocol, NSXPCListenerDelegate, @unchecked Sendable {
        let listener = NSXPCListener.anonymous()
        private let service = DecodeService()
        private let reads = Mutex(0)

        var benchReads: Int {
            reads.withLock { $0 }
        }

        override init() {
            super.init()
            listener.delegate = self
            listener.resume()
        }

        func listener(_: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
            connection.exportedInterface = NSXPCInterface(with: DecodeServiceProtocol.self)
            connection.exportedObject = self
            connection.resume()
            return true
        }

        func decode(_ file: Data, path: String, reply: @escaping @Sendable (Data?, Data?) -> Void) {
            service.decode(file, path: path, reply: reply)
        }

        func captures(
            _ files: [Data], paths: [String], concurrently: Bool, reply: @escaping @Sendable (Data?) -> Void,
        ) {
            service.captures(files, paths: paths, concurrently: concurrently, reply: reply)
        }

        func focusThumbnails(
            _ files: [Data], paths: [String], concurrently: Bool, reply: @escaping @Sendable (Data?) -> Void,
        ) {
            service.focusThumbnails(files, paths: paths, concurrently: concurrently, reply: reply)
        }

        func imageProperties(_ files: [Data], paths: [String], reply: @escaping @Sendable (Data?) -> Void) {
            service.imageProperties(files, paths: paths, reply: reply)
        }

        func haldImage(_ file: Data, path: String, reply: @escaping @Sendable (Data?, Int, Int) -> Void) {
            service.haldImage(file, path: path, reply: reply)
        }

        func rawIdentities(_ files: [Data], paths: [String], reply: @escaping @Sendable (Data?) -> Void) {
            reads.withLock { $0 += files.count }
            service.rawIdentities(files, paths: paths, reply: reply)
        }

        func cameraPreviews(
            _ files: [Data], paths: [String], maxLongEdge: Int, reply: @escaping @Sendable (Data?) -> Void,
        ) {
            reads.withLock { $0 += files.count }
            service.cameraPreviews(files, paths: paths, maxLongEdge: maxLongEdge, reply: reply)
        }
    }

    /// Previews in sRGB, Display P3 and an ICC profile of their own, and a camera that embeds none
    /// the bench can read.
    static let serviceSamples = [
        "_DSC0009.ARW",
        "IMG_1361.DNG",
        "Samsung_Galaxy-S23-Ultra.dng",
        "Canon_EOS-R5-Mark-II.CR3",
    ]

    static func untimed(_ photo: CameraBenchPhoto) -> CameraBenchPhoto {
        var photo = photo
        photo.decodeSeconds = nil
        photo.renderSeconds = nil
        return photo
    }

    /// An image's pixels drawn in sRGB, 8 bits a channel.
    static func pixels(_ image: CGImage?) -> [UInt8]? {
        guard let image, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(
            data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        )
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }

    @Test(.enabled(if: canRender && sample(serviceSamples[0]) != nil))
    func `the bench reports the same through the decode service as in the app`() async throws {
        let service = BenchService()
        let served = try CameraBench(engine: RedlampEngine(decoder: DecodeServiceClient(
            endpoint: service.listener.endpoint,
        )))
        let local = try Self.bench()
        let urls = Self.serviceSamples.compactMap(Self.sample)
        var reports: [[CameraBenchPhoto]] = [[], []]
        for url in urls {
            let ours = try #require(await local.run(url), "\(url.lastPathComponent)")
            let theirs = try #require(await served.run(url), "\(url.lastPathComponent)")
            reports[0].append(Self.untimed(ours.photo))
            reports[1].append(Self.untimed(theirs.photo))
            #expect(Self.pixels(theirs.theirs) == Self.pixels(ours.theirs), "\(url.lastPathComponent)")
        }
        let environment = local.environment(redlamp: "development", commit: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(CameraBenchReport(environment: environment, photos: reports[1]))
            == encoder.encode(CameraBenchReport(environment: environment, photos: reports[0])))
        #expect(service.benchReads >= 2 * urls.count)
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
        clippedShare: 0.002, zeroShare: 0.0001, darkEdges: DarkEdges(), colorMatrix: [
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

    @Test func `masked margins far from the stated black fail the black check, a little off warns`() {
        var measured = Self.healthy
        measured.opticalBlack = 700
        #expect(CameraBenchChecks.black(measured).verdict == .fail)
        measured.opticalBlack = 540
        #expect(CameraBenchChecks.black(measured).verdict == .warn)
    }

    @Test func `margins of padding far below the stated black aren't held against it`() {
        var measured = Self.healthy
        measured.opticalBlack = 0.5
        #expect(CameraBenchChecks.black(measured).verdict == .pass)
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

    @Test func `a strip the camera's JPEG is dark along too isn't a fault`() {
        var measured = Self.healthy
        measured.darkEdges = DarkEdges(top: 10)
        var identity = Self.identity
        identity.imageSize = PixelSize(width: 200, height: 100)
        /// A grey JPEG, black along one upright side.
        func camera(width: Int, height: Int, blackAt side: Int?) -> PixelImage {
            var image = PixelImage(
                width: width,
                height: height,
                pixels: Array(repeating: SIMD3(0.5, 0.5, 0.5), count: width * height),
            )
            for y in 0 ..< height {
                for x in 0 ..< width where side == 0 && y < 12 || side == 1 && x >= width - 12 {
                    image[x, y] = .zero
                }
            }
            return image
        }
        #expect(CameraBenchChecks.edges(
            measured,
            identity: identity,
            camera: camera(width: 200, height: 100, blackAt: 0),
        ).verdict == .pass)
        #expect(CameraBenchChecks.edges(
            measured,
            identity: identity,
            camera: camera(width: 200, height: 100, blackAt: nil),
        ).verdict == .fail)
        identity.orientation = 6
        #expect(CameraBenchChecks.edges(
            measured,
            identity: identity,
            camera: camera(width: 100, height: 200, blackAt: 1),
        ).verdict == .pass)
        #expect(CameraBenchChecks.edges(
            measured,
            identity: identity,
            camera: camera(width: 100, height: 200, blackAt: 0),
        ).verdict == .fail)
    }

    @Test(arguments: ["Z 8", "Z5_2", "Z50_2"])
    func `a refused High Efficiency NEF names its tracker row`(model: String) {
        let identity = RawFileIdentity(make: "Nikon", model: model, format: "NEF")
        let error = EngineError.notSupportedYet("Nikon's High Efficiency raw files (HE and HE*)", tracker: "CAM-12")
        let check = CameraBenchChecks.refused(identity, error: error)
        #expect(check.verdict == .fail)
        #expect(check.tracker == "CAM-12")
    }

    @Test func `a refused JPEG XL mosaic DNG names its tracker row`() {
        let identity = RawFileIdentity(make: "Samsung", model: "Galaxy S25 Ultra", format: "DNG")
        let error = EngineError.notSupportedYet("JPEG XL-compressed mosaic DNGs", tracker: "CAM-10")
        #expect(CameraBenchChecks.refused(identity, error: error).tracker == "CAM-10")
    }

    @Test func `a Nikon that won't open for another reason names no tracker row`() {
        let identity = RawFileIdentity(make: "Nikon", model: "Z 8", format: "NEF", refusal: "Unsupported file format")
        #expect(CameraBenchChecks.refused(identity, error: EngineError.unsupportedFile("DSC_0001.NEF")).tracker == nil)
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
/// Reads files as the CLI's engine does, so the bench identifies them and finds their previews.
extension FaultyDecoder: FileInspecting {
    func captures(of urls: [URL], concurrently: Bool) -> [CaptureSettings?] {
        InProcessDecoder().captures(of: urls, concurrently: concurrently)
    }

    func focusThumbnails(of urls: [URL], concurrently: Bool) -> [GreyThumbnail?] {
        InProcessDecoder().focusThumbnails(of: urls, concurrently: concurrently)
    }

    func imageProperties(of urls: [URL]) -> [ImageProperties?] {
        InProcessDecoder().imageProperties(of: urls)
    }

    func haldImage(of url: URL) -> HaldImage? {
        InProcessDecoder().haldImage(of: url)
    }

    func rawIdentities(of urls: [URL]) -> [RawFileIdentity?] {
        InProcessDecoder().rawIdentities(of: urls)
    }

    func cameraPreviews(of urls: [URL], maxLongEdge: Int) -> [CGImage?] {
        InProcessDecoder().cameraPreviews(of: urls, maxLongEdge: maxLongEdge)
    }
}

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
