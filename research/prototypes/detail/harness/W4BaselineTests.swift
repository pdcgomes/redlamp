import CoreGraphics
import Foundation
import ImageIO
import IOSurface
import Metal
import MetalPerformanceShaders
import RedlampEngineAPI
import RedlampKernels
import RedlampServices
import simd
import Testing
@testable import RedlampEngine

// Measurement harness for the detail decomposition (research/prototypes/detail/README.md).
// Copy into packages/RedlampEngine/Tests, run `tuist generate`, then
// TEST_RUNNER_W4_PART=timing,preview,halo,sweep,noise,dump xcodebuild test ...
// -only-testing:RedlampEngineTests/W4Baseline

@Suite(.serialized)
struct W4Baseline {
    static let parts = Set((ProcessInfo.processInfo.environment["W4_PART"] ?? "").split(separator: ",")
        .map(String.init))
    static let out = URL(fileURLWithPath: "/tmp/w4-detail")

    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let kernels: KernelLibrary

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        queue = try #require(device.makeCommandQueue())
        kernels = try KernelLibrary(device: device)
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
    }

    static func load() -> String {
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        return String(format: "load %.0f %.0f %.0f", loads[0], loads[1], loads[2])
    }

    static func write(_ values: [Float], _ name: String) throws {
        try values.withUnsafeBytes { Data($0) }.write(to: out.appending(path: name))
    }

    static func base() -> EditRecipe {
        var recipe = EditRecipe()
        recipe[.sharpenAmount] = 0
        recipe[.noiseColor] = 0
        return recipe
    }

    static func gradientMask(_ parameter: ParameterID, _ value: Double) -> MaskLayer {
        let gradient = LinearMask(start: ImagePoint(x: 0.3, y: 0.5), end: ImagePoint(x: 0.7, y: 0.5))
        return MaskLayer(
            name: "G",
            components: [MaskComponent(shape: .linear(gradient))],
            adjustments: [parameter: value],
        )
    }

    func nikonSession() throws -> ImageSession {
        let url = try #require(EngineSmokeTests.fixtures.first { $0.lastPathComponent == "DSC_0750.NEF" })
        return try SessionBuilder(device: device, queue: queue, kernels: kernels).build(ImageDecoder.decode(url))
    }

    // MARK: - GPU time per sub-stage

    @Test(.enabled(if: parts.contains("timing")))
    func timing() throws {
        let session = try nikonSession()
        let frame = session.orientedSize
        func centred(_ width: Int, _ height: Int) -> ImageRect {
            ImageRect(
                x: Double(frame.width - width) / 2 / Double(frame.width),
                y: Double(frame.height - height) / 2 / Double(frame.height),
                width: Double(width) / Double(frame.width), height: Double(height) / Double(frame.height),
            )
        }
        let views: [(String, ImageRect, PixelSize)] = [
            ("1:1 2560x1600", centred(2560, 1600), PixelSize(width: 2560, height: 1600)),
            ("fit 3900x2600 (level 0)", .full, frame.fitted(within: PixelSize(width: 3900, height: 2600))),
            ("fit 2400x1600 (level 1)", .full, frame.fitted(within: PixelSize(width: 2400, height: 1600))),
        ]
        typealias Case = (String, Bool, (Int) -> EditRecipe)
        let process = Int(ProcessInfo.processInfo.environment["W4_PROCESS"] ?? "") ?? EditRecipe.currentProcessVersion
        func edit(_ change: (inout EditRecipe) -> Void) -> EditRecipe {
            var r = EditRecipe()
            r.processVersion = process
            change(&r)
            return r
        }
        let cases: [Case] = [
            ("Default edit, uncached", false, { _ in edit { _ in } }),
            ("Heavy: NR L50, Texture 50, Clarity 50, mask, uncached", false, { _ in edit { r in
                r[.noiseLuminance] = 50; r[.texture] = 50; r[.clarity] = 50
                r.masks = [Self.gradientMask(.localTexture, 50)]
            } }),
            ("Texture drag", true, { step in edit { $0[.texture] = Double(20 + step) } }),
            (
                "Texture drag, NR L50",
                true,
                { step in edit { $0[.noiseLuminance] = 50; $0[.texture] = Double(20 + step) } },
            ),
            ("Clarity drag", true, { step in edit { $0[.clarity] = Double(20 + step) } }),
            ("Amount drag", true, { step in edit { $0[.sharpenAmount] = Double(40 + step) } }),
            ("Masking drag", true, { step in edit { $0[.sharpenMasking] = Double(10 + step) } }),
            ("Radius drag", true, { step in edit { $0[.sharpenRadius] = 1 + 0.05 * Double(step) } }),
            ("Luminance drag", true, { step in edit { $0[.noiseLuminance] = Double(20 + step) } }),
        ]
        var lines = ["start \(Self.load())"]
        for (viewName, region, size) in views {
            let work = DetailStage.workArea(
                session: session,
                geometry: GeometryMap(recipe: EditRecipe(), imageSize: frame, lens: session.info.lensCorrection),
                region: region, outputSize: size,
            )
            lines
                .append(
                    "process \(process), \(viewName): work level \(work.level), \(work.size.x)x\(work.size.y) texels",
                )
            for (label, cache, recipe) in cases {
                let stage = DetailStage(device: device, kernels: kernels)
                var buffers: [any MTLCommandBuffer] = []
                for step in 0 ..< 24 {
                    if buffers.count >= 3 {
                        buffers[buffers.count - 3].waitUntilCompleted()
                    }
                    let commands = try #require(queue.makeCommandBuffer())
                    _ = try stage.process(
                        recipe(step), session: session, region: region, outputSize: size, commands: commands,
                        cache: cache,
                    )
                    commands.commit()
                    buffers.append(commands)
                }
                buffers.last?.waitUntilCompleted()
                let times = buffers.dropFirst(8).map { ($0.gpuEndTime - $0.gpuStartTime) * 1000 }.sorted()
                lines.append(String(
                    format: "  %@: median %.2f ms, min %.2f, p90 %.2f, %d MB held, %d tiles  (%@)", label,
                    times[times.count / 2], times[0], times[Int(Double(times.count) * 0.9)],
                    stage.heldTextures.reduce(0) { $0 + $1.allocatedSize } >> 20, stage.tileCount, Self.load(),
                ))
                try print(#require(lines.last))
            }
        }
        lines.append("end \(Self.load())")
        try lines.joined(separator: "\n").write(
            to: Self.out.appending(path: "timing.txt"),
            atomically: true,
            encoding: .utf8,
        )
        print(lines.joined(separator: "\n"))
    }

    // MARK: - Preview against export (ARC-04)

    private static let decode: [Double] = (0 ..< 256).map { value in
        let c = Double(value) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        0.2290 * r + 0.6917 * g + 0.0793 * b
    }

    @Test(.enabled(if: parts.contains("preview")))
    func `preview against export`() async throws {
        let url = try #require(EngineSmokeTests.fixtures.first { $0.lastPathComponent == "DSC_0750.NEF" })
        let engine = try RedlampEngine()
        _ = try await engine.open(url)
        let frames = engine.frames()
        var iterator = frames.makeAsyncIterator()
        var generation: UInt64 = 0
        var lines = ["start \(Self.load())"]

        func preview(_ recipe: EditRecipe, _ edge: Int) async throws -> (values: [Double], width: Int, height: Int) {
            generation += 1
            engine.render(RenderRequest(
                recipe: recipe,
                targetSize: PixelSize(width: edge, height: edge),
                generation: generation,
            ))
            var frame = try #require(await iterator.next())
            while frame.generation != generation {
                frame = try #require(await iterator.next())
            }
            let surface = frame.surface
            IOSurfaceLock(surface, .readOnly, nil)
            defer { IOSurfaceUnlock(surface, .readOnly, nil) }
            let base = IOSurfaceGetBaseAddress(surface)
            let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
            let values = (0 ..< frame.size.height).flatMap { y in
                let row = (base + y * bytesPerRow).assumingMemoryBound(to: Float16.self)
                return (0 ..< frame.size.width).map { x in
                    Self.luminance(Double(row[x * 4]), Double(row[x * 4 + 1]), Double(row[x * 4 + 2]))
                }
            }
            return (values, frame.size.width, frame.size.height)
        }

        let sixteen = ProcessInfo.processInfo.environment["W4_BITS"] == "16"
        func export(_ recipe: EditRecipe, _ edge: Int) async throws -> [Double] {
            let image = try await engine.renderStill(StillRequest(
                recipe: recipe, maxLongEdge: edge, colorSpace: .displayP3, bitsPerComponent: sixteen ? 16 : 8,
                purpose: .export,
            ))
            let data = try #require(image.dataProvider?.data) as Data
            if sixteen {
                return data.withUnsafeBytes { raw in
                    let words = raw.bindMemory(to: UInt16.self)
                    func decode(_ v: UInt16) -> Double {
                        let c = Double(v) / 65535
                        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
                    }
                    return (0 ..< image.height).flatMap { y in
                        (0 ..< image.width).map { x in
                            let offset = (y * image.bytesPerRow) / 2 + x * 4
                            return Self.luminance(
                                decode(words[offset]),
                                decode(words[offset + 1]),
                                decode(words[offset + 2]),
                            )
                        }
                    }
                }
            }
            let bytes = [UInt8](data)
            let bytesPerPixel = image.bitsPerPixel / 8
            return (0 ..< image.height).flatMap { y in
                (0 ..< image.width).map { x in
                    let offset = y * image.bytesPerRow + x * bytesPerPixel
                    return Self.luminance(
                        Self.decode[Int(bytes[offset])], Self.decode[Int(bytes[offset + 1])],
                        Self.decode[Int(bytes[offset + 2])],
                    )
                }
            }
        }

        let cases: [(String, ParameterID, Double)] = [
            ("Texture", .texture, 60), ("Texture", .texture, -60), ("Texture", .texture, 100),
            ("Clarity", .clarity, 60), ("Sharpening", .sharpenAmount, 100),
        ]
        let plain = ProcessInfo.processInfo.environment["W4_PLAIN"] == "1"
        func start() -> EditRecipe {
            var recipe = EditRecipe()
            if plain {
                recipe[.noiseColor] = 0; recipe[.sharpenAmount] = 0; recipe[.texture] = 0.01
            }
            if ProcessInfo.processInfo.environment["W4_NOLENS"] == "1" {
                recipe[.lensProfile] = 0
            }
            return recipe
        }
        for edge in [700, 1000, 2000] {
            let previewBase = try await preview(start(), edge)
            let exportBase = try await export(start(), edge)
            try Self.write(previewBase.values.map(Float.init), "arc04_base_preview_\(edge).f32")
            try Self.write(exportBase.map(Float.init), "arc04_base_export_\(edge).f32")
            for (name, parameter, value) in cases {
                var edited = start()
                edited[parameter] = value
                let previewEdited = try await preview(edited, edge)
                let exportEdited = try await export(edited, edge)
                try #require(previewBase.values.count == exportBase.count)
                try Self.write(previewEdited.values.map(Float.init), "arc04_\(name)\(Int(value))_preview_\(edge).f32")
                try Self.write(exportEdited.map(Float.init), "arc04_\(name)\(Int(value))_export_\(edge).f32")
                var previewEnergy = 0.0, exportEnergy = 0.0, cross = 0.0
                for index in previewBase.values.indices {
                    let shown = previewEdited.values[index] - previewBase.values[index]
                    let exported = exportEdited[index] - exportBase[index]
                    previewEnergy += shown * shown
                    exportEnergy += exported * exported
                    cross += shown * exported
                }
                let ratio = (previewEnergy / exportEnergy).squareRoot()
                let correlation = cross / (previewEnergy * exportEnergy).squareRoot()
                lines.append(String(
                    format: "%@ %+.0f at %d px (%dx%d): preview/export %.3f, correlation %.3f (%@)", name, value, edge,
                    previewBase.width, previewBase.height, ratio, correlation, Self.load(),
                ))
                try print(#require(lines.last))
            }
        }
        try lines.joined(separator: "\n").write(
            to: Self.out.appending(path: "preview.txt"),
            atomically: true,
            encoding: .utf8,
        )
    }

    // MARK: - Synthetic scenes through the stage

    /// Rec. 2020 luminance of each pixel, averaged over rows `rows`, per column.
    static func profile(_ pixels: [SIMD3<Float>], width: Int, rows: Range<Int>, luma: SIMD4<Float>) -> [Float] {
        (0 ..< width).map { x in
            rows.map { y in max(simd_dot(pixels[y * width + x], SIMD3(luma.x, luma.y, luma.z)), 1e-6) }
                .reduce(0, +) / Float(rows.count)
        }
    }

    /// The stage's output at pyramid level `level` (region full, output size the level's).
    func render(
        _ helper: DetailStageTests,
        _ session: ImageSession,
        _ recipe: EditRecipe,
        level: Int,
    ) throws -> [SIMD3<Float>] {
        let stage = DetailStage(device: device, kernels: kernels)
        let commands = try #require(queue.makeCommandBuffer())
        let width = max(1, session.pyramid.width >> level), height = max(1, session.pyramid.height >> level)
        let size = level == 0 ? session.orientedSize : PixelSize(width: width, height: height)
        guard let output = try stage.process(
            recipe, session: session, region: .full, outputSize: size, commands: commands, cache: false,
        ) else {
            return try helper.readLevel(session, level: level)
        }
        commands.commit()
        commands.waitUntilCompleted()
        try #require(output.texture.width == width && output.texture.height == height, "work \(output.texture.width)")
        return try helper.readBack(output.texture, level: 0, width: width, height: height)
    }

    nonisolated(unsafe) static let settings: [(String, (inout EditRecipe) -> Void)] = [
        ("Texture +100", { $0[.texture] = 100 }),
        ("Texture -100", { $0[.texture] = -100 }),
        ("Clarity +100 (p9)", { $0[.clarity] = 100 }),
        ("Clarity +100 (p8)", { $0.processVersion = 8; $0[.clarity] = 100 }),
        ("Sharpening 100 (R1 D25)", { $0[.sharpenAmount] = 100 }),
        ("Sharpening 150 (R1 D25)", { $0[.sharpenAmount] = 150 }),
        ("Sharpening 100 (R1 D100)", { $0[.sharpenAmount] = 100; $0[.sharpenDetail] = 100 }),
        ("Sharpening 100 (R2 D25)", { $0[.sharpenAmount] = 100; $0[.sharpenRadius] = 2 }),
    ]

    @Test(.enabled(if: parts.contains("halo")))
    func halos() throws {
        let helper = try DetailStageTests()
        let width = 1024, edge = 512, rows = 24 ..< 40
        let dark = 0.04, bright = 0.4
        func soft(_ x: Int, sigma: Double) -> Double {
            let t = Double(x) + 0.5 - Double(edge)
            return 0.5 * (1 + erf(t / (sigma * 2.0.squareRoot())))
        }
        let scenes: [(String, (Int, Int) -> Float)] = [
            ("hard step 3.3 stops", { x, _ in Float(x < edge ? dark : bright) }),
            ("soft step 3.3 stops (sigma 1.2)", { x, _ in Float(dark + (bright - dark) * soft(x, sigma: 1.2)) }),
            ("hard step 1 stop", { x, _ in Float(x < edge ? 0.1 : 0.2) }),
            ("bright line 2 px, 3.3 stops", { x, _ in Float(x == edge || x == edge + 1 ? bright : dark) }),
        ]
        var json: [[String: Any]] = []
        var lines: [String] = []
        for (sceneName, signal) in scenes {
            let session = try helper.makeSession(.bayer, width: width, height: 64, noiseScale: 0, signal: signal)
            let luma = DetailStage.luma(session)
            let before = try Self.profile(helper.readLevel(session, level: 0), width: width, rows: rows, luma: luma)
            for (settingName, change) in Self.settings {
                var recipe = DetailStageTests.untouched
                change(&recipe)
                let after = try Self.profile(
                    render(helper, session, recipe, level: 0),
                    width: width,
                    rows: rows,
                    luma: luma,
                )
                let delta = zip(after, before).map { log2($0) - log2($1) }
                let far = (edge - 200 ..< edge - 120).map { delta[$0] }.reduce(0, +) / 80
                let farBright = (edge + 120 ..< edge + 200).map { delta[$0] }.reduce(0, +) / 80
                let darkSide = (edge - 48 ..< edge - 1).map { delta[$0] - far }
                let brightSide = (edge + 2 ..< edge + 48).map { delta[$0] - farBright }
                let darkPeak = darkSide.min() ?? 0, brightPeak = brightSide.max() ?? 0
                let darkWidth = (darkSide.firstIndex { abs($0) > 0.02 }).map { 48 - $0 } ?? 0
                let brightWidth = (brightSide.lastIndex { abs($0) > 0.02 }).map { $0 + 3 } ?? 0
                let darkBand = (edge - 16 ..< edge - 2).map { delta[$0] - far }.reduce(0, +) / 14
                let brightBand = (edge + 3 ..< edge + 17).map { delta[$0] - farBright }.reduce(0, +) / 14
                lines.append(String(
                    format: "%@ | %@: dark peak %+.3f, width %d px, band %+.3f | bright peak %+.3f, width %d px, band %+.3f",
                    sceneName, settingName, darkPeak, darkWidth, darkBand, brightPeak, brightWidth, brightBand,
                ))
                try print(#require(lines.last))
                json.append([
                    "scene": sceneName, "setting": settingName,
                    "x": Array(edge - 48 ..< edge + 48),
                    "before": (edge - 48 ..< edge + 48).map { Double(log2(before[$0])) },
                    "delta": (edge - 48 ..< edge + 48).map { Double(delta[$0]) },
                ])
            }
        }
        try JSONSerialization.data(withJSONObject: json).write(to: Self.out.appending(path: "halo.json"))
        try lines.joined(separator: "\n").write(
            to: Self.out.appending(path: "halo.txt"),
            atomically: true,
            encoding: .utf8,
        )
    }

    // MARK: - Band responses: gain on stripes by period, at levels 0 to 3

    @Test(.enabled(if: parts.contains("sweep")))
    func `band sweep`() throws {
        let helper = try DetailStageTests()
        let width = 2048, rows = 24 ..< 40
        let amplitude = 0.05
        var lines: [String] = []
        var json: [[String: Any]] = []
        for period in [3.0, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128, 192, 256] {
            let session = try helper.makeSession(.bayer, width: width, height: 64, noiseScale: 0) { x, _ in
                Float(0.2 * pow(2, amplitude * sin(2 * .pi * Double(x) / period)))
            }
            let luma = DetailStage.luma(session)
            for level in 0 ... 3 where period >= 2 * Double(1 << level) {
                let levelWidth = width >> level
                let levelRows = (rows.lowerBound >> level) ..< max(
                    rows.upperBound >> level,
                    (rows.lowerBound >> level) + 1,
                )
                let input = try Self.profile(
                    helper.readLevel(session, level: level),
                    width: levelWidth,
                    rows: levelRows,
                    luma: luma,
                )
                func spread(_ values: [Float]) -> Float {
                    let logs = (levelWidth / 8 ..< levelWidth * 7 / 8).map { log2(values[$0]) }
                    let mean = logs.reduce(0, +) / Float(logs.count)
                    return (logs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(logs.count)).squareRoot()
                }
                let reference = spread(input)
                for (settingName, change) in Self.settings {
                    var recipe = DetailStageTests.untouched
                    change(&recipe)
                    let output = try render(helper, session, recipe, level: level)
                    let gain = spread(Self.profile(output, width: levelWidth, rows: levelRows, luma: luma)) / reference
                    lines.append(String(
                        format: "period %5.0f px, level %d, %@: gain %.3f (input %.4f stops rms)",
                        period,
                        level,
                        settingName,
                        gain,
                        reference,
                    ))
                    json.append([
                        "period": period,
                        "level": level,
                        "setting": settingName,
                        "gain": Double(gain),
                        "input": Double(reference),
                    ])
                }
            }
            print("period \(period) done")
        }
        try JSONSerialization.data(withJSONObject: json).write(to: Self.out.appending(path: "sweep.json"))
        try lines.joined(separator: "\n").write(
            to: Self.out.appending(path: "sweep.txt"),
            atomically: true,
            encoding: .utf8,
        )
    }

    /// Sharpening's response by period, with a near-noiseless model so the separator keeps the stripes.
    @Test(.enabled(if: parts.contains("sweepsharpen")))
    func `sharpen sweep`() throws {
        let helper = try DetailStageTests()
        let width = 2048, rows = 24 ..< 40
        let quiet = NoiseModel(a: SIMD3(repeating: 1e-9), b: SIMD3(repeating: 1e-11))
        var lines: [String] = []
        var json: [[String: Any]] = []
        for period in [3.0, 4, 6, 8, 12, 16, 24, 32, 48] {
            let session = try helper
                .makeSession(.bayer, width: width, height: 64, noiseScale: 0, profile: quiet) { x, _ in
                    Float(0.2 * pow(2, 0.05 * sin(2 * .pi * Double(x) / period)))
                }
            let luma = DetailStage.luma(session)
            for level in 0 ... 2 where period >= 2 * Double(1 << level) {
                let levelWidth = width >> level
                let levelRows = (rows.lowerBound >> level) ..< (rows.upperBound >> level)
                let input = try Self.profile(
                    helper.readLevel(session, level: level),
                    width: levelWidth,
                    rows: levelRows,
                    luma: luma,
                )
                func spread(_ values: [Float]) -> Float {
                    let logs = (levelWidth / 8 ..< levelWidth * 7 / 8).map { log2(values[$0]) }
                    let mean = logs.reduce(0, +) / Float(logs.count)
                    return (logs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(logs.count)).squareRoot()
                }
                for (settingName, change) in Self.settings where settingName.hasPrefix("Sharpening") {
                    var recipe = DetailStageTests.untouched
                    change(&recipe)
                    let output = try render(helper, session, recipe, level: level)
                    let gain = spread(Self.profile(output, width: levelWidth, rows: levelRows, luma: luma)) /
                        spread(input)
                    lines.append(String(
                        format: "period %5.0f px, level %d, %@: gain %.3f",
                        period,
                        level,
                        settingName,
                        gain,
                    ))
                    json.append(["period": period, "level": level, "setting": settingName, "gain": Double(gain)])
                }
            }
        }
        try JSONSerialization.data(withJSONObject: json).write(to: Self.out.appending(path: "sweep_sharpen.json"))
        try lines.joined(separator: "\n").write(
            to: Self.out.appending(path: "sweep_sharpen.txt"),
            atomically: true,
            encoding: .utf8,
        )
    }

    // MARK: - Noise with Texture after noise reduction

    @Test(.enabled(if: parts.contains("noise")))
    func `noise with texture`() throws {
        let helper = try DetailStageTests()
        let session = try helper.makeSession(.bayer, width: 1024, height: 768)
        let luma = DetailStage.luma(session)
        var lines: [String] = []
        let cases: [(String, (inout EditRecipe) -> Void)] = [
            ("NR off, Texture 0", { $0[.noiseColor] = 0 }),
            ("NR off, Texture +100", { $0[.noiseColor] = 0; $0[.texture] = 100 }),
            ("NR L60 C25", { $0[.noiseLuminance] = 60; $0[.noiseColor] = 25 }),
            ("NR L60 C25, Texture +100", { $0[.noiseLuminance] = 60; $0[.noiseColor] = 25; $0[.texture] = 100 }),
            ("NR L60 C25, Texture +50", { $0[.noiseLuminance] = 60; $0[.noiseColor] = 25; $0[.texture] = 50 }),
            ("NR L60 C25, Texture -100", { $0[.noiseLuminance] = 60; $0[.noiseColor] = 25; $0[.texture] = -100 }),
            ("NR L60 C25, Clarity +100", { $0[.noiseLuminance] = 60; $0[.noiseColor] = 25; $0[.clarity] = 100 }),
            (
                "NR L60 C25, Sharpening 100",
                { $0[.noiseLuminance] = 60; $0[.noiseColor] = 25; $0[.sharpenAmount] = 100 },
            ),
        ]
        for level in 0 ... 2 {
            let width = 1024 >> level, height = 768 >> level
            let input = try helper.readLevel(session, level: level)
            func deviation(_ pixels: [SIMD3<Float>]) -> Float {
                let margin = 64 >> level
                let values = (margin ..< height - margin).flatMap { y in
                    (margin ..< width - margin)
                        .map { x in simd_dot(pixels[y * width + x], SIMD3(luma.x, luma.y, luma.z)) }
                }
                let mean = values.reduce(0, +) / Float(values.count)
                return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(values.count)).squareRoot() / mean
            }
            lines.append(String(format: "level %d: input noise %.4f (relative)", level, deviation(input)))
            for (name, change) in cases {
                var recipe = DetailStageTests.untouched
                change(&recipe)
                let output = try render(helper, session, recipe, level: level)
                lines.append(String(format: "level %d, %@: noise %.4f", level, name, deviation(output)))
                try print(#require(lines.last))
            }
        }
        try lines.joined(separator: "\n").write(
            to: Self.out.appending(path: "noise.txt"),
            atomically: true,
            encoding: .utf8,
        )
    }

    /// MPSImageLanczosScale on single-channel float images written by the prototype (name_W_H.f32 ->
    /// name_mps<edge>.f32), to compare the export's downscaler with the simulator's.
    @Test(.enabled(if: parts.contains("mps")))
    func `mps lanczos`() throws {
        let names = (ProcessInfo.processInfo.environment["W4_MPS"] ?? "").split(separator: ",").map(String.init)
        for name in names {
            let parts = name.split(separator: "_").suffix(2).compactMap { Int($0) }
            let (width, height) = (parts[0], parts[1])
            let data = try Data(contentsOf: Self.out.appending(path: "\(name).f32"))
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r32Float,
                width: width,
                height: height,
                mipmapped: false,
            )
            descriptor.usage = [.shaderRead, .shaderWrite]
            let source = try #require(device.makeTexture(descriptor: descriptor))
            data.withUnsafeBytes { source.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: $0.baseAddress!,
                bytesPerRow: width * 4,
            ) }
            for edge in [700, 1000, 2000] {
                let size = PixelSize(width: width, height: height).fitted(within: PixelSize(width: edge, height: edge))
                let out = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .r32Float,
                    width: size.width,
                    height: size.height,
                    mipmapped: false,
                )
                out.usage = [.shaderRead, .shaderWrite]
                let target = try #require(device.makeTexture(descriptor: out))
                let commands = try #require(queue.makeCommandBuffer())
                MPSImageLanczosScale(device: device).encode(
                    commandBuffer: commands,
                    sourceTexture: source,
                    destinationTexture: target,
                )
                commands.commit()
                commands.waitUntilCompleted()
                var values = [Float](repeating: 0, count: size.width * size.height)
                values.withUnsafeMutableBytes { target.getBytes(
                    $0.baseAddress!,
                    bytesPerRow: size.width * 4,
                    from: MTLRegionMake2D(0, 0, size.width, size.height),
                    mipmapLevel: 0,
                ) }
                try Self.write(values, "\(name)_mps\(edge).f32")
            }
        }
    }

    /// Noisy flat and striped fields: level 0 and the stage's output with NR L60 C25 (and with Texture +100).
    @Test(.enabled(if: parts.contains("noisedump")))
    func `noise dumps`() throws {
        let helper = try DetailStageTests()
        let scenes: [(String, (Int, Int) -> Float)] = [
            ("nflat", { _, _ in 0.1 }),
            ("nstripes", { x, _ in Float(0.1 * pow(2, 0.1 * sin(2 * .pi * Double(x) / 12))) }),
        ]
        for (name, signal) in scenes {
            let session = try helper.makeSession(.bayer, width: 1024, height: 768, signal: signal)
            let luma = DetailStage.luma(session)
            func y(_ pixels: [SIMD3<Float>]) -> [Float] {
                pixels.map { simd_dot($0, SIMD3(luma.x, luma.y, luma.z)) }
            }
            try Self.write(y(helper.readLevel(session, level: 0)), "\(name)_in_Y.f32")
            var recipe = DetailStageTests.untouched
            recipe[.noiseLuminance] = 60
            recipe[.noiseColor] = 25
            try Self.write(y(render(helper, session, recipe, level: 0)), "\(name)_nr_Y.f32")
            recipe[.texture] = 100
            try Self.write(y(render(helper, session, recipe, level: 0)), "\(name)_nrtex_Y.f32")
            let meta: [String: Any] = [
                "width": 1024, "height": 768, "luma": [luma.x, luma.y, luma.z, luma.w],
                "a": [session.noise.a.x, session.noise.a.y, session.noise.a.z],
                "b": [session.noise.b.x, session.noise.b.y, session.noise.b.z],
            ]
            try JSONSerialization.data(withJSONObject: meta).write(to: Self.out.appending(path: "\(name)_meta.json"))
        }
    }

    /// GPU time of a prototype ladder (4 B3 à-trous scales of linear luminance, single channel) and of
    /// an apply pass that reads it, on work areas of the timing views' sizes.
    @Test(.enabled(if: parts.contains("ladder")))
    func `ladder cost`() throws {
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        constant float kB3[5] = {1.0f / 16.0f, 4.0f / 16.0f, 6.0f / 16.0f, 4.0f / 16.0f, 1.0f / 16.0f};
        kernel void rows(texture2d<half, access::read> src [[texture(0)]], texture2d<half, access::write> dst [[texture(1)]],
                         texture2d<half, access::read> rgb [[texture(2)]], constant int2 &p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
            int2 size = int2(dst.get_width(), dst.get_height());
            if (int(gid.x) >= size.x || int(gid.y) >= size.y) return;
            float sum = 0.0f;
            for (int i = -2; i <= 2; i++) {
                uint2 at = uint2(clamp(int(gid.x) + i * p.x, 0, size.x - 1), gid.y);
                float v = p.y != 0 ? dot(float3(rgb.read(at).rgb), float3(0.2627f, 0.678f, 0.0593f)) : float(src.read(at).r);
                sum += kB3[i + 2] * v;
            }
            dst.write(half4(half(sum)), gid);
        }
        kernel void columns(texture2d<half, access::read> rowsT [[texture(0)]], texture2d<half, access::read> cur [[texture(1)]],
                            texture2d<half, access::write> next [[texture(2)]], texture2d<half, access::read_write> bands [[texture(3)]],
                            texture2d<half, access::read> rgb [[texture(4)]], constant int2 &p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
            int2 size = int2(next.get_width(), next.get_height());
            if (int(gid.x) >= size.x || int(gid.y) >= size.y) return;
            float sum = 0.0f;
            for (int i = -2; i <= 2; i++) sum += kB3[i + 2] * float(rowsT.read(uint2(gid.x, clamp(int(gid.y) + i * p.x, 0, size.y - 1))).r);
            float here = p.y != 0 ? dot(float3(rgb.read(gid).rgb), float3(0.2627f, 0.678f, 0.0593f)) : float(cur.read(gid).r);
            half4 b = p.y != 0 ? half4(0.0h) : bands.read(gid);
            int scale = int(log2(float(p.x)));
            b[scale] = half(here - sum);
            bands.write(b, gid);
            next.write(half4(half(sum)), gid);
        }
        kernel void apply(texture2d<half, access::read> rgb [[texture(0)]], texture2d<half, access::read> bands [[texture(1)]],
                          texture2d<half, access::read> residual [[texture(2)]], texture2d<half, access::write> out [[texture(3)]],
                          uint2 gid [[thread_position_in_grid]]) {
            int2 size = int2(out.get_width(), out.get_height());
            if (int(gid.x) >= size.x || int(gid.y) >= size.y) return;
            float4 w = float4(bands.read(gid));
            float c4 = float(residual.read(gid).r);
            float c3 = c4 + w.w, c1 = c3 + w.z + w.y;
            float texture = 0.25f * tanh((log2(c1 + 0.001f) - log2(c3 + 0.001f)) / 0.25f);
            float clarity = 0.5f * tanh((log2(c3 + 0.001f) - log2(c4 + 0.001f)) / 0.5f);
            float3 c = float3(rgb.read(gid).rgb);
            out.write(half4(half3(c * exp2(0.6f * texture + 0.4f * clarity)), 1.0h), gid);
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        let rowsPipeline = try device.makeComputePipelineState(function: #require(library.makeFunction(name: "rows")))
        let columnsPipeline = try device
            .makeComputePipelineState(function: #require(library.makeFunction(name: "columns")))
        let applyPipeline = try device.makeComputePipelineState(function: #require(library.makeFunction(name: "apply")))
        var lines = ["start \(Self.load())"]
        for (label, width, height) in [
            ("1:1 2560x1600", 2689, 1728),
            ("fit level 0", 6064, 4040),
            ("fit level 1", 3032, 2020),
        ] {
            func texture(_ format: MTLPixelFormat) throws -> any MTLTexture {
                let d = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: format,
                    width: width,
                    height: height,
                    mipmapped: false,
                )
                d.usage = [.shaderRead, .shaderWrite]
                d.storageMode = .private
                return try #require(device.makeTexture(descriptor: d))
            }
            let rgb = try texture(.rgba16Float), rowsT = try texture(.r16Float), a = try texture(.r16Float),
                b = try texture(.r16Float)
            let bands = try texture(.rgba16Float), out = try texture(.rgba16Float)
            func encodeLadder(_ encoder: any MTLComputeCommandEncoder) {
                var current = a, next = b
                for scale in 0 ..< 4 {
                    var p = SIMD2<Int32>(Int32(1 << scale), scale == 0 ? 1 : 0)
                    encoder.setComputePipelineState(rowsPipeline)
                    encoder.setTexture(current, index: 0); encoder.setTexture(rowsT, index: 1); encoder.setTexture(
                        rgb,
                        index: 2,
                    )
                    encoder.setBytes(&p, length: 8, index: 0)
                    encoder.dispatchThreads(
                        MTLSize(width: width, height: height, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1),
                    )
                    encoder.setComputePipelineState(columnsPipeline)
                    encoder.setTexture(rowsT, index: 0); encoder.setTexture(current, index: 1); encoder.setTexture(
                        next,
                        index: 2,
                    )
                    encoder.setTexture(bands, index: 3); encoder.setTexture(rgb, index: 4)
                    encoder.setBytes(&p, length: 8, index: 0)
                    encoder.dispatchThreads(
                        MTLSize(width: width, height: height, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1),
                    )
                    swap(&current, &next)
                }
            }
            func median(_ encode: (any MTLComputeCommandEncoder) -> Void) throws -> Double {
                var buffers: [any MTLCommandBuffer] = []
                for _ in 0 ..< 24 {
                    if buffers.count >= 3 {
                        buffers[buffers.count - 3].waitUntilCompleted()
                    }
                    let commands = try #require(queue.makeCommandBuffer())
                    let encoder = try #require(commands.makeComputeCommandEncoder())
                    encode(encoder)
                    encoder.endEncoding()
                    commands.commit()
                    buffers.append(commands)
                }
                buffers.last?.waitUntilCompleted()
                let times = buffers.dropFirst(8).map { ($0.gpuEndTime - $0.gpuStartTime) * 1000 }.sorted()
                return times[times.count / 2]
            }
            let ladder = try median(encodeLadder)
            let apply = try median { encoder in
                encoder.setComputePipelineState(applyPipeline)
                encoder.setTexture(rgb, index: 0); encoder.setTexture(bands, index: 1); encoder.setTexture(
                    a,
                    index: 2,
                ); encoder.setTexture(out, index: 3)
                encoder.dispatchThreads(
                    MTLSize(width: width, height: height, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1),
                )
            }
            lines.append(String(
                format: "%@ (%dx%d): ladder (4 scales) median %.2f ms, apply %.2f ms (%@)",
                label,
                width,
                height,
                ladder,
                apply,
                Self.load(),
            ))
            try print(#require(lines.last))
        }
        try lines.joined(separator: "\n").write(
            to: Self.out.appending(path: "ladder.txt"),
            atomically: true,
            encoding: .utf8,
        )
    }

    // MARK: - Dumps for the Python prototype

    /// Level 0 of each photo in W4_DUMP (or the Nikon) as linear camera RGB (float32, interleaved), with
    /// its luma weights and noise model, and the stage's level-0 luminance for a few settings.
    @Test(.enabled(if: parts.contains("dump")))
    func dumps() throws {
        let helper = try DetailStageTests()
        let paths = (ProcessInfo.processInfo.environment["W4_DUMP"] ?? "").split(separator: ",").map(String.init)
        let urls = try paths
            .isEmpty ? [#require(EngineSmokeTests.fixtures.first { $0.lastPathComponent == "DSC_0750.NEF" })]
            : paths.map { URL(fileURLWithPath: $0) }
        let builder = SessionBuilder(device: device, queue: queue, kernels: kernels)
        for url in urls {
            let session = try builder.build(ImageDecoder.decode(url))
            let name = url.deletingPathExtension().lastPathComponent
            let width = session.pyramid.width, height = session.pyramid.height
            let level0 = try helper.readLevel(session, level: 0)
            try Self.write(level0.flatMap { [$0.x, $0.y, $0.z] }, "\(name)_rgb.f32")
            for mip in 1 ... 3 {
                try Self.write(
                    helper.readLevel(session, level: mip).flatMap { [$0.x, $0.y, $0.z] },
                    "\(name)_rgb_level\(mip).f32",
                )
            }
            let luma = DetailStage.luma(session)
            let meta: [String: Any] = [
                "width": width, "height": height, "luma": [luma.x, luma.y, luma.z, luma.w],
                "a": [session.noise.a.x, session.noise.a.y, session.noise.a.z],
                "b": [session.noise.b.x, session.noise.b.y, session.noise.b.z],
                "sensor": "\(session.sensor)", "orientation": session.orientation,
            ]
            try JSONSerialization.data(withJSONObject: meta).write(to: Self.out.appending(path: "\(name)_meta.json"))
            let settings: [(String, (inout EditRecipe) -> Void)] = [
                ("texture100", { $0[.texture] = 100 }),
                ("sharpen100", { $0[.sharpenAmount] = 100 }),
                ("clarity100", { $0[.clarity] = 100 }),
            ]
            for (label, change) in settings {
                var recipe = DetailStageTests.untouched
                recipe[.lensProfile] = 0
                change(&recipe)
                let output = try render(helper, session, recipe, level: 0)
                try Self.write(output.map { simd_dot($0, SIMD3(luma.x, luma.y, luma.z)) }, "\(name)_\(label)_Y.f32")
                print("dumped \(name) \(label)")
            }
        }
        // Flat noisy fields through the real builder, for the log-luminance noise per scale.
        for level in [0.02, 0.1, 0.4] {
            let session = try helper.makeSession(.bayer, width: 1024, height: 768) { _, _ in Float(level) }
            let pixels = try helper.readLevel(session, level: 0)
            try Self.write(pixels.flatMap { [$0.x, $0.y, $0.z] }, "flat_\(level)_rgb.f32")
            let luma = DetailStage.luma(session)
            let meta: [String: Any] = [
                "width": 1024, "height": 768, "luma": [luma.x, luma.y, luma.z, luma.w],
                "a": [session.noise.a.x, session.noise.a.y, session.noise.a.z],
                "b": [session.noise.b.x, session.noise.b.y, session.noise.b.z],
            ]
            try JSONSerialization.data(withJSONObject: meta)
                .write(to: Self.out.appending(path: "flat_\(level)_meta.json"))
        }
    }

    // MARK: - Texture crops at full resolution, by process and setting

    @Test(.enabled(if: parts.contains("crops")))
    func crops() async throws {
        let tag = ProcessInfo.processInfo.environment["W4_TAG"] ?? "p10"
        let versions = (ProcessInfo.processInfo.environment["W4_VERSIONS"] ?? "10").split(separator: ",")
            .compactMap { Int($0) }
        let names = ["DSC_0750.NEF", "AFXT2720.RAF", "_DSC0009.ARW"]
        let dir = Self.out.appending(path: "crops")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in names {
            let url = try #require(EngineSmokeTests.fixtures.first { $0.lastPathComponent == name })
            let engine = try RedlampEngine()
            _ = try await engine.open(url)
            func still(_ recipe: EditRecipe) async throws -> CGImage {
                try await engine.renderStill(StillRequest(
                    recipe: recipe,
                    maxLongEdge: nil,
                    colorSpace: .sRGB,
                    purpose: .export,
                ))
            }
            var base = EditRecipe()
            base.processVersion = 9
            let reference = try await still(base)
            let boxes = try Self.boxes(reference, size: 400)
            for version in versions {
                for texture in [0.0, 50, 100, -50] {
                    if texture == 0, version == 10 {
                        continue
                    }
                    var recipe = base
                    recipe.processVersion = version
                    recipe[.texture] = texture
                    let image = texture == 0 ? reference : try await still(recipe)
                    for (index, box) in boxes.enumerated() {
                        let crop = try #require(image.cropping(to: box))
                        let label = texture == 0 ? "base" : "\(version == 9 ? "p9" : tag)_t\(Int(texture))"
                        let file = dir
                            .appending(path: "\(url.deletingPathExtension().lastPathComponent)_\(index)_\(label).png")
                        let destination = try #require(CGImageDestinationCreateWithURL(
                            file as CFURL,
                            "public.png" as CFString,
                            1,
                            nil,
                        ))
                        CGImageDestinationAddImage(destination, crop, nil)
                        #expect(CGImageDestinationFinalize(destination))
                    }
                }
            }
            print("crops \(name) \(boxes)")
        }
    }

    /// The most detailed 400 px block and one with a strong edge beside flat sky or skin.
    static func boxes(_ image: CGImage, size: Int) throws -> [CGRect] {
        let width = image.width, height = image.height
        var gray = [UInt8](repeating: 0, count: width * height)
        let context = try #require(CGContext(
            data: &gray, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue,
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var best: (Double, CGRect) = (-1, .zero)
        var edgy: (Double, CGRect) = (-1, .zero)
        for by in stride(from: 0, to: height - size, by: size / 2) {
            for bx in stride(from: 0, to: width - size, by: size / 2) {
                var small = 0.0, large = 0, count = 0
                for y in stride(from: by, to: by + size - 1, by: 2) {
                    for x in stride(from: bx, to: bx + size - 1, by: 2) {
                        let d = abs(Int(gray[y * width + x + 1]) - Int(gray[y * width + x]))
                        if d > 40 {
                            large += 1
                        } else {
                            small += Double(d)
                        }
                        count += 1
                    }
                }
                let texture = small / Double(count)
                if texture > best.0 {
                    best = (texture, CGRect(x: bx, y: by, width: size, height: size))
                }
                let edge = Double(large) / Double(count) / (texture + 0.5)
                if edge > edgy.0 {
                    edgy = (edge, CGRect(x: bx, y: by, width: size, height: size))
                }
            }
        }
        return [best.1, edgy.1]
    }
}
