import CoreGraphics
import Foundation
import ImageIO
import RedlampEngine
import RedlampEngineAPI
import RedlampRecipes
import UniformTypeIdentifiers

/// `redlamp mcp`: the engine and recipe library as a Model Context Protocol server over
/// stdin/stdout (newline-delimited JSON-RPC 2.0), for the agent studio and for hands-on
/// sessions in Cursor. Every file it writes goes under `build/recipe-runs/<run>/`.
final class MCPServer {
    static let protocolVersion = "2025-06-18"

    private let library = RecipeLibrary()
    private var tools: RecipeRenderer?
    private let output = FileHandle.standardOutput

    func run() async throws {
        log("redlamp mcp ready (root \(Repository.root.path))")
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "parse error"]])
                continue
            }
            let id = message["id"]
            let method = message["method"] as? String ?? ""
            let params = message["params"] as? [String: Any] ?? [:]
            guard let id else { continue } // Notifications need no reply.
            do {
                let result = try await handle(method, params)
                send(["jsonrpc": "2.0", "id": id, "result": result])
            } catch let error as RPCError {
                send(["jsonrpc": "2.0", "id": id, "error": ["code": error.code, "message": error.message]])
            } catch {
                send(["jsonrpc": "2.0", "id": id, "error": ["code": -32603, "message": "\(error)"]])
            }
        }
    }

    struct RPCError: Error {
        var code: Int
        var message: String
    }

    private func handle(_ method: String, _ params: [String: Any]) async throws -> Any {
        switch method {
        case "initialize":
            return [
                "protocolVersion": Self.protocolVersion,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "redlamp", "version": "1"],
                "instructions": """
                Redlamp's rendering engine and recipe library. Recipes are JSON (see the schema tool); \
                render, compare and contact_sheet return images. Pass `run` to keep outputs in \
                build/recipe-runs/<run>/.
                """,
            ]
        case "ping":
            return [String: Any]()
        case "tools/list":
            return ["tools": Self.toolList]
        case "tools/call":
            guard let name = params["name"] as? String
            else { throw RPCError(code: -32602, message: "missing tool name") }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                return try await call(name, arguments)
            } catch {
                return ["content": [["type": "text", "text": "error: \(error)"]], "isError": true]
            }
        default:
            throw RPCError(code: -32601, message: "unknown method \(method)")
        }
    }

    // MARK: - Tools

    private static func tool(
        _ name: String,
        _ description: String,
        _ properties: [String: Any],
        required: [String] = [],
    ) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required],
        ]
    }

    private static var recipeArgument: [String: Any] {
        [
            "description": "A recipe id (redlamp/essentials/punchy), a .redrecipe path, or an inline recipe object (see schema).",
        ]
    }

    private static var runArgument: [String: Any] {
        ["type": "string", "description": "Run id; outputs go to build/recipe-runs/<run>/."]
    }

    static var toolList: [[String: Any]] {
        [
            tool(
                "schema",
                "Every parameter (key, range, default, group), the setting groups, film slots and Base Looks, and the recipe JSON shape.",
                [:],
            ),
            tool(
                "list_images",
                "The look-development images (by scene category), the lint chart, and the decode fixtures.",
                [
                    "category": [
                        "type": "string",
                        "description": "portrait, landscape, sky, foliage, night, tungsten, high-dynamic-range, street, monochrome",
                    ],
                ],
            ),
            tool("list_recipes", "Recipes in the library.", ["query": ["type": "string"]]),
            tool("render", "Render a recipe on an image; returns the image.", [
                "recipe": recipeArgument, "image": ["type": "string", "description": "Path, or `chart`."],
                "size": ["type": "integer"], "amount": ["type": "number"], "run": runArgument,
            ], required: ["recipe", "image"]),
            tool("contact_sheet", "Render recipes (columns) on images (rows); returns the sheet.", [
                "recipes": ["type": "array", "items": recipeArgument], "images": [
                    "type": "array",
                    "items": ["type": "string"],
                ],
                "original": ["type": "boolean"], "tile": ["type": "integer"], "run": runArgument,
            ], required: ["recipes"]),
            tool("compare", "Two recipes side by side on one image, for pairwise judging.", [
                "a": recipeArgument, "b": recipeArgument, "image": ["type": "string"], "run": runArgument,
            ], required: ["a", "b", "image"]),
            tool(
                "fingerprint",
                "Style fingerprint of images, or of a recipe's renders over images; optional distance to a target.",
                [
                    "images": ["type": "array", "items": ["type": "string"]], "recipe": recipeArgument,
                    "target": ["type": "object", "description": "A fingerprint to measure distance to."],
                ],
                required: ["images"],
            ),
            tool(
                "fit_to_fingerprint",
                "Search recipe settings (and optionally a look table) towards a target fingerprint.",
                [
                    "references": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Reference images defining the target.",
                    ],
                    "target": ["type": "object"], "images": ["type": "array", "items": ["type": "string"]],
                    "start": recipeArgument, "name": ["type": "string"], "lut": ["type": "boolean"],
                    "evaluations": ["type": "integer"], "seed": ["type": "integer"], "run": runArgument,
                    "brief": ["type": "string"],
                ],
            ),
            tool(
                "lint",
                "Deterministic quality checks: neutral axis, skin hue, monotonic luminance, banding, clipping.",
                [
                    "recipe": recipeArgument,
                ],
                required: ["recipe"],
            ),
            tool("save_candidate", "Save a candidate recipe in a run, with lineage; renders its contact sheet.", [
                "run": runArgument, "recipe": recipeArgument, "id": ["type": "string"], "brief": ["type": "string"],
                "parent": ["type": "string"], "iteration": ["type": "integer"], "origin": ["type": "string"],
                "notes": ["type": "string"], "images": ["type": "array", "items": ["type": "string"]],
            ], required: ["run", "recipe"]),
        ]
    }

    private func renderer() throws -> RecipeRenderer {
        if let tools {
            return tools
        }
        let created = try RecipeRenderer(engine: RedlampEngine(), library: library)
        tools = created
        return created
    }
}

