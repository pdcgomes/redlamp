import CoreGraphics
import Foundation
import ImageIO
import RedlampEngine
import RedlampEngineAPI
import UniformTypeIdentifiers

let usage = """
usage: redlamp info <image>
       redlamp render <image> -o <output.{jpg,png,tif,heic}> [options]
       redlamp recipe <command> …   recipes and look development (redlamp recipe help)
       redlamp stack <frames…> …    merge a focus stack (redlamp stack --help)
       redlamp mask <image> …       write an AI mask as a PNG (redlamp mask --help)
       redlamp mcp                  the engine as an MCP server on stdin/stdout

options:
  --size <pixels>          long edge of the output (default: full resolution)
  --set <name>=<value>     set a parameter, e.g. --set exposure=0.5 --set basic.contrast=20
  --recipe <file.json>     start from a recipe (e.g. a .redlamp sidecar, file or package)
  --mask <kind>            add an AI mask: subject, background, sky, people, or people:<part>
                           (faceSkin, bodySkin, eyebrows, eyeSclera, iris, lips, teeth, hair,
                           facialHair, clothes)
  --mask-set <name>=<v>    set a local adjustment of the last mask, e.g. --mask-set local.exposure=-1
  --mask-invert            invert the last mask's components
  --base-look <name>       color, neutral, vivid, landscape, portrait, monochrome (--profile works too)
  --wb <mode>              asShot, auto, daylight, cloudy, shade, tungsten, fluorescent, flash
  --bw                     black & white treatment
  --p3                     encode in Display P3 instead of sRGB
  --16bit                  16 bits per component (PNG/TIFF)
"""

struct CLIError: Error, CustomStringConvertible {
    let description: String
}

/// Accepts either the sidecar key (`basic.exposure`) or the Swift case name (`exposure`).
func parameter(named name: String) -> ParameterID? {
    ParameterID(rawValue: name) ?? ParameterID.allCases.first { "\($0)".lowercased() == name.lowercased() }
}

