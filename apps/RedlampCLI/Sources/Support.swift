import CoreGraphics
import Foundation
import ImageIO
import RedlampDocument
import RedlampRecipes
import UniformTypeIdentifiers

/// `--name value` options, `--flag`s and positional arguments.
struct Arguments {
    private(set) var positional: [String] = []
    private var options: [String: [String]] = [:]
    private var flags: Set<String> = []

    /// Options that take a value; everything else starting with `--` is a flag.
    init(_ arguments: some Sequence<String>, valued: Set<String>) throws {
        var iterator = Array(arguments).makeIterator()
        while let argument = iterator.next() {
            let name = argument == "-o" ? "--output" : argument
            if name.hasPrefix("--") {
                if valued.contains(name) {
                    guard let value = iterator.next()
                    else { throw CLIError(description: "missing value for \(argument)") }
                    options[name, default: []].append(value)
                } else {
                    flags.insert(name)
                }
            } else {
                positional.append(argument)
            }
        }
    }

    func value(_ name: String) -> String? {
        options[name]?.last
    }

    func values(_ name: String) -> [String] {
        options[name] ?? []
    }

    func has(_ flag: String) -> Bool {
        flags.contains(flag)
    }

    func int(_ name: String) throws -> Int? {
        guard let text = value(name) else { return nil }
        guard let number = Int(text) else { throw CLIError(description: "\(name) needs a whole number") }
        return number
    }

    func double(_ name: String) throws -> Double? {
        guard let text = value(name) else { return nil }
        guard let number = Double(text) else { throw CLIError(description: "\(name) needs a number") }
        return number
    }
}

enum Repository {
    /// The checkout this tool runs in: `REDLAMP_ROOT`, or the first parent of the current
    /// directory holding `Workspace.swift`.
    static var root: URL {
        if let env = ProcessInfo.processInfo.environment["REDLAMP_ROOT"] {
            return URL(fileURLWithPath: env)
        }
        var url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Workspace.swift").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}

/// The look-development image set: `research/look-dev/manifest.json`, downloaded into
/// `build/look-dev/` by `mise run lookdev`; the decode fixtures when that's missing.
enum LookDev {
    static func manifest() -> LookDevSet? {
        LookDevSet.load(root: Repository.root)
    }

    static func images(category: String? = nil) -> [URL] {
        if let manifest = manifest() {
            let present = manifest.available(root: Repository.root, category: category).map(\.url)
            if !present.isEmpty {
                return present
            }
        }
        let fixtures = Repository.root.appendingPathComponent("tests/fixtures/raw")
        let files = (try? FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil)) ?? []
        return files.filter { ["arw", "raf", "cr3", "nef", "dng"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

enum ImageFile {
    /// Writes `image` to `url`, replacing any file there that isn't `source` or another photo.
    static func write(_ image: CGImage, to url: URL, quality: Double = 0.92, protecting source: URL? = nil) throws {
        let type: UTType = switch url.pathExtension.lowercased() {
        case "png": .png
        case "tif", "tiff": .tiff
        case "heic": .heic
        default: .jpeg
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try place(at: url, protecting: source) { temporary in
            guard let destination = CGImageDestinationCreateWithURL(
                temporary as CFURL, type.identifier as CFString, 1, nil,
            ) else {
                throw CLIError(description: "cannot write \(url.path)")
            }
            CGImageDestinationAddImage(
                destination,
                image,
                [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary,
            )
            guard CGImageDestinationFinalize(destination)
            else { throw CLIError(description: "failed to write \(url.path)") }
        }
    }

    /// Writes a file to `url` the way the app exports: beside it first, then moved into
    /// place, and never over `source` or another photo.
    static func place(at url: URL, protecting source: URL? = nil, writing: (URL) throws -> Void) throws {
        do {
            try ImageExporter.place(at: url, source: source, writing: writing)
        } catch let error as ExportError {
            throw CLIError(description: error.localizedDescription)
        }
    }

    static func read(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw CLIError(description: "cannot read \(url.path)") }
        return image
    }
}

extension RecipeLibrary {
    /// A recipe from a `.redrecipe` path, an id, or a bundled slug (`essentials/punchy`).
    func resolve(_ spec: String) throws -> Recipe {
        if FileManager.default.fileExists(atPath: spec) {
            return try RecipeFile.read(URL(fileURLWithPath: spec)).recipe
        }
        if let recipe = recipe(id: spec) ?? recipe(id: "redlamp/\(spec)") {
            return recipe
        }
        if let recipe = all.first(where: { $0.name.lowercased() == spec.lowercased() }) {
            return recipe
        }
        throw CLIError(description: "no recipe \(spec) (try `redlamp recipe list`)")
    }

    /// `all`, `group:Name`, or comma-separated specs.
    func resolveList(_ spec: String) throws -> [Recipe] {
        if spec == "all" {
            return all
        }
        if spec.hasPrefix("group:") {
            let group = spec.dropFirst("group:".count).lowercased()
            return all.filter { $0.group.lowercased() == group }
        }
        return try spec.split(separator: ",").map { try resolve(String($0)) }
    }
}

func printJSON(_ value: some Encodable) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    try print(String(decoding: encoder.encode(value), as: UTF8.self))
}