// MARK: - Tool implementations

extension MCPServer {
    private func call(_ name: String, _ args: [String: Any]) async throws -> [String: Any] {
        switch name {
        case "schema", "list_images", "list_recipes": try catalogTool(name, args)
        case "render", "contact_sheet", "compare": try await renderingTool(name, args)
        default: try await studioTool(name, args)
        }
    }

    private func catalogTool(_ name: String, _ args: [String: Any]) throws -> [String: Any] {
        switch name {
        case "schema":
            return try text(schema())

        case "list_images":
            let category = args["category"] as? String
            var entries: [[String: Any]] = []
            if let manifest = LookDev.manifest() {
                let folder = Repository.root.appendingPathComponent("build/look-dev")
                for image in manifest.images where category == nil || image.categories.contains(category!) {
                    let path = folder.appendingPathComponent(image.file).path
                    entries.append([
                        "path": path,
                        "camera": image.camera,
                        "categories": image.categories,
                        "downloaded": FileManager.default.fileExists(atPath: path),
                    ])
                }
            }
            let fixtures = LookDev.images().map(\.path)
            return try text(json(["lookDev": entries, "available": fixtures, "chart": RecipeChart.fileURL().path]))

        case "list_recipes":
            let recipes = library.search(args["query"] as? String ?? "")
            return text(json(recipes.map { [
                "id": $0.id,
                "version": $0.version,
                "name": $0.name,
                "group": $0.group,
                "summary": $0.summary ?? "",
                "tags": $0.tags,
                "usesLookTable": $0.usesLookTable,
            ] }))

        default:
            throw RPCError(code: -32602, message: "unknown tool \(name)")
        }
    }

