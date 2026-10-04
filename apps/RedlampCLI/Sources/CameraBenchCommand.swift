import CoreGraphics
import Foundation
import ImageIO
import RedlampEngine
import RedlampEngineAPI
import RedlampRecipes
import RedlampServices
import UniformTypeIdentifiers

/// `redlamp camera-bench`: tests raw files against the JPEG their camera embedded (CAM-14), the
/// checks the app's Camera Bench window runs, and writes the report it would send.
enum CameraBenchCommand {
    static let usage = """
    usage: redlamp camera-bench <files or folders…> [-o report.json] [--pairs <dir>] [--per-mode <n>] [--all]
      Checks how each raw decodes, then compares Redlamp's default rendering with the JPEG the
      camera embedded (docs/camera-bench.md). Folders are searched for raws, and up to 8 photos per
      camera mode are chosen to cover the evidence checklist; --all tests every file.
      -o report.json   writes the report, as the app would send it (docs/camera-bench.schema.json)
      --pairs <dir>    writes each photo's pair, Redlamp's rendering beside the camera's, as JPEG
    """

    static func run(_ arguments: [String]) async throws {
        guard !arguments.isEmpty, !arguments.contains("--help") else {
            print(usage)
            return
        }
        var inputs: [URL] = []
        var output: URL?
        var pairs: URL?
        var perMode = 8
        var all = false
        var index = 0
        func value() throws -> String {
            index += 1
            guard index < arguments.count
            else { throw CLIError(description: "missing value for \(arguments[index - 1])") }
            return arguments[index]
        }
        while index < arguments.count {
            switch arguments[index] {
            case "-o", "--output": output = try URL(fileURLWithPath: value())
            case "--pairs": pairs = try URL(fileURLWithPath: value(), isDirectory: true)
            case "--per-mode": perMode = try Int(value()) ?? perMode
            case "--all": all = true
            default: inputs.append(URL(fileURLWithPath: arguments[index]))
            }
            index += 1
        }
        let files = rawFiles(in: inputs)
        guard !files.isEmpty else { throw CLIError(description: "no raw files in \(inputs.map(\.path))") }

        let engine = try RedlampEngine(decoder: InProcessDecoder(), lensProfiles: .user)
        let bench = CameraBench(engine: engine)
        let candidates = files.compactMap { url in engine.identify(url).map { CameraBenchSelection.Candidate(
            url: url,
            identity: $0,
        ) } }
        let groups = CameraBenchSelection.choose(candidates, perMode: all ? Int.max : perMode)
        let chosen = groups.flatMap(\.chosen)
        print("\(candidates.count) raw files in \(groups.count) camera modes; testing \(chosen.count)")
        if let pairs {
            try FileManager.default.createDirectory(at: pairs, withIntermediateDirectories: true)
        }

        var photos: [CameraBenchPhoto] = []
        for (number, url) in chosen.enumerated() {
            guard let result = await bench.run(url) else { continue }
            photos.append(result.photo)
            let problems = result.photo.checks.filter { $0.verdict >= .warn }
            let verdict = result.photo.verdict.rawValue.uppercased()
            print(
                "[\(number + 1)/\(chosen.count)] \(url.lastPathComponent)  \(result.photo.mode.camera), \(result.photo.mode.label)  \(verdict)",
            )
            for check in problems {
                let tracker = check.tracker.map { " (\($0))" } ?? ""
                print("    \(check.verdict.rawValue) \(check.id): \(check.summary)\(tracker)")
            }
            if let pairs, let image = pair(result) {
                try write(image, to: pairs.appending(path: url.deletingPathExtension().lastPathComponent + "-pair.jpg"))
            }
        }

        print("")
        for group in groups {
            let tested = photos.filter { $0.mode == group.mode }
            let worst = tested.map(\.verdict).max() ?? .skipped
            let met = Set(tested.flatMap(\.conditions))
            let missing = BenchCondition.allCases.filter { !met.contains($0) }.map(\.rawValue)
            print(
                "\(group.mode.camera), \(group.mode.label): \(tested.count) of \(group.candidates) tested, worst \(worst.rawValue)"
                    + (missing.isEmpty ? "" : "; not yet covered: \(missing.joined(separator: ", "))"),
            )
        }

        if let output {
            let info = Bundle.main.infoDictionary
            let report = CameraBenchReport(
                environment: bench.environment(
                    redlamp: info?["CFBundleShortVersionString"] as? String ?? "development",
                    commit: info?["RedlampCommit"] as? String,
                ),
                photos: photos,
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(report).write(to: output, options: .atomic)
            print("wrote \(output.path)")
        }
        if photos.contains(where: { $0.verdict == .fail }) {
            throw ExitCode(2)
        }
    }

    static func rawFiles(in inputs: [URL]) -> [URL] {
        inputs.flatMap { url -> [URL] in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
            guard isDirectory.boolValue else { return SupportedFormats.isRaw(url) ? [url] : [] }
            let found = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL } ?? []
            return found.filter(SupportedFormats.isRaw).sorted { $0.path < $1.path }
        }
    }

    /// Redlamp's rendering on the left, the camera's on the right, each fitted into the same height.
    static func pair(_ result: CameraBenchResult) -> CGImage? {
        let images = [result.ours, result.theirs].compactMap(\.self)
        guard !images.isEmpty else { return nil }
        let height = CameraBench.pairSize * 2 / 3
        let widths = images.map { Int((Double($0.width) / Double($0.height) * Double(height)).rounded()) }
        let gap = 12
        guard let context = CGContext(
            data: nil, width: widths.reduce(0, +) + gap * (images.count - 1), height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        ) else { return nil }
        context.setFillColor(gray: 0.12, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: height))
        var x = 0
        for (image, width) in zip(images, widths) {
            context.draw(image, in: CGRect(x: x, y: 0, width: width, height: height))
            x += width + gap
        }
        return context.makeImage()
    }

    static func write(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil,
        )
        else { throw CLIError(description: "can't write \(url.path)") }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary,
        )
        guard CGImageDestinationFinalize(destination) else { throw CLIError(description: "can't write \(url.path)") }
    }
}
