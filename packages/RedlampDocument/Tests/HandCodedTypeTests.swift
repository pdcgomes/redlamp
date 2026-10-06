import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampDocument

/// Every type with hand-written coding writes each stored property and reads it back: a
/// property added to the type but not to its coding fails here.
struct HandCodedTypeTests {
    /// Fields a newer build added, written beside the type's own keys.
    private static let bags: Set<String> = ["unknownFields", "unknownAdjustments", "unknownValues"]

    /// Checks `value`, fully populated, against its coding. `renamed` gives the keys of
    /// properties written under another name; `notWritten` the ones kept out of the file.
    private func check<T: Codable & Equatable>(
        _ value: T,
        renamed: [String: String] = [:],
        notWritten: Set<String> = [],
        sourceLocation: SourceLocation = #_sourceLocation,
    ) throws {
        let data = try JSONEncoder.sidecar.encode(value)
        guard case let .object(written) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            Issue.record("\(T.self) doesn't encode as an object", sourceLocation: sourceLocation)
            return
        }
        for case let label? in Mirror(reflecting: value).children.map(\.label)
            where !Self.bags.contains(label) && !notWritten.contains(label) {
            #expect(
                written[renamed[label] ?? label] != nil,
                "\(T.self).\(label) isn't written",
                sourceLocation: sourceLocation,
            )
        }
        #expect(
            try JSONDecoder.sidecar.decode(T.self, from: data) == value,
            "\(T.self) doesn't read back",
            sourceLocation: sourceLocation,
        )
    }

    private let everything = SidecarSamples.everything

    @Test func `the sidecar and its edit`() throws {
        try check(everything, notWritten: ["session", "clearsHistory", "unsavedSessions"])
        try check(
            everything.recipe, renamed: ["whiteBalanceMode": "whiteBalance"],
            notWritten: ["pointColor", "panelsOff", "unknownPanelsOff"],
        )
        var colored = everything.recipe
        colored.pointColor = [Self.pickedSwatch]
        colored.panelsOff = [.detail, .lens]
        try check(colored, renamed: ["whiteBalanceMode": "whiteBalance", "unknownPanelsOff": "panelsOff"])
        try check(#require(everything.recipe.exposureAnchor))
        try check(#require(everything.snapshots.first))
        var metadata = try #require(everything.metadata)
        metadata.originalName = "IMG_0001.ARW"
        metadata.keywords = ["Places/Portugal/Lisbon", "Music/AC%2FDC"]
        metadata.customLabel = "Second Look"
        metadata.mark = true
        metadata.title = "Tram 28"
        metadata.caption = "The tram climbing to Graça."
        metadata.creator = "Ana Sousa"
        metadata.copyright = "© 2026 Ana Sousa"
        metadata.location = PhotoLocation(
            country: "Portugal", state: "Lisboa", city: "Lisbon", sublocation: "Graça", countryCode: "PT",
        )
        metadata.collections = ["Clients/Acme/Selects"]
        metadata.stack = PhotoStack(id: UUID(uuidString: "6F1C2A4E-8B1D-4C3A-9E57-1B2D3C4E5F60"), top: true)
        try check(metadata)
        try check(#require(metadata.location))
        try check(#require(metadata.stack))
    }

    /// A swatch picked on the photo, every setting away from its default.
    private static let pickedSwatch = PointColorSwatch(
        color: .oklch(OKLCh(lightness: 0.62, chroma: 0.07, hue: 52)),
        picked: ColorSample(center: ImagePoint(x: 0.4, y: 0.3), radius: 0.01),
        values: Dictionary(uniqueKeysWithValues: ParameterID.pointColorParameters.enumerated().map {
            ($0.element, $0.element.spec.defaultValue + 10 + Double($0.offset))
        }),
    )

    @Test func `swatches and their colours`() throws {
        try check(Self.pickedSwatch)
        try check(OKLCh(lightness: 0.5, chroma: 0.1, hue: 200))
        let typical = PointColorSwatch(color: .mask, values: [.pointColorHueUniformity: 50])
        try check(typical, notWritten: ["picked"])
        var masked = everything.recipe.masks[0]
        masked.pointColor = [typical]
        try check(masked, notWritten: ["curves", "inverted"])
    }

    @Test func `mask layers, components and AI masks`() throws {
        let masks = everything.recipe.masks
        try check(masks[0], notWritten: ["curves", "pointColor", "inverted"])
        var inverted = masks[0]
        inverted.inverted = true
        try check(inverted, notWritten: ["curves", "pointColor"])
        var curved = masks[0]
        var curves = MaskCurves()
        for (index, channel) in MaskCurves.Channel.allCases.enumerated() {
            curves[channel] = [
                CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.25 + 0.125 * Double(index)), CurvePoint(x: 1, y: 1),
            ]
        }
        curved.curves = curves
        try check(curved, notWritten: ["pointColor", "inverted"])
        try check(curves)
        for component in masks.flatMap(\.components) {
            try check(component)
        }
        guard case let .ai(person) = masks[1].components[1].shape else {
            Issue.record("the sample's second subject component isn't an AI mask")
            return
        }
        try check(person, notWritten: ["box", "feather", "edge"])
        let object = AIMask(
            kind: .objects, provider: "redlamp.sam2.1", revision: 1, prompts: [ImagePoint(x: 0.4, y: 0.5)],
            excludedPrompts: [ImagePoint(x: 0.45, y: 0.55)], box: ImageRect(
                x: 0.25,
                y: 0.25,
                width: 0.5,
                height: 0.375,
            ),
            analysisHash: "h", center: ImagePoint(x: 0.5, y: 0.45),
            bitmap: MaskBitmap(sha256: String(repeating: "b", count: 64), width: 64, height: 48),
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
        )
        var shaped = object
        shaped.feather = 25
        shaped.edge = -10
        try check(shaped, notWritten: ["osBuild", "instance", "part", "refinements"])
    }

    @Test func `spots, recipes and looks`() throws {
        try check(everything.recipe.spots[1], notWritten: ["region", "fill"])
        try check(everything.recipe.spots[2], notWritten: ["stroke", "fill"])
        let generated = RetouchSpot(
            mode: .remove, center: ImagePoint(x: 0.5, y: 0.6), source: ImagePoint(x: 0.5, y: 0.6), radius: 0.04,
            fill: GeneratedFill(
                bitmap: MaskBitmap(sha256: String(repeating: "a", count: 64), width: 32, height: 24), peak: 1.5,
                box: GeneratedFill.Box(x: 120, y: 200, width: 128, height: 96),
                photoSize: PixelSize(width: 640, height: 480), model: "flux2-klein-4b-fill", modelVersion: 1, seed: 11,
                prompt: "remove",
            ),
        )
        try check(generated, notWritten: ["stroke", "region"])
        try check(#require(generated.fill))
        try check(#require(everything.recipe.appliedRecipe))
        try check(everything.recipe.baseLook)
        try check(
            BaseLookParameters(
                contrast: 1.1, saturation: 0.9, warmth: 0.1, greenBoost: 0.2, skinSoftening: 0.3, isMonochrome: true,
            ),
            renamed: ["isMonochrome": "monochrome"],
        )
    }

    @Test func `export settings`() throws {
        var sizing = ExportSizing()
        sizing.mode = .megapixels
        sizing.longEdge = 2000
        sizing.shortEdge = 1000
        sizing.width = 300
        sizing.height = 200
        sizing.megapixels = 12
        sizing.percentage = 50
        sizing.ppi = 300
        try check(sizing)

        var settings = ExportSettings()
        settings.format = .tiff
        settings.quality = 70
        settings.limitsFileSize = true
        settings.fileSizeLimitKB = 900
        settings.tiffCompression = .lzw
        settings.bitDepth = 16
        settings.colorSpace = .displayP3
        settings.sizing = sizing
        settings.metadata = .allExceptLocation
        settings.destinationFolder = URL(fileURLWithPath: "/tmp/Exports", isDirectory: true)
        settings.naming = ExportNaming(mode: .custom, customName: "Trip")
        settings.existingFiles = .overwrite
        settings.revealInFinder = false
        try check(settings)
    }
}