    private func renderingTool(_ name: String, _ args: [String: Any]) async throws -> [String: Any] {
        switch name {
        case "render":
            let recipe = try recipe(args["recipe"])
            let image = try imageURL(args["image"])
            let rendered = try await renderer().render(
                recipe, image: image, maxLongEdge: args["size"] as? Int ?? 1024,
                amount: args["amount"] as? Double ?? 100,
            )
            let url = try outputURL(
                run: args["run"],
                name: "render-\(slug(recipe.name))-\(image.deletingPathExtension().lastPathComponent)",
            )
            try ImageFile.write(rendered, to: url)
            return imageResult(rendered, path: url)

        case "contact_sheet":
            var recipes: [Recipe?] = try (args["recipes"] as? [Any] ?? []).map(recipe)
            if args["original"] as? Bool == true {
                recipes.insert(nil, at: 0)
            }
            let images = try (args["images"] as? [String])
                .map { try $0.map(imageURL) } ?? Array(LookDev.images().prefix(6))
            let sheet = try await renderer().contactSheet(
                recipes: recipes,
                images: images,
                tile: args["tile"] as? Int ?? 240,
            )
            let url = try outputURL(run: args["run"], name: "sheet-\(UUID().uuidString.prefix(8))")
            try ImageFile.write(sheet, to: url)
            return imageResult(sheet, path: url)

        case "compare":
            let a = try recipe(args["a"]), b = try recipe(args["b"])
            let image = try imageURL(args["image"])
            let sheet = try await renderer().compare(a, b, image: image, tile: 512)
            let url = try outputURL(run: args["run"], name: "compare-\(slug(a.name))-vs-\(slug(b.name))")
            try ImageFile.write(sheet, to: url)
            return imageResult(sheet, path: url)

        default:
            throw RPCError(code: -32602, message: "unknown tool \(name)")
        }
    }

    private func studioTool(_ name: String, _ args: [String: Any]) async throws -> [String: Any] {
        switch name {
        case "fingerprint":
            let images = try (args["images"] as? [String] ?? []).map(imageURL)
            let print: StyleFingerprint = if let recipeArgument = args["recipe"] {
                try await StyleFitter(renderer: renderer(), images: images).fingerprint(of: recipe(recipeArgument))
            } else {
                try StyleFingerprint.average(images.map(fingerprint(of:)))
            }
            var result: [String: Any] = try [
                "fingerprint": jsonObject(print),
                "summary": print.summary,
                "vector": print.vector,
            ]
            if let target = args["target"] {
                result["distance"] = try print.distance(to: decode(StyleFingerprint.self, from: target))
            }
            return text(json(result))

        case "fit_to_fingerprint":
            let target: StyleFingerprint
            if let given = args["target"] {
                target = try decode(StyleFingerprint.self, from: given)
            } else {
                let references = try (args["references"] as? [String] ?? []).map(imageURL)
                guard !references.isEmpty else { throw RPCError(code: -32602, message: "pass references or target") }
                target = try StyleFingerprint.average(references.map(fingerprint(of:)))
            }
            let images = try (args["images"] as? [String])
                .map { try $0.map(imageURL) } ?? Array(LookDev.images().prefix(6))
            let start = try args["start"].map(recipe)
            let result = try await StyleFitter(renderer: renderer(), images: images).fit(
                to: target, name: args["name"] as? String ?? "Fitted Look", start: start,
                useLookTable: args["lut"] as? Bool ?? false, evaluations: args["evaluations"] as? Int ?? 120,
                seed: UInt64(args["seed"] as? Int ?? 1),
            )
            var payload: [String: Any] = try [
                "distance": result.distance, "startDistance": result.startDistance, "evaluations": result.evaluations,
                "recipe": jsonObject(result.recipe),
            ]
            if let run = args["run"] as? String {
                let candidate = try await save(
                    result.recipe,
                    run: run,
                    args: args.merging(["origin": "fit"]) { a, _ in a },
                    distance: result.distance,
                )
                payload["candidate"] = candidate.id
            }
            return text(json(payload))

        case "lint":
            let recipe = try recipe(args["recipe"])
            let results = try await renderer().lint(recipe)
            return text(json([
                "overall": RecipeLint.overall(results).rawValue,
                "checks": results.map { [
                    "check": $0.check.rawValue,
                    "status": $0.status.rawValue,
                    "value": $0.value,
                    "detail": $0.detail,
                ] },
            ]))

        case "save_candidate":
            guard let run = args["run"] as? String else { throw RPCError(code: -32602, message: "missing run") }
            let candidate = try await save(recipe(args["recipe"]), run: run, args: args, distance: nil)
            let store = RunStore.named(run, root: Repository.root)
            var result: [String: Any] = [
                "candidate": candidate.id,
                "recipe": store.recipeURL(for: candidate.id).path,
                "lint": candidate.lint ?? "",
            ]
            if let render = candidate.render {
                result["render"] = store.directory.appendingPathComponent(render).path
            }
            return text(json(result))

        default:
            throw RPCError(code: -32602, message: "unknown tool \(name)")
        }
    }

