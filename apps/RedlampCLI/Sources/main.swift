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
       redlamp mcp                  the engine as an MCP server on stdin/stdout

options:
  --size <pixels>          long edge of the output (default: full resolution)
  --set <name>=<value>     set a parameter, e.g. --set exposure=0.5 --set basic.contrast=20
  --recipe <file.json>     start from a recipe (e.g. a .redlamp sidecar)
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
            let data = try Data(contentsOf: URL(fileURLWithPath: value()))
            if let sidecar = try? JSONDecoder().decode([String: EditRecipe].self, from: data),
               let stored = sidecar["recipe"] {
                recipe = stored
            } else {
                recipe = try JSONDecoder().decode(EditRecipe.self, from: data)
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
