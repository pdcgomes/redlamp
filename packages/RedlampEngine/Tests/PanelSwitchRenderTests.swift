import CoreGraphics
import Foundation
import Metal
import RedlampEngineAPI
import RedlampKernels
import RedlampServices
import simd
import Testing
@testable import RedlampEngine

/// Panel switches (UX-30) as the engine renders them: a switched-off panel renders as its settings
/// at rest, on the canvas and in exports alike.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct PanelSwitchRenderTests {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let kernels: KernelLibrary
    static let (width, height) = (192, 128)

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        queue = try #require(device.makeCommandQueue())
        kernels = try KernelLibrary(device: device)
    }

    /// The file's own correction: a barrel and corners a stop dark.
    static let lens = LensCorrection(
        source: .sony, center: SIMD2(0.5, 0.5), radii: [0, 0.4, 0.8, 1.2],
        distortion: [SIMD3(repeating: 1), SIMD3(repeating: 0.99), SIMD3(repeating: 0.97), SIMD3(repeating: 0.94)],
        vignetting: [1, 1.15, 1.6, 2.2],
    )

    /// Orange and blue squares with a speckle of colour noise, for sharpening, noise reduction and
    /// the colour panels to act on.
    func session() throws -> ImageSession {
        let (width, height) = (Self.width, Self.height)
        var generator = SystemRandomNumberGenerator()
        var samples = [UInt16](repeating: 0, count: width * height * 3)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let base = (x / 12 + y / 12).isMultiple(of: 2) ? SIMD3(0.4, 0.24, 0.1) : SIMD3(0.1, 0.18, 0.36)
                for channel in 0 ..< 3 {
                    let noise = Double.random(in: -0.04 ... 0.04, using: &generator)
                    samples[(y * width + x) * 3 + channel] = UInt16(min(max(base[channel] + noise, 0), 1) * 65535)
                }
            }
        }
        var decoded = DecodedImage(
            width: width, height: height, layout: .linearRGB, samples: samples, blackLevels: [0, 0, 0],
            whiteLevel: 65535, asShotMultipliers: SIMD3(1, 1, 1), cameraToSRGB: [1, 0, 0, 0, 1, 0, 0, 0, 1],
            xyzToCamera: nil, orientation: 0, baselineExposure: 0,
            info: ImageInfo(
                url: URL(fileURLWithPath: "/switches.dng"), pixelSize: PixelSize(width: width, height: height),
                isRaw: true, sensorDescription: "synthetic",
            ),
        )
        decoded.lensCorrection = Self.lens
        return try SessionBuilder(device: device, queue: queue, kernels: kernels).build(decoded)
    }

    func render(_ engine: RedlampEngine, _ session: ImageSession, _ recipe: EditRecipe) throws -> [Float] {
        let size = session.orientedSize
        let frame = try engine.renderFrame(
            RenderRequest(recipe: recipe, targetSize: size, generation: 0), session: session,
        )
        let surface = frame.surface
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let rowBytes = IOSurfaceGetBytesPerRow(surface)
        let base = IOSurfaceGetBaseAddress(surface)
        return (0 ..< size.height).flatMap { y in
            let row = (base + y * rowBytes).assumingMemoryBound(to: Float16.self)
            return (0 ..< size.width * 4).map { Float(row[$0]) }
        }
    }

    func still(_ engine: RedlampEngine, _ session: ImageSession, _ recipe: EditRecipe) throws -> Data {
        let image = try engine.renderStillNow(StillRequest(recipe: recipe, purpose: .export), session: session)
        return try #require(image.dataProvider?.data as Data?)
    }

    static func difference(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).map { abs($0 - $1) }.max() ?? .infinity
    }

    @Test func `Detail off renders as no sharpening and no noise reduction`() throws {
        let session = try session()
        let engine = try RedlampEngine()
        var edit = EditRecipe()
        edit[.noiseLuminance] = 40
        var off = edit
        off.setPanel(.detail, on: false)
        var none = edit
        none[.sharpenAmount] = 0
        none[.noiseLuminance] = 0
        none[.noiseColor] = 0
        let rendered = try render(engine, session, off)
        #expect(try Self.difference(rendered, render(engine, session, none)) == 0)
        #expect(try Self.difference(rendered, render(engine, session, edit)) > 0.01, "the defaults act")
        #expect(try still(engine, session, off) == still(engine, session, none), "exports agree")
    }

    @Test func `Lens Corrections off renders without the file's own correction`() throws {
        let session = try session()
        let engine = try RedlampEngine()
        let edit = EditRecipe()
        var off = edit
        off.setPanel(.lens, on: false)
        var none = edit
        none[.lensProfile] = 0
        let rendered = try render(engine, session, off)
        #expect(try Self.difference(rendered, render(engine, session, none)) == 0)
        #expect(try Self.difference(rendered, render(engine, session, edit)) > 0.01, "the profile applies by default")
        #expect(try still(engine, session, off) == still(engine, session, none), "exports agree")
    }

    @Test func `the other panels off render as their settings at rest`() throws {
        let session = try session()
        let engine = try RedlampEngine()
        var edit = EditRecipe()
        edit[.lensProfile] = 0
        edit[.sharpenAmount] = 0
        edit[.noiseColor] = 0
        let plain = try render(engine, session, edit)
        let settings: [(SwitchablePanel, ParameterID, Double)] = [
            (.toneCurve, .curveLights, 60), (.colorMixer, .luminanceOrange, -60), (
                .colorGrading,
                .gradeGlobalSaturation,
                60,
            ),
            (.transform, .transformRotate, 5), (.effects, .vignetteAmount, -60), (.calibration, .calibrationRedHue, 60),
        ]
        for (panel, parameter, value) in settings {
            var on = edit
            on[parameter] = value
            var off = on
            off.setPanel(panel, on: false)
            #expect(try Self.difference(render(engine, session, off), plain) == 0, "\(panel) off")
            #expect(try Self.difference(render(engine, session, on), plain) > 0.001, "\(parameter) acts")
        }
    }
}