    private func save(_ recipe: Recipe, run: String, args: [String: Any], distance: Double?) async throws -> RecipeRun
        .Candidate {
        let store = RunStore.named(run, root: Repository.root)
        try store.prepare()
        let id = (args["id"] as? String).map(slug) ?? "c\(String(format: "%03d", store.candidates().count + 1))"
        let tools = try renderer()
        let lint = try await tools.lint(recipe)
        let images = try (args["images"] as? [String]).map { try $0.map(imageURL) } ?? Array(LookDev.images().prefix(6))
        var renderPath: String?
        if !images.isEmpty {
            let sheet = try await tools.contactSheet(recipes: [nil, recipe], images: images, tile: 240)
            let name = "\(id)-sheet.jpg"
            try ImageFile.write(sheet, to: store.renderURL(name), quality: 0.88)
            renderPath = "renders/\(name)"
        }
        let candidate = RecipeRun.Candidate(
            id: id, brief: args["brief"] as? String, parent: args["parent"] as? String,
            iteration: args["iteration"] as? Int ?? 0, origin: args["origin"] as? String ?? "colorist",
            notes: args["notes"] as? String, lint: RecipeLint.overall(lint).rawValue, fingerprintDistance: distance,
            render: renderPath,
        )
        var named = recipe
        if !named.isLocal {
            named.id = "local/\(run)/\(id)"
        }
        return try store.save(named, as: candidate)
    }

    // MARK: - Arguments

