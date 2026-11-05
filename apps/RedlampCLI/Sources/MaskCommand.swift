import Foundation
import ImageIO
import RedlampEngine
import RedlampEngineAPI

/// `redlamp mask`: computes AI masks of a photo and writes them as 8-bit PNGs, as an edit stores them.
enum MaskCommand {
    static let usage = """
    usage: redlamp mask <image> --kind <kind> -o <mask.png> [--point x,y]… [--exclude x,y]… [--box x,y,w,h]
                        [--refine x,y;x,y… [--refine-size s]]… [--from <mask.png>] [--refine-edges]
           redlamp mask --batch <jobs.json>

      --kind      subject, background, sky, people, people:<part>, objects, depthRange,
                  landscape:<class>
                  (parts: faceSkin, bodySkin, eyebrows, eyeSclera, iris, lips, teeth, hair,
                  facialHair, clothes; classes: water, vegetation, mountains, architecture,
                  naturalGround, artificialGround, snow)
      --point     for objects: a point to select (0…1, from the top left); repeat to add
      --exclude   for objects: a point to leave out
      --box       for objects: a box around the thing (0…1, from the top left: x,y,width,height)
      --refine    a Refine Edge brush stroke through these points, solved again per pixel; repeat
                  for more strokes
      --refine-size  the following strokes' radius, as a fraction of the height (default 0.03)
      --from      start from this mask (a PNG, as an edit stores it) instead of computing one
      --refine-edges  Refine Edges, as the component's menu does: the edge solved again
      -o          the PNG; several masks (one per person) are written as name-1.png, name-2.png…
      --batch     many masks in one process, each photo opened and each model loaded once: a JSON
                  array of jobs, each {"image", "kind", "output"} and optionally "points" and
                  "excluded" ([[x, y]…]), "box" ([x, y, w, h]), "from" and "refineEdges"; prints a
                  JSON line per job with its masks' files and providers and the seconds it took, or
                  its error

    Objects and Depth Range use downloaded models (Settings › Models in the app; set
    REDLAMP_EVALUATION_MODELS=1 for models awaiting licence review). REDLAMP_SKY_METHOD forces
    Sky's method: auto (the default), sam, da3 or classical; REDLAMP_SKY_MATTE=off keeps the
    models' edges instead of solving each edge pixel at full size.
    """

    /// One mask request, and what to do with its masks.
    struct Spec {
        var kind: MaskKind
        var part = PersonPart.entirePerson
        var landscape = LandscapeClass.vegetation
        var prompts: [ImagePoint] = []
        var excluded: [ImagePoint] = []
        var box: ImageRect?
        var refinements: [BrushStroke] = []
        var source: URL?
        var refinesEdges = false
        var output: URL
    }

    /// A job of `--batch`.
    struct Job: Decodable {
        var image: String
        var kind: String
        var output: String
        var points: [[Double]]?
        var excluded: [[Double]]?
        var box: [Double]?
        var from: String?
        var refineEdges: Bool?
    }

    static func run(_ arguments: [String]) async throws {
        guard let path = arguments.first, path != "--help" else {
            print(usage)
            return
        }
        if path == "--batch" {
            guard arguments.count == 2 else { throw CLIError(description: "--batch takes one jobs file\n\n\(usage)") }
            return try await runBatch(arguments[1])
        }
        var kind: (MaskKind, PersonPart, LandscapeClass)?
        var prompts: [ImagePoint] = []
        var excluded: [ImagePoint] = []
        var box: ImageRect?
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
            case "--kind": kind = try Self.kind(value())
            case "--point": try prompts.append(point(value()))
            case "--exclude": try excluded.append(point(value()))
            case "--box": box = try Self.box(value().split(separator: ",").compactMap { Double($0) })
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
        guard let (kind, part, landscape) = kind, kind.isAI
        else { throw CLIError(description: "--kind must be an AI mask kind\n\n\(usage)") }
        guard let output else { throw CLIError(description: "missing -o <mask.png>") }
        let spec = Spec(
            kind: kind, part: part, landscape: landscape, prompts: prompts, excluded: excluded, box: box,
            refinements: refinements, source: source, refinesEdges: refinesEdges, output: output,
        )

        let photo = URL(fileURLWithPath: path)
        let engine = try RedlampEngine()
        _ = try await engine.open(photo)
        try await download(for: kind, engine: engine) { print($0) }
        let (masks, elapsed) = try await make(spec, engine: engine) { print($0) }
        for (url, mask) in try write(masks, to: output, protecting: photo) {
            print(
                "\(url.lastPathComponent): \(mask.bitmap.width)x\(mask.bitmap.height) \(mask.provider) r\(mask.revision)",
            )
        }
        print("\(masks.count) mask\(masks.count == 1 ? "" : "s") in \(elapsed)")
    }

