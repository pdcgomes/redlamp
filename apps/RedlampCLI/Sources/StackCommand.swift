import Foundation
import RedlampDocument
import RedlampEngine
import RedlampEngineAPI

/// `redlamp stack`: merges a focus stack and writes the developed result.
enum StackCommand {
    static let usage = """
    usage: redlamp stack <frame> <frame> … -o <output.{jpg,png,tif,heic}> [options]
           redlamp stack <frame> <frame> … --save <stack.redlampstack> [-o <output>] [options]
           redlamp stack --detect <folder> …

    Frames are given in focus order (near to far or far to near); a directory means every
    image in it, sorted by name.

    options:
      --strategy <name>   auto (default), smooth or detail
      --size <pixels>     long edge of the output (default: full resolution)
      --depth <file>      also write the depth map (black = first frame, white = last)
      --every <n>         use every nth frame
      --json              print the report as JSON
      --save <file>       write a stack document (frames relative to its folder) and merge it
                          into the cache; open or render the document like any photo
    """

    static func run(_ arguments: [String]) async throws {
        let parsed = try Arguments(
            arguments,
            valued: ["--output", "--strategy", "--size", "--depth", "--every", "--save"],
        )
        guard !parsed.has("--help") else {
            print(usage)
            return
        }
        if parsed.has("--detect") {
            detect(parsed.positional)
            return
        }
        let strategyName = parsed.value("--strategy") ?? FocusStackStrategy.auto.rawValue
        guard let strategy = FocusStackStrategy(rawValue: strategyName) else {
            throw CLIError(description: "unknown strategy \(strategyName)")
        }
        let every = try max(1, parsed.int("--every") ?? 1)
        let frames = try parsed.positional.flatMap(expand).enumerated().filter { $0.offset % every == 0 }.map(\.element)
        guard frames.count >= 2
        else { throw CLIError(description: "a focus stack needs at least two frames\n\n\(usage)") }

        if let save = parsed.value("--save") {
            try await saveDocument(frames, strategy: strategy, to: URL(fileURLWithPath: save), parsed: parsed)
            return
        }
        guard let output = parsed.value("--output") else { throw CLIError(description: usage) }
        let engine = try RedlampEngine()
        let clock = ContinuousClock()
        let start = clock.now
        let preview = try await engine.renderFocusStack(
            frames, strategy: strategy, maxLongEdge: parsed.int("--size"),
            progress: { fraction in
                FileHandle.standardError.write(Data(String(format: "\r%3.0f%%", fraction * 100).utf8))
            },
        )
        FileHandle.standardError.write(Data("\r".utf8))
        try ImageFile.write(preview.image, to: URL(fileURLWithPath: output))
        if let depth = parsed.value("--depth") {
            try ImageFile.write(preview.depth, to: URL(fileURLWithPath: depth))
        }
        let report = preview.report
        if parsed.has("--json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try print(String(bytes: encoder.encode(report), encoding: .utf8) ?? "")
            return
        }
        let phases = ["decode", "align", "depth", "fuse"].compactMap { phase in
            report.timings[phase].map { String(format: "%@ %.1fs", phase, $0) }
        }
        print("""
        \(report.frames) frames → \(URL(fileURLWithPath: output).lastPathComponent) \
        \(preview.image.width)x\(preview.image.height), \(strategy.rawValue), reference frame \(report.reference + 1)
        scale change \(String(format: "%.2f%%", report.maximumScaleChange * 100)), \
        lowest correlation \(String(format: "%.3f", report.minimumCorrelation)), \
        confident depth \(String(format: "%.0f%%", report.confidentDepthFraction * 100))
        \(phases.joined(separator: ", ")); total \(clock.now - start)
        """)
    }

    /// Writes the document, opens it (merging into the cache unless already there) and renders
    /// it when an output is given.
    private static func saveDocument(
        _ frames: [URL], strategy: FocusStackStrategy, to url: URL, parsed: Arguments,
    ) async throws {
        try FocusStackDocument(frames: frames, strategy: strategy, at: url).write(to: url)
        let engine = try RedlampEngine()
        let clock = ContinuousClock()
        let start = clock.now
        let info = try await engine.open(url)
        print("\(url.lastPathComponent): \(info.pixelSize.width)x\(info.pixelSize.height) \(info.sensorDescription), "
            + "open \(clock.now - start)")
        guard let output = parsed.value("--output") else { return }
        let request = try StillRequest(recipe: EditRecipe(), maxLongEdge: parsed.int("--size"), purpose: .export)
        try await ImageFile.write(engine.renderStill(request), to: URL(fileURLWithPath: output))
    }

    /// Prints the focus stacks the library would suggest in each folder.
    private static func detect(_ folders: [String]) {
        for folder in folders {
            let clock = ContinuousClock()
            let start = clock.now
            let images = Library.images(in: URL(fileURLWithPath: folder))
            let suggestions = StackDetector.suggestions(in: images)
            print("\(folder): \(images.count) images, \(suggestions.count) stacks (\(clock.now - start))")
            for suggestion in suggestions {
                let names = suggestion.frames.map(\.lastPathComponent)
                print("  \(names.count) frames: \(names.first ?? "") … \(names.last ?? "")")
            }
        }
    }

    /// A file, or every supported image in a directory sorted by name.
    private static func expand(_ path: String) throws -> [URL] {
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw CLIError(description: "no such file \(path)")
        }
        guard isDirectory.boolValue else { return [url] }
        let extensions: Set = [
            "arw",
            "raf",
            "cr2",
            "cr3",
            "nef",
            "dng",
            "orf",
            "rw2",
            "tif",
            "tiff",
            "jpg",
            "jpeg",
            "png",
        ]
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
