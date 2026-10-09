import CoreGraphics
import Foundation
import ImageIO
import IOSurface
import RedlampColor
import RedlampEngine
import RedlampEngineAPI
import simd
import Testing

/// Every process version keeps rendering as it did when it shipped (ARC-03). Each fixture is
/// developed with each `Edit` at every process version, from 1 to the current one, and measured
/// twice: the whole photo exported at `longEdge`, and a window from its middle at full resolution,
/// as the editor shows it at 1:1. Each keeps its patches' colours (CIELAB, as `CameraGoldenTests`
/// measures them) and detail, compared with `tests/golden/process/process-<N>`.
///
/// A version's references are recorded once, when the version ships, and never regenerated.
/// Recording writes only the missing ones and leaves the rest alone:
/// `TEST_RUNNER_REDLAMP_RECORD_PROCESS_GOLDEN=1 mise run test`.
struct ProcessStabilityTests {
    struct Patches: Codable, Equatable {
        var width: Int
        var height: Int
        var columns: Int
        var rows: Int
        /// Patch means in L*a*b*, row-major.
        var lab: [[Double]]
        /// Each patch's RMS difference in L* between neighbouring pixels, which grain, noise
        /// reduction, sharpening and Texture change.
        var detail: [Double]
    }

    struct Reference: Codable, Equatable {
        /// The whole photo, exported at `longEdge`.
        var frame: Patches
        /// `window` pixels from the middle of the photo, at full resolution.
        var oneToOne: Patches
    }

    static let longEdge = 384
    static let frameGrid = (columns: 24, rows: 16)
    static let window = PixelSize(width: 384, height: 256)
    static let windowGrid = (columns: 12, rows: 8)
    /// The mean over the patches and the worst patch, for colour (CIEDE2000) and for detail (L*).
    /// Rendering is deterministic: on an M1 Ultra (macOS 26.6), repeats with the same engine, with
    /// a fresh one and in reverse order measured the same to the last digit. So the limits leave
    /// room only for another GPU's rounding, a twenty-fifth and a tenth of the camera goldens'. A
    /// 10% nudge at the current process of Sharpening, grain, Texture, Clarity, Dehaze, Shadows or
    /// Color noise reduction moves the mean of its most affected fixture by 0.038 to 0.39.
    static let meanLimit = 0.02
    static let worstLimit = 0.2

    static let folder = CameraGoldenTests.root.appending(path: "tests/golden/process")
    static let recording = ProcessInfo.processInfo.environment["REDLAMP_RECORD_PROCESS_GOLDEN"] == "1"
    static let versions = Array(1 ... EditRecipe.currentProcessVersion)

    /// Between them, every process's change shows: grain at 1:1 (2), a bitmap, and halation that
    /// skips large clipped areas (3), the Pixel's HueSatMap (4), ProRAW's gain table map with its
    /// embedded look and Sony's lens correction (5), Fujifilm's lens correction (6), and edge-aware
    /// Highlights and Shadows (7), Dehaze (8) and Clarity (9) in all of them. The bitmap is the
    /// Nikon sample developed by macOS, kept beside the references so it never changes. It's a PNG
    /// because JPEG decoders differ between Macs (a GitHub runner decoded the JPEG it replaced up to
    /// 3 levels apart in 8% of its pixels), while a PNG decodes to the same pixels everywhere.
    static let fixtures: [URL] = {
        let raws = ["_DSC0009.ARW", "AFXT2720.RAF", "IMG_1361.DNG", "PXL_20201121_100251397.dng"]
        return EngineSmokeTests.fixtures.filter { raws.contains($0.lastPathComponent) }
            + [folder.appending(path: "DSC_0750.png")]
    }()

    enum Edit: String, CaseIterable, Sendable {
        /// Tone, presence, colour, a curve, grading, grain, halation and a gradient (`heavyEdit`).
        case heavy
        /// Brush, luminance range, colour range and AI masks, Heal and Clone spots, an angled
        /// crop with Transform, and black and white with its mixer (`retouchEdit`).
        case retouch
        /// Redlamp Reproduction with the typical exposure anchor, Exposure, Blacks against flare
        /// and a gradient's own exposure (`reproductionEdit`).
        case reproduction
    }

