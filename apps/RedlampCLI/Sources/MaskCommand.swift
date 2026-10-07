import Foundation
import ImageIO
import RedlampEngine
import RedlampEngineAPI

/// `redlamp mask`: computes AI masks of a photo and writes them as 8-bit PNGs, as an edit stores them.
enum MaskCommand {
    static let usage = """
    usage: redlamp mask <image> --kind <kind> -o <mask.png> [--point x,y]… [--exclude x,y]…
                        [--refine x,y;x,y… [--refine-size s]]… [--from <mask.png>] [--refine-edges]

      --kind      subject, background, sky, people, people:<part>, objects, depthRange,
                  landscape:<class>
                  (parts: faceSkin, bodySkin, eyebrows, eyeSclera, iris, lips, teeth, hair,
                  facialHair, clothes; classes: water, vegetation, mountains, architecture,
                  naturalGround, artificialGround, snow)
      --point     for objects: a point to select (0…1, from the top left); repeat to add
      --exclude   for objects: a point to leave out
      --refine    a Refine Edge brush stroke through these points, solved again per pixel; repeat
                  for more strokes
      --refine-size  the following strokes' radius, as a fraction of the height (default 0.03)
      --from      start from this mask (a PNG, as an edit stores it) instead of computing one
      --refine-edges  Refine Edges, as the component's menu does: the edge solved again
      -o          the PNG; several masks (one per person) are written as name-1.png, name-2.png…

    Objects and Depth Range use downloaded models (Settings › Models in the app; set
    REDLAMP_EVALUATION_MODELS=1 for models awaiting licence review). REDLAMP_SKY_METHOD forces
    Sky's method: auto (the default), sam, da3 or classical; REDLAMP_SKY_MATTE=off keeps the
    models' edges instead of solving each edge pixel at full size.
    """

    static func run(_ arguments: [String]) async throws {
        guard let path = arguments.first, path != "--help" else {
            print(usage)
            return
        }
        var kind: MaskKind?
        var part = PersonPart.entirePerson
        var landscape = LandscapeClass.vegetation
        var prompts: [ImagePoint] = []
        var excluded: [ImagePoint] = []
        var output: URL?
        var refinements: [BrushStroke] = []
        var refineSize = 0.03
        var source: URL?
        var refinesEdges = false
        var index = 1
        func value() throws -> String {
            index += 1
            guard index < arguments.count
            else { throw CLIError(description: "missing value for \(arguments[index - 1])") }
            return arguments[index]
        }
        func point(_ text: String) throws -> ImagePoint {
            let parts = text.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2 else { throw CLIError(description: "bad point \(text) (use x,y)") }
            return ImagePoint(x: parts[0], y: parts[1])
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--kind":
                let spec = try value().split(separator: ":").map(String.init)
                kind = MaskKind(rawValue: spec[0])
                if spec.count > 1, kind == .landscape {
                    guard let named = LandscapeClass(rawValue: spec[1])
                    else { throw CLIError(description: "unknown Landscape class \(spec[1])") }
                    landscape = named
                } else if spec.count > 1 {
                    guard let named = PersonPart(rawValue: spec[1])
                    else { throw CLIError(description: "unknown part \(spec[1])") }
                    part = named
                }
            case "--point": try prompts.append(point(value()))
            case "--exclude": try excluded.append(point(value()))
            case "--refine":
                try refinements.append(BrushStroke(
                    points: value().split(separator: ";").map { try point(String($0)) }, size: refineSize, feather: 0,
                ))
            case "--refine-size":
                guard let size = try Double(value()) else { throw CLIError(description: "bad --refine-size") }
                refineSize = size
            case "--from": source = try URL(fileURLWithPath: value())
            case "--refine-edges": refinesEdges = true
            case "-o", "--output": output = try URL(fileURLWithPath: value())
            default: throw CLIError(description: "unknown option \(arguments[index])\n\n\(usage)")
            }
            index += 1
        }
        guard let kind, kind.isAI else { throw CLIError(description: "--kind must be an AI mask kind\n\n\(usage)") }
        guard let output else { throw CLIError(description: "missing -o <mask.png>") }

        let engine = try RedlampEngine()
        _ = try await engine.open(URL(fileURLWithPath: path))
        if let model = await engine.modelNeeded(for: kind) {
            print("downloading \(model.name) (\(model.formattedSize))…")
            try await engine.downloadModel(model.id) { _ in }
        }
        let clock = ContinuousClock()
        let started = clock.now
        var masks: [AIMask] = if let source {
            try [given(source, kind: kind, part: part, landscape: landscape)]
        } else {
            try await engine.computeMasks(MaskRequest(
                kind: kind,
                part: part,
                prompts: prompts,
                excluded: excluded,
                landscape: landscape,
            ))
        }
        let elapsed = clock.now - started
        if refinesEdges {
            let refining = clock.now
            for index in masks.indices {
                masks[index].bitmap = try await engine.refineMaskEdges(masks[index])
            }
            print("refined edges in \(clock.now - refining)")
        }
        if !refinements.isEmpty {
            let refining = clock.now
            for index in masks.indices {
                masks[index].bitmap = try await engine.refineMaskEdges(masks[index].bitmap, along: refinements)
            }
            print(
                "refined along \(refinements.count) stroke\(refinements.count == 1 ? "" : "s") in \(clock.now - refining)",
            )
        }
        for (number, mask) in masks.enumerated() {
            guard let png = mask.bitmap.png else { continue }
            let url = masks.count == 1 ? output : output.deletingLastPathComponent()
                .appending(path: "\(output.deletingPathExtension().lastPathComponent)-\(number + 1).png")
            try ImageFile.write(encoded: png, to: url, protecting: [URL(fileURLWithPath: path)])
            print(
                "\(url.lastPathComponent): \(mask.bitmap.width)x\(mask.bitmap.height) \(mask.provider) r\(mask.revision)",
            )
        }
        print("\(masks.count) mask\(masks.count == 1 ? "" : "s") in \(elapsed)")
    }

    /// The mask in `url` as an AI mask of `kind`, as if it had just been made.
    static func given(_ url: URL, kind: MaskKind, part: PersonPart, landscape: LandscapeClass) throws -> AIMask {
        let png = try Data(contentsOf: url)
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw CLIError(description: "\(url.lastPathComponent) isn't an image") }
        return AIMask(
            kind: kind, provider: "file", revision: 1,
            part: kind == .landscape ? landscape.rawValue : kind == .people ? part.rawValue : nil,
            analysisHash: "", center: ImagePoint(x: 0.5, y: 0.5),
            bitmap: MaskBitmap(png: png, width: image.width, height: image.height),
        )
    }
}
