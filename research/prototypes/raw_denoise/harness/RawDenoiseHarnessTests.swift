import Foundation
import Metal
import RedlampEngineAPI
import RedlampServices
import simd
import Testing
@testable import RedlampEngine

/// Renders mosaics prepared in Python (`research/prototypes/raw_denoise`) through the real session
/// builder (normalisation, hot photosites, highlights, demosaic) and detail stage, and writes balanced
/// camera RGB as float32. Runs only when `TEST_RUNNER_REDLAMP_RAWDN_DIR` names a folder holding
/// `jobs.json`; copy this file into `packages/RedlampEngine/Tests` while measuring, then remove it.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil
        && ProcessInfo.processInfo.environment["REDLAMP_RAWDN_DIR"] != nil))
struct RawDenoiseHarnessTests {
    struct Render: Decodable {
        var out: String
        /// Detail panel values by parameter ID suffix (`luminance`, `color`, `luminanceDetail`, ...).
        var settings: [String: Double] = [:]
        /// The edit's process version; absent, the latest.
        var process: Int?
    }

    struct Job: Decodable {
        var name: String
        /// Little-endian float32, one value per photosite (0 black, 1 white), before white balance.
        var mosaic: String
        var width: Int
        var height: Int
        /// Row-major colours of the CFA tile (0 red, 1 green, 2 blue), and its size.
        var cfa: [Int]
        var cfaWidth: Int
        var cfaHeight: Int
        /// Poisson–Gaussian noise per channel in normalised units, before white balance.
        var noiseA: [Float]
        var noiseB: [Float]
        var asShot: [Double] = [1, 1, 1]
        var demosaic: String = "menon"
        /// "markesteijn" or "generic"; absent before CAM-07.
        var xTrans: String?
        var dual: Bool = true
        var renders: [Render]
    }

    let detail: DetailStageTests

    init() throws {
        detail = try DetailStageTests()
    }

    @Test func `render the queued mosaics`() throws {
        let folder = try URL(fileURLWithPath: #require(ProcessInfo.processInfo.environment["REDLAMP_RAWDN_DIR"]))
        let jobs = try JSONDecoder().decode([Job].self, from: Data(contentsOf: folder.appending(path: "jobs.json")))
        var timings: [String] = []
        for job in jobs {
            let session = try makeSession(job, folder: folder)
            for render in job.renders {
                var recipe = DetailStageTests.unsharpened
                recipe.processVersion = render.process ?? EditRecipe.currentProcessVersion
                for (key, value) in render.settings {
                    let id = try #require(ParameterID(rawValue: "detail.noise.\(key)"), "unknown setting \(key)")
                    recipe[id] = value
                }
                let started = ContinuousClock.now
                let pixels = render.settings.values.contains(where: { $0 > 0 })
                    ? try detail.processed(session, recipe: recipe)
                    : try detail.readLevel(session, level: 0)
                timings.append("\(job.name) \(render.out) \(ContinuousClock.now - started)")
                var floats = [Float]()
                floats.reserveCapacity(pixels.count * 3)
                for pixel in pixels {
                    floats.append(pixel.x)
                    floats.append(pixel.y)
                    floats.append(pixel.z)
                }
                let destination = render.out.hasPrefix("/")
                    ? URL(fileURLWithPath: render.out) : folder.appending(path: render.out)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
                )
                try floats.withUnsafeBufferPointer { try Data(buffer: $0).write(to: destination) }
            }
        }
        try timings.joined(separator: "\n").write(
            to: folder.appending(path: "timings.txt"), atomically: true, encoding: .utf8,
        )
    }

    /// Black and white sit wide apart so that normalised values keep about 16 bits, with room below
    /// black for noise.
    private func makeSession(_ job: Job, folder: URL) throws -> ImageSession {
        let black: Float = 2048
        let white: Float = 65535
        let source = job.mosaic.hasPrefix("/") ? URL(fileURLWithPath: job.mosaic) : folder.appending(path: job.mosaic)
        let data = try Data(contentsOf: source)
        let values = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        try #require(values.count == job.width * job.height, "\(job.name): \(values.count) values")
        let samples = values.map { UInt16(min(max(black + $0 * (white - black), 0), 65535).rounded()) }
        var decoded = DecodedImage(
            width: job.width, height: job.height,
            layout: .mosaic(CFAPattern(width: job.cfaWidth, height: job.cfaHeight, colors: job.cfa.map { UInt8($0) })),
            samples: samples, blackLevels: [Float](repeating: black, count: job.cfaWidth * job.cfaHeight),
            whiteLevel: white,
            asShotMultipliers: SIMD3(job.asShot[0], job.asShot[1], job.asShot[2]),
            cameraToSRGB: [1, 0, 0, 0, 1, 0, 0, 0, 1], xyzToCamera: nil, orientation: 0, baselineExposure: 0,
            info: ImageInfo(
                url: URL(fileURLWithPath: "/\(job.name).dng"),
                pixelSize: PixelSize(width: job.width, height: job.height), isRaw: true,
                sensorDescription: "raw denoise harness",
            ),
        )
        decoded.noiseProfile = NoiseModel(
            a: SIMD3(job.noiseA[0], job.noiseA[1], job.noiseA[2]),
            b: SIMD3(job.noiseB[0], job.noiseB[1], job.noiseB[2]),
        )
        var builder = SessionBuilder(device: detail.device, queue: detail.queue, kernels: detail.kernels)
        builder.bayerDemosaic = job.demosaic == "malvar" ? .malvar : .menon
        builder.dualDemosaic = job.dual
        builder.xTransDemosaic = job.xTrans == "generic" ? .generic : .markesteijn
        return try builder.build(decoded)
    }
}