    private func recipe(_ value: Any?) throws -> Recipe {
        if let spec = value as? String {
            return try library.resolve(spec)
        }
        guard var object = value as? [String: Any] else { throw RPCError(
            code: -32602,
            message: "recipe must be an id, path or object",
        ) }
        if object["id"] == nil {
            object["id"] = "local/agent/\(UUID().uuidString.lowercased())"
        }
        if object["name"] == nil {
            object["name"] = "Candidate"
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        let (recipe, _) = try RecipeValidator.decode(data)
        return recipe
    }

    private func imageURL(_ value: Any?) throws -> URL {
        guard let path = value as? String else { throw RPCError(code: -32602, message: "image must be a path") }
        if path == "chart" {
            return try RecipeChart.fileURL()
        }
        let url = URL(fileURLWithPath: path, relativeTo: Repository.root)
        guard FileManager.default.fileExists(atPath: url.path) else { throw RPCError(
            code: -32602,
            message: "no image at \(path)",
        ) }
        return url.standardizedFileURL
    }

    private func fingerprint(of url: URL) throws -> StyleFingerprint {
        let image: CGImage
        if SupportedFormats.isSupported(url),
           !["jpg", "jpeg", "png", "tif", "tiff", "heic"].contains(url.pathExtension.lowercased()) {
            throw RPCError(
                code: -32602,
                message: "fingerprint raw files through a recipe render instead: \(url.lastPathComponent)",
            )
        }
        image = try ImageFile.read(url)
        guard let pixels = PixelImage(image, maxLongEdge: StyleFingerprint.analysisSize) else {
            throw RPCError(code: -32602, message: "cannot read \(url.path)")
        }
        return StyleFingerprint(pixels)
    }

    private func outputURL(run: Any?, name: String) throws -> URL {
        let store = RunStore.named(run as? String ?? "adhoc", root: Repository.root)
        try store.prepare()
        return store.renderURL("\(name).jpg")
    }

    private func slug(_ text: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")
        return String(text.lowercased().map { allowed.contains($0) ? $0 : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    // MARK: - Results

    private func schema() throws -> String {
        let global = ParameterCatalog.all
            .filter { !$0.id.isMaskScoped && !$0.id.isSpotScoped && !$0.id.isPointColorScoped }
        let parameters = global.map { spec -> [String: Any] in
            [
                "key": spec.id.rawValue, "label": spec.label, "min": spec.range.lowerBound,
                "max": spec.range.upperBound,
                "default": spec.defaultValue,
                "group": RecipeSettingGroup(parameter: spec.id)?.rawValue ?? "not-in-recipes",
                "renders": spec.availability.isLive,
            ]
        }
        return json([
            "parameters": parameters,
            "settingGroups": RecipeSettingGroup.allCases.map(\.rawValue),
            "filmSlots": FilmSlot.allCases.map { ["slot": $0.rawValue, "name": $0.name, "summary": $0.summary] },
            "baseLooks": library.baseLooks.map { [
                "id": $0.id,
                "version": $0.version,
                "name": $0.name,
                "summary": $0.summary ?? "",
                "reference": (try? jsonObject($0.reference)) ?? [:],
            ] },
            "recipeShape": [
                "name": "string", "includes": "[setting group]",
                "settings": [
                    "values": "{parameter key: number}",
                    "treatment": "color|blackAndWhite",
                    "whiteBalance": "asShot|auto|daylight|…|custom",
                    "pointCurve": "[{x,y}] in 0…1",
                ],
                "baseLook": "a baseLooks[].reference, optionally with amount 0…200",
            ],
            "notes": "Only parameters of included groups are kept; unlisted ones in an included group take their default.",
        ])
    }

    private func imageResult(_ image: CGImage, path: URL) -> [String: Any] {
        var content: [[String: Any]] = [["type": "text", "text": "saved \(path.path) (\(image.width)×\(image.height))"]]
        if let data = jpeg(image, maxLongEdge: 1280) {
            content.append(["type": "image", "data": data.base64EncodedString(), "mimeType": "image/jpeg"])
        }
        return ["content": content]
    }

    private func jpeg(_ image: CGImage, maxLongEdge: Int) -> Data? {
        var source = image
        if max(image.width, image.height) > maxLongEdge, let pixels = PixelImage(image, maxLongEdge: maxLongEdge),
           let scaled = pixels.cgImage() {
            source = scaled
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination,
            source,
            [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary,
        )
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private func text(_ string: String) -> [String: Any] {
        ["content": [["type": "text", "text": string]]]
    }

    private func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes],
        ) else {
            return "\(value)"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func jsonObject(_ value: some Encodable) throws -> Any {
        try JSONSerialization.jsonObject(with: RecipeFile.encoder.encode(value))
    }

    private func decode<T: Decodable>(_ type: T.Type, from value: Any) throws -> T {
        try RecipeFile.decoder.decode(type, from: JSONSerialization.data(withJSONObject: value))
    }

    private func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])
        else { return }
        data.append(0x0A)
        output.write(data)
    }

    private func log(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}
