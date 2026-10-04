import CoreGraphics
import Foundation
import ImageIO
import RedlampEngine
import RedlampEngineAPI
import RedlampRecipes
import RedlampServices
import UniformTypeIdentifiers

let usage = """
usage: redlamp info <image>
       redlamp render <image> -o <output.{jpg,png,tif,heic}> [options]
       redlamp recipe <command> …   recipes and look development (redlamp recipe help)
       redlamp stack <frames…> …    merge a focus stack (redlamp stack --help)
       redlamp mask <image> …       write an AI mask as a PNG (redlamp mask --help)
       redlamp noise <command> …    calibrate a camera's noise profile (redlamp noise --help)
       redlamp bench [files…]       time the engine and print the results as JSON (redlamp bench --help)
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
  --base-look <name>       color, neutral, vivid, landscape, portrait, monochrome, or embedded (the
                           camera profile's look a DNG carries); --profile works too
  --wb <mode>              asShot, auto, daylight, cloudy, shade, tungsten, fluorescent, flash
  --upright <mode>         auto, level, vertical or full, from the photo's own edges
  --heal <x>,<y>,<radius>  heal a spot (x, y 0...1 across the photo as shown, radius a fraction
                           of its height) from the best source nearby; --clone copies instead
  --heal-brush <x>,<y>,…,<radius>  the same along a brush stroke through the points; --clone-brush
  --remove <x>,<y>,<radius>  fill a spot from the photo around it (content-aware); --remove-brush
  --remove-dust <0…100>    heal the sensor dust found at this sensitivity (50 is the app's)
  --remove-found <things>  remove what's found by name, e.g. car or "trash,sign" (OWLv2 and Segment
                           Anything, from Settings › Models)
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

/// The engine renders only looks it has been given, so an edit's look from a recipe of yours
/// comes from the installed ones, as it does in the app.
func registerInstalledLook(_ reference: BaseLookReference, with engine: RedlampEngine) {
    if let look = RecipeLibrary().definition(for: reference) {
        engine.registerBaseLook(look)
    }
}

func run(_ arguments: [String]) async throws {
    guard arguments.count >= 2 else { throw CLIError(description: usage) }
    let command = arguments[0]
    let input = URL(fileURLWithPath: arguments[1])
    let engine = try RedlampEngine(decoder: InProcessDecoder(), lensProfiles: .user)
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
            if name == "embedded" {
                guard let embedded = info.embeddedBaseLook else {
                    throw CLIError(description: "\(info.fileName) embeds no camera profile look")
                }
                recipe.baseLook = embedded
                break
            }
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
        case "--upright":
            let name = try value()
            guard let mode = UprightMode(rawValue: name) else { throw CLIError(description: "unknown upright \(name)") }
            let started = clock.now
            let lines = await engine.detectLines()
            guard let solved = Transform(recipe: recipe).upright(
                mode, lines: lines, imageSize: info.pixelSize, orientation: recipe.orientation,
            ) else { throw CLIError(description: "too few straight edges for Upright in \(info.fileName)") }
            recipe[.transformVertical] = solved.vertical
            recipe[.transformHorizontal] = solved.horizontal
            recipe[.transformRotate] = solved.rotate
            recipe.crop = GeometryMap.constrained(
                recipe.crop, recipe: recipe, imageSize: info.pixelSize, lens: info.lensCorrection,
            )
            print(String(
                format: "upright %@: %d lines in %@, vertical %.1f, horizontal %.1f, rotate %.2f",
                name, lines.count, "\(clock.now - started)", solved.vertical, solved.horizontal, solved.rotate,
            ))
        case "--heal", "--clone", "--remove", "--heal-brush", "--clone-brush", "--remove-brush":
            let flag = arguments[index]
            let mode: RetouchSpot.Mode = flag.hasPrefix("--heal") ? .heal : flag.hasPrefix("--clone") ? .clone : .remove
            let numbers = try value().split(separator: ",").compactMap { Double($0) }
            let brush = flag.hasSuffix("-brush")
            let counted = brush ? numbers.count >= 5 && numbers.count % 2 == 1 : numbers.count == 3
            guard counted else {
                throw CLIError(description: "\(flag) needs \(brush ? "x,y pairs and a radius" : "x,y,radius")")
            }
            let points = stride(from: 0, to: numbers.count - 1, by: 2).map { ImagePoint(
                x: numbers[$0],
                y: numbers[$0 + 1],
            ) }
            var spot = RetouchSpot(
                mode: mode, center: points[0], source: points[0],
                stroke: points.dropFirst().map { ImagePoint(x: $0.x - points[0].x, y: $0.y - points[0].y) },
                radius: numbers[numbers.count - 1],
            )
            if mode.usesSource {
                guard let source = await engine.retouchSource(for: spot, recipe: recipe) else {
                    throw CLIError(description: "no source fits a spot at \(points[0].x), \(points[0].y)")
                }
                spot.source = source
                print(String(format: "%@ from %.3f, %.3f", mode.name.lowercased(), source.x, source.y))
            }
            recipe.spots.append(spot)
        case "--remove-dust":
            let sensitivity = try Double(value()) ?? 50
            let found = await engine.detectDust(recipe: recipe, sensitivity: sensitivity)
            for speck in found {
                var spot = RetouchSpot(center: speck.center, source: speck.center, radius: speck.radius)
                spot.source = await engine.retouchSource(for: spot, recipe: recipe) ?? speck.center
                recipe.spots.append(spot)
            }
            print(
                "dust: \(found.count) specks, \(found.prefix(8).map { String(format: "%.3f,%.3f", $0.center.x, $0.center.y) })",
            )
        case "--remove-found":
            let names = try Set(value().split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
            let known = await engine.thingsToFind()
            if let model = await engine.modelNeededToFind() {
                throw CLIError(description: "--remove-found needs \(model.name), from Redlamp's Settings › Models")
            }
            guard names.isSubset(of: known) else {
                throw CLIError(description: "--remove-found can find \(known.joined(separator: ", "))")
            }
            let found = try await engine.findThings(names, threshold: 0.25)
            for thing in found {
                let mask: AIMask
                do {
                    guard let first = try await engine.computeMasks(MaskRequest(kind: .objects, box: thing.box)).first
                    else { continue }
                    mask = first
                } catch MaskComputationError.nothingFound {
                    print(String(format: "skipped %@ %.2f: no shape found in its box", thing.thing, thing.score))
                    continue
                }
                // Grown by half a percent of the height, as the Healing tool grows a picked object.
                recipe.spots.append(RetouchSpot(
                    mode: .remove, center: mask.center, source: mask.center, region: mask, radius: 0.005,
                ))
            }
            for thing in found {
                print(String(
                    format: "found %@ %.2f at %.3f,%.3f %.3fx%.3f", thing.thing, thing.score,
                    thing.box.x, thing.box.y, thing.box.width, thing.box.height,
                ))
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
    registerInstalledLook(recipe.baseLook, with: engine)
    request.recipe = recipe

    let renderStart = clock.now
    let image = try await engine.renderStill(request)
    let renderTime = clock.now - renderStart

    try ImageFile.write(image, to: output, protecting: [input])
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
    case "noise":
        try await NoiseCommand.run(Array(arguments.dropFirst()))
    case "bench":
        try await BenchCommand.run(Array(arguments.dropFirst()))
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