    /// `--batch`: the jobs in order, opening a photo only when it changes, so the masks of one photo
    /// share its analysis render and its solved Subject matte.
    static func runBatch(_ path: String) async throws {
        let jobs = try JSONDecoder().decode([Job].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let engine = try RedlampEngine()
        var opened: String?
        var offered: Set<MaskKind> = []
        for job in jobs {
            var line: [String: Any] = ["image": job.image, "kind": job.kind, "output": job.output]
            let clock = ContinuousClock()
            let started = clock.now
            do {
                let spec = try spec(job)
                let photo = URL(fileURLWithPath: job.image)
                if opened != job.image {
                    opened = nil
                    _ = try await engine.open(photo)
                    opened = job.image
                }
                if offered.insert(spec.kind).inserted {
                    try await download(for: spec.kind, engine: engine) {
                        FileHandle.standardError.write(Data(($0 + "\n").utf8))
                    }
                }
                let (masks, _) = try await make(spec, engine: engine) { _ in }
                line["masks"] = try write(masks, to: spec.output, protecting: photo).map { url, mask in
                    [
                        "file": url.path, "width": mask.bitmap.width, "height": mask.bitmap.height,
                        "provider": mask.provider, "revision": mask.revision,
                    ] as [String: Any]
                }
            } catch {
                line["error"] = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
            let elapsed = (clock.now - started).components
            line["seconds"] = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            let data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            fflush(stdout)
        }
    }

    static func spec(_ job: Job) throws -> Spec {
        let (kind, part, landscape) = try kind(job.kind)
        guard kind.isAI else { throw CLIError(description: "\(job.kind) isn't an AI mask kind") }
        func points(_ pairs: [[Double]]?) throws -> [ImagePoint] {
            try (pairs ?? []).map { pair in
                guard pair.count == 2 else { throw CLIError(description: "bad point \(pair) (use [x, y])") }
                return ImagePoint(x: pair[0], y: pair[1])
            }
        }
        return try Spec(
            kind: kind, part: part, landscape: landscape, prompts: points(job.points), excluded: points(job.excluded),
            box: job.box.map(box), source: job.from.map { URL(fileURLWithPath: $0) },
            refinesEdges: job.refineEdges ?? false, output: URL(fileURLWithPath: job.output),
        )
    }

    /// A `--kind` value: the kind, and a person part or Landscape class after a colon.
    static func kind(_ text: String) throws -> (MaskKind, PersonPart, LandscapeClass) {
        let spec = text.split(separator: ":").map(String.init)
        guard let kind = spec.first.flatMap(MaskKind.init(rawValue:))
        else { throw CLIError(description: "unknown kind \(text)\n\n\(usage)") }
        var part = PersonPart.entirePerson
        var landscape = LandscapeClass.vegetation
        if spec.count > 1, kind == .landscape {
            guard let named = LandscapeClass(rawValue: spec[1])
            else { throw CLIError(description: "unknown Landscape class \(spec[1])") }
            landscape = named
        } else if spec.count > 1 {
            guard let named = PersonPart(rawValue: spec[1])
            else { throw CLIError(description: "unknown part \(spec[1])") }
            part = named
        }
        return (kind, part, landscape)
    }

    static func box(_ values: [Double]) throws -> ImageRect {
        guard values.count == 4, values[2] > 0, values[3] > 0
        else { throw CLIError(description: "bad box \(values) (use x,y,width,height)") }
        return ImageRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    /// Downloads the model `kind` needs, if this Mac doesn't have it yet.
    static func download(for kind: MaskKind, engine: RedlampEngine, note: (String) -> Void) async throws {
        guard let model = await engine.modelNeeded(for: kind) else { return }
        note("downloading \(model.name) (\(model.formattedSize))…")
        try await engine.downloadModel(model.id) { _ in }
    }

    /// The masks `spec` asks for, made from the open photo or read from its `source`, then refined as
    /// it says; and how long making them took, refinement aside.
    static func make(
        _ spec: Spec, engine: RedlampEngine, note: (String) -> Void,
    ) async throws -> (masks: [AIMask], elapsed: Duration) {
        let clock = ContinuousClock()
        let started = clock.now
        var masks: [AIMask] = if let source = spec.source {
            try [given(source, kind: spec.kind, part: spec.part, landscape: spec.landscape)]
        } else {
            try await engine.computeMasks(MaskRequest(
                kind: spec.kind,
                part: spec.part,
                prompts: spec.prompts,
                excluded: spec.excluded,
                landscape: spec.landscape,
                box: spec.box,
            ))
        }
        let elapsed = clock.now - started
        if spec.refinesEdges {
            let refining = clock.now
            for index in masks.indices {
                masks[index].bitmap = try await engine.refineMaskEdges(masks[index])
            }
            note("refined edges in \(clock.now - refining)")
        }
        if !spec.refinements.isEmpty {
            let refining = clock.now
            for index in masks.indices {
                masks[index].bitmap = try await engine.refineMaskEdges(masks[index].bitmap, along: spec.refinements)
            }
            let count = spec.refinements.count
            note("refined along \(count) stroke\(count == 1 ? "" : "s") in \(clock.now - refining)")
        }
        return (masks, elapsed)
    }

    /// Writes each mask as a PNG: `output` for one, `name-1.png`, `name-2.png`… for several.
    static func write(_ masks: [AIMask], to output: URL, protecting photo: URL) throws -> [(URL, AIMask)] {
        try masks.enumerated().compactMap { number, mask in
            guard let png = mask.bitmap.png else { return nil }
            let url = masks.count == 1 ? output : output.deletingLastPathComponent()
                .appending(path: "\(output.deletingPathExtension().lastPathComponent)-\(number + 1).png")
            try ImageFile.write(encoded: png, to: url, protecting: [photo])
            return (url, mask)
        }
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