    static func referenceURL(process: Int, fixture: URL, edit: Edit) -> URL {
        let suffix = edit == .heavy ? "" : ".\(edit.rawValue)"
        return folder.appending(path: "process-\(process)/\(fixture.lastPathComponent)\(suffix).json")
    }

    @Test(.enabled(if: EngineSmokeTests.canRender && !recording), arguments: fixtures, Edit.allCases)
    func `every process version renders as recorded`(fixture: URL, edit: Edit) async throws {
        let engine = try RedlampEngine()
        let info = try await engine.open(fixture)
        let name = edit == .heavy ? fixture.lastPathComponent : "\(fixture.lastPathComponent) (\(edit.rawValue) edit)"
        for process in Self.versions {
            guard let data = try? Data(contentsOf: Self.referenceURL(process: process, fixture: fixture, edit: edit))
            else {
                Issue.record("""
                process \(process) has no reference for \(name); record the missing references with \
                TEST_RUNNER_REDLAMP_RECORD_PROCESS_GOLDEN=1 mise run test
                """)
                continue
            }
            let reference = try JSONDecoder().decode(Reference.self, from: data)
            let measured = try await Self.measure(
                engine,
                info: info,
                recipe: Self.recipe(edit, process: process, info: info),
            )
            for (view, now, then) in [
                ("whole frame", measured.frame, reference.frame), ("1:1 window", measured.oneToOne, reference.oneToOne),
            ] {
                guard now.width == then.width, now.height == then.height, now.lab.count == then.lab.count else {
                    Issue.record("process \(process), \(name), \(view): the size or the patch grid changed")
                    continue
                }
                let colour = Self.spread(zip(now.lab, then.lab).map { a, b in
                    CIELab.deltaE2000(SIMD3(a[0], a[1], a[2]), SIMD3(b[0], b[1], b[2]))
                })
                let detail = Self.spread(zip(now.detail, then.detail).map { abs($0 - $1) })
                func value(_ x: Double) -> String {
                    String(format: "%.3f", x)
                }
                #expect(
                    [colour.mean, detail.mean].allSatisfy { $0 < Self.meanLimit }
                        && [colour.worst, detail.worst].allSatisfy { $0 < Self.worstLimit },
                    """
                    process \(process) no longer renders \(name) as recorded (\(view)): colour ΔE2000 mean \
                    \(value(colour.mean)), worst \(value(colour.worst)); detail ΔL* mean \(value(detail.mean)), \
                    worst \(value(detail.worst)) (limits \(Self.meanLimit) and \(Self.worstLimit))
                    """,
                )
            }
        }
    }

    @Test(.enabled(if: EngineSmokeTests.canRender && recording))
    func `record missing references`() async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for fixture in Self.fixtures {
            let missing = Self.versions.flatMap { process in
                Edit.allCases.filter {
                    !FileManager.default.fileExists(
                        atPath: Self.referenceURL(process: process, fixture: fixture, edit: $0).path,
                    )
                }.map { (process, $0) }
            }
            guard !missing.isEmpty else { continue }
            let engine = try RedlampEngine()
            let info = try await engine.open(fixture)
            for (process, edit) in missing {
                let url = Self.referenceURL(process: process, fixture: fixture, edit: edit)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                )
                try await encoder.encode(Self.measure(
                    engine, info: info, recipe: Self.recipe(edit, process: process, info: info),
                )).write(to: url, options: .withoutOverwriting)
            }
        }
    }

    static func recipe(_ edit: Edit, process: Int, info: ImageInfo) throws -> EditRecipe {
        switch edit {
        case .heavy: heavyEdit(process: process, info: info)
        case .retouch: try retouchEdit(process: process)
        case .reproduction: reproductionEdit(process: process, info: info)
        }
    }

    /// Redlamp Reproduction as a copy stand uses it: the camera's anchor (the typical one here),
    /// a little Exposure, Blacks lowered a touch for flare, and a gradient with its own exposure.
    static func reproductionEdit(process: Int, info: ImageInfo) -> EditRecipe {
        var recipe = EditRecipe()
        recipe.processVersion = process
        recipe.baseLook = BuiltInBaseLook.reproduction.reference
        recipe = recipe.anchored(info.isRaw ? .typical(for: info.cameraName) : nil)
        recipe[.exposure] = 0.3
        recipe[.blacks] = -5
        var gradient = MaskLayer(
            id: UUID(uuidString: "9A4E2C61-7B3D-4F58-A1E9-5C0D2B3A4E71")!,
            name: "Top",
            components: [MaskComponent(
                id: UUID(uuidString: "4D7F1B92-6E2A-4C3B-8D5F-2A1B0C9D8E7F")!,
                shape: .linear(LinearMask(start: ImagePoint(x: 0.5, y: 0), end: ImagePoint(x: 0.5, y: 0.6))),
            )],
        )
        gradient[.localExposure] = -0.6
        recipe.masks = [gradient]
        return recipe
    }

    /// One edit using everything process versions have changed: tone, Texture, Clarity and
    /// Dehaze, colour, a tone curve, grading, grain and halation, a gradient with its own exposure
    /// and Clarity, and the file's lens correction (on by default). A photo whose embedded look
    /// comes with a gain table map (ProRAW) uses the look from the process that applies the map,
    /// when the Basic panel starts offering it.
    static func heavyEdit(process: Int, info: ImageInfo) -> EditRecipe {
        var recipe = EditRecipe()
        recipe.processVersion = process
        recipe[.exposure] = 0.3
        recipe[.contrast] = 20
        recipe[.highlights] = -60
        recipe[.shadows] = 60
        recipe[.whites] = 15
        recipe[.blacks] = -15
        recipe[.texture] = 40
        recipe[.clarity] = 40
        recipe[.dehaze] = 40
        recipe[.vibrance] = 30
        recipe[.saturation] = 10
        recipe.pointCurve = [
            CurvePoint(x: 0, y: 0), CurvePoint(x: 0.25, y: 0.21), CurvePoint(x: 0.75, y: 0.8), CurvePoint(x: 1, y: 1),
        ]
        recipe[.curveLights] = 15
        recipe[.gradeShadowsHue] = 220
        recipe[.gradeShadowsSaturation] = 30
        recipe[.gradeHighlightsHue] = 45
        recipe[.gradeHighlightsSaturation] = 25
        recipe[.grainAmount] = 40
        recipe[.halationAmount] = 50
        var gradient = MaskLayer(
            id: UUID(uuidString: "6C1D3F0A-9E2B-4B8E-8F57-0A3C2D1E4F60")!,
            name: "Top",
            components: [MaskComponent(
                id: UUID(uuidString: "2B8E5A71-3C4D-4E6F-9A0B-1C2D3E4F5A6B")!,
                shape: .linear(LinearMask(start: ImagePoint(x: 0.5, y: 0), end: ImagePoint(x: 0.5, y: 0.6))),
            )],
        )
        gradient[.localExposure] = -0.6
        gradient[.localClarity] = 50
        recipe.masks = [gradient]
        if let look = info.embeddedBaseLook, let needs = info.embeddedBaseLookProcess, process >= needs {
            recipe.baseLook = look
        }
        return recipe
    }

    /// The sky matte `IMG_1361.DNG` carries, as the decoder reads it, kept here so the AI
    /// mask never changes with the reader or the OS. Every fixture uses it, stretched to its frame.
    static let skyMatte = folder.appending(path: "IMG_1361.sky.png")

    /// The rest of the editor: a brush, luminance and colour ranges, an AI mask, a Heal circle and
    /// a brushed Clone, Transform under a crop turned by its angle, and black and white with the
    /// mixer's luminance. Each local adjustment is mostly exposure, which black and white keeps.
    /// Heal and Clone sit where both views see them.
    ///
    /// Spots are the removal work's (RM-*), and still changing, so they use only what
    /// `RetouchSpot` has had from the start. A change to how an existing spot renders is a
    /// process-version question: if it ships as one, the new version records its references here.
    static func retouchEdit(process: Int) throws -> EditRecipe {
        var recipe = EditRecipe()
        recipe.processVersion = process
        recipe.treatment = .blackAndWhite
        recipe[.luminanceRed] = -30
        recipe[.luminanceOrange] = 25
        recipe[.luminanceYellow] = 20
        recipe[.luminanceGreen] = -25
        recipe[.luminanceBlue] = -45
        recipe.crop = CropRect(left: 0.08, top: 0.1, right: 0.92, bottom: 0.9)
        recipe[.cropAngle] = 3.5
        recipe[.transformVertical] = 12
        recipe[.transformHorizontal] = -8

        func id(_ last: Int) -> UUID {
            UUID(uuidString: String(format: "8F3A1C52-6D0E-4B7A-9C2F-%012X", last))!
        }
        func layer(
            _ number: Int,
            _ name: String,
            _ shape: MaskShape,
            _ adjustments: [ParameterID: Double],
        ) -> MaskLayer {
            MaskLayer(
                id: id(number), name: name, components: [MaskComponent(id: id(number + 100), shape: shape)],
                adjustments: adjustments,
            )
        }
        let png = try Data(contentsOf: skyMatte)
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let sky = try AIMask(
            kind: .sky, provider: "apple.embedded.sky", revision: 1, analysisHash: "",
            center: ImagePoint(x: 0.5, y: 0.2),
            bitmap: MaskBitmap(
                png: png,
                width: #require(properties[kCGImagePropertyPixelWidth] as? Int),
                height: #require(properties[kCGImagePropertyPixelHeight] as? Int),
            ),
            createdAt: Date(timeIntervalSince1970: 0),
        )
        recipe.masks = [
            layer(1, "Brush", .brush(BrushMask(strokes: [BrushStroke(
                points: [
                    ImagePoint(x: 0.12, y: 0.72), ImagePoint(x: 0.3, y: 0.58), ImagePoint(x: 0.5, y: 0.62),
                    ImagePoint(x: 0.72, y: 0.5),
                ],
                size: 0.07, feather: 60, flow: 80,
            )])), [.localExposure: 0.9]),
            layer(2, "Lights", .luminanceRange(LuminanceRangeMask(lower: 65, upper: 100, lowerFeather: 15)), [
                .localExposure: -0.7, .localContrast: 30,
            ]),
            layer(3, "Colour", .colorRange(ColorRangeMask(samples: [
                ColorSample(center: ImagePoint(x: 0.5, y: 0.5), radius: 0.03), ColorSample(center: ImagePoint(
                    x: 0.3,
                    y: 0.3,
                )),
            ])), [.localExposure: 0.6]),
            layer(4, "Sky", .ai(sky), [.localExposure: -0.8, .localDehaze: 40]),
        ]
        recipe.spots = [
            RetouchSpot(
                id: id(200), mode: .heal, center: ImagePoint(x: 0.3, y: 0.4), source: ImagePoint(x: 0.62, y: 0.42),
                radius: 0.06,
            ),
            RetouchSpot(
                id: id(201), mode: .clone, center: ImagePoint(x: 0.5, y: 0.5), source: ImagePoint(x: 0.46, y: 0.43),
                stroke: [ImagePoint(x: 0.03, y: 0.01)], radius: 0.02, feather: 30,
            ),
        ]
        return recipe
    }

    /// `recipe`: the whole photo exported, and the window rendered at 1:1.
    static func measure(_ engine: RedlampEngine, info: ImageInfo, recipe: EditRecipe) async throws -> Reference {
        let process = recipe.processVersion
        let image = try await engine.renderStill(StillRequest(
            recipe: recipe, maxLongEdge: longEdge, colorSpace: .sRGB, bitsPerComponent: 16, purpose: .export,
        ))
        let developed = recipe.developedSize(imageSize: info.pixelSize)
        let size = PixelSize(width: min(window.width, developed.width), height: min(window.height, developed.height))
        let region = ImageRect(
            x: Double((developed.width - size.width) / 2) / Double(developed.width),
            y: Double((developed.height - size.height) / 2) / Double(developed.height),
            width: Double(size.width) / Double(developed.width),
            height: Double(size.height) / Double(developed.height),
        )
        var frames = engine.frames().makeAsyncIterator()
        engine.render(RenderRequest(recipe: recipe, targetSize: size, region: region, generation: UInt64(process)))
        let frame = try #require(await frames.next())
        try #require(frame.generation == UInt64(process) && frame.size == size)
        return try Reference(
            frame: patches(linearSRGB(image), width: image.width, height: image.height, grid: frameGrid),
            oneToOne: patches(linearSRGB(frame), width: size.width, height: size.height, grid: windowGrid),
        )
    }

    /// A still's pixels in linear sRGB, read as `CameraGoldenTests` reads them.
    static func linearSRGB(_ image: CGImage) throws -> [SIMD3<Double>] {
        let (width, height) = (image.width, image.height)
        let space = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        var pixels = [Float](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 32,
                bytesPerRow: width * 16, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue,
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        try #require(drawn)
        return (0 ..< width * height).map { i in
            SIMD3(Double(pixels[i * 4]), Double(pixels[i * 4 + 1]), Double(pixels[i * 4 + 2]))
        }
    }

    /// An editor frame's pixels (linear Display P3) in linear sRGB.
    static func linearSRGB(_ frame: RenderedFrame) -> [SIMD3<Double>] {
        let surface = frame.surface
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let base = IOSurfaceGetBaseAddress(surface)
        let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
        let toSRGB = RGBPrimaries.displayP3.conversion(to: .sRGB)
        return (0 ..< frame.size.height).flatMap { y in
            let row = (base + y * bytesPerRow).assumingMemoryBound(to: Float16.self)
            return (0 ..< frame.size.width).map { x in
                toSRGB * SIMD3(Double(row[x * 4]), Double(row[x * 4 + 1]), Double(row[x * 4 + 2]))
            }
        }
    }

    static func patches(
        _ pixels: [SIMD3<Double>], width: Int, height: Int, grid: (columns: Int, rows: Int),
    ) -> Patches {
        let lightness = pixels.map { CIELab.fromLinearSRGB($0).x }
        func rounded(_ value: Double) -> Double {
            (value * 1000).rounded() / 1000
        }
        var lab: [[Double]] = []
        var detail: [Double] = []
        for row in 0 ..< grid.rows {
            for column in 0 ..< grid.columns {
                var sum = SIMD3<Double>.zero
                var steps = 0.0
                var stepCount = 0
                let ys = row * height / grid.rows ..< (row + 1) * height / grid.rows
                let xs = column * width / grid.columns ..< (column + 1) * width / grid.columns
                for y in ys {
                    for x in xs {
                        let index = y * width + x
                        sum += pixels[index]
                        if x + 1 < xs.upperBound {
                            steps += pow(lightness[index + 1] - lightness[index], 2)
                            stepCount += 1
                        }
                        if y + 1 < ys.upperBound {
                            steps += pow(lightness[index + width] - lightness[index], 2)
                            stepCount += 1
                        }
                    }
                }
                let value = CIELab.fromLinearSRGB(sum / Double(ys.count * xs.count))
                lab.append([value.x, value.y, value.z].map(rounded))
                detail.append(rounded((steps / Double(max(stepCount, 1))).squareRoot()))
            }
        }
        return Patches(width: width, height: height, columns: grid.columns, rows: grid.rows, lab: lab, detail: detail)
    }

    static func spread(_ differences: [Double]) -> (mean: Double, worst: Double) {
        (differences.reduce(0, +) / Double(max(differences.count, 1)), differences.max() ?? 0)
    }
}