func run(_ arguments: [String]) async throws {
    guard arguments.count >= 2 else { throw CLIError(description: usage) }
    let command = arguments[0]
    let input = URL(fileURLWithPath: arguments[1])
    let engine = try RedlampEngine()
    let clock = ContinuousClock()

    let openStart = clock.now
    let info = try await engine.open(input)
    let openTime = clock.now - openStart

    if command == "info" {
        print("\(info.fileName): \(info.pixelSize.width)x\(info.pixelSize.height) \(info.sensorDescription)")
        print("camera: \(info.cameraName ?? "unknown")  lens: \(info.lens ?? "unknown")")
        print("capture: \(info.exposureSummary.joined(separator: "  "))")
        if let wb = info.asShotWhiteBalance {
            print("as shot: \(Int(wb.temperature)) K, tint \(String(format: "%+.0f", wb.tint))")
        }
        print("decode + pyramid: \(openTime)")
        return
    }
    guard command == "render" else { throw CLIError(description: usage) }

    var recipe = EditRecipe()
    var output: URL?
    var request = StillRequest(recipe: recipe, purpose: .export)
    var index = 2
    func value() throws -> String {
        index += 1
        guard index < arguments.count else { throw CLIError(description: "missing value for \(arguments[index - 1])") }
        return arguments[index]
    }
    while index < arguments.count {
        switch arguments[index] {
        case "-o", "--output":
            output = try URL(fileURLWithPath: value())
        case "--size":
            request.maxLongEdge = try Int(value())
        case "--recipe":
            let path = try URL(fileURLWithPath: value())
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory)
            let package = isDirectory.boolValue ? path : nil
            let data = try Data(contentsOf: package?.appending(path: "edit.json") ?? path)
            // A sidecar holds the edit under "recipe" beside its other fields.
            struct Stored: Decodable {
                var recipe: EditRecipe?
            }
            if let stored = try? JSONDecoder().decode(Stored.self, from: data).recipe {
                recipe = stored
            } else {
                recipe = try JSONDecoder().decode(EditRecipe.self, from: data)
            }
            if let package {
                recipe.loadMaskBitmaps { sha in try? Data(contentsOf: package.appending(path: "masks/\(sha).png")) }
            }
        case "--mask":
            let spec = try value().split(separator: ":").map(String.init)
            guard let kind = MaskKind(rawValue: spec[0]), kind.isAI else {
                throw CLIError(description: "unknown AI mask \(spec[0])")
            }
            let part = spec.count > 1 ? PersonPart(rawValue: spec[1]) : .entirePerson
            guard let part else { throw CLIError(description: "unknown person part \(spec[1])") }
            let masks = try await engine.computeMasks(MaskRequest(kind: kind, part: part))
            let name = kind == .people && part != .entirePerson ? part.name : kind.name
            recipe.masks.append(MaskLayer(name: name, components: masks.map { MaskComponent(shape: .ai($0)) }))
        case "--mask-set":
            let pair = try value().split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2, let id = parameter(named: pair[0]), id.isLocal, let number = Double(pair[1]),
                  !recipe.masks.isEmpty
            else {
                throw CLIError(description: "bad --mask-set \(arguments[index]) (it needs a --mask before it)")
            }
            recipe.masks[recipe.masks.count - 1][id] = number
        case "--mask-invert":
            guard !recipe.masks.isEmpty else { throw CLIError(description: "--mask-invert needs a --mask before it") }
            for index in recipe.masks[recipe.masks.count - 1].components.indices {
                recipe.masks[recipe.masks.count - 1].components[index].inverted.toggle()
            }
        case "--set":
            let pair = try value().split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2, let id = parameter(named: pair[0]), let number = Double(pair[1]) else {
                throw CLIError(description: "bad --set \(arguments[index])")
            }
            recipe[id] = number
        case "--profile", "--base-look":
            let name = try value()
            guard let look = BuiltInBaseLook(legacyID: name) ?? BuiltInBaseLook(legacyID: "redlamp.\(name)") else {
                throw CLIError(description: "unknown base look \(name)")
            }
            recipe.baseLook = look.reference
        case "--wb":
            let name = try value()
            guard let mode = WhiteBalanceMode(rawValue: name)
            else { throw CLIError(description: "unknown white balance \(name)") }
            recipe.whiteBalanceMode = mode
            var wb = mode.presetValue
            if mode == .auto {
                wb = await engine.autoWhiteBalance()
            }
            if let wb {
                recipe[.temperature] = wb.temperature
                recipe[.tint] = wb.tint
            }
        case "--bw":
            recipe.treatment = .blackAndWhite
        case "--p3":
            request.colorSpace = .displayP3
        case "--16bit":
            request.bitsPerComponent = 16
        default:
            throw CLIError(description: "unknown option \(arguments[index])\n\n\(usage)")
        }
        index += 1
    }
    guard let output else { throw CLIError(description: "missing -o <output>") }
    request.recipe = recipe

    let renderStart = clock.now
    let image = try await engine.renderStill(request)
    let renderTime = clock.now - renderStart

    let type: UTType = switch output.pathExtension.lowercased() {
    case "png": .png
    case "tif", "tiff": .tiff
    case "heic": .heic
    default: .jpeg
    }
    guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else {
        throw CLIError(description: "cannot write \(output.path)")
    }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw CLIError(description: "failed to write \(output.path)") }
    print(
        "\(info.fileName) → \(output.lastPathComponent) \(image.width)x\(image.height)  open \(openTime), render \(renderTime)",
    )
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    switch arguments.first {
    case "recipe":
        try await RecipeCommands.run(Array(arguments.dropFirst()))
    case "stack":
        try await StackCommand.run(Array(arguments.dropFirst()))
    case "mask":
        try await MaskCommand.run(Array(arguments.dropFirst()))
    case "mcp":
        try await MCPServer().run()
    default:
        try await run(arguments)
    }
} catch let exit as ExitCode {
    Foundation.exit(exit.code)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
