import Foundation
import RedlampEngine
import RedlampEngineAPI
import Testing
@testable import RedlampRecipes

/// The camera bench's report against `docs/camera-bench.schema.json`, the contract the relay and
/// the aggregator rely on: a report with every field validates, every key it writes is in the
/// schema and every key in the schema is written, and its JSON stays as recorded.
struct CameraBenchReportTests {
    static let root = CameraBenchTests.root
    static let schemaURL = root.appending(path: "docs/camera-bench.schema.json")
    static let goldenURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appending(path: "Golden/camera-bench-report.json")
    static let recording = ProcessInfo.processInfo.environment["REDLAMP_RECORD_BENCH_GOLDEN"] == "1"

    /// A report with every field the format has.
    static let report: CameraBenchReport = {
        let opened = CameraBenchPhoto(
            fileHash: String(repeating: "ab", count: 32), mode: CameraMode(identity: CameraBenchTests.identity),
            identity: {
                var identity = CameraBenchTests.identity
                identity.lens = "FE 24-70mm F2.8 GM II"
                identity.software = "ILCE-7M3 v4.01"
                identity.dngVersion = 0
                identity.exposureTime = 0.004
                identity.aperture = 8
                identity.focalLength = 35
                identity.previews = [PixelSize(width: 1616, height: 1080), PixelSize(width: 6000, height: 4000)]
                return identity
            }(),
            measurements: CameraBenchTests.healthy, asShotTemperature: 5600,
            checks: [
                CameraBenchChecks.opened(),
                BenchCheck(
                    id: "preview.cast", version: 1, verdict: .warn, measurements: ["cast": 4.5, "neutralSamples": 812],
                    summary: "A colour cast where the camera's is neutral (4.5).", tracker: "CAM-13",
                ),
            ],
            conditions: [.baseISO, .clippedHighlights], decodeSeconds: 0.84, renderSeconds: 0.31,
        )
        let refusedIdentity = RawFileIdentity(
            make: "NIKON CORPORATION",
            model: "NIKON Z 8",
            format: "NEF",
            refusal: "Unsupported file format",
        )
        let refused = CameraBenchPhoto(
            fileHash: String(repeating: "cd", count: 32), mode: CameraMode(identity: refusedIdentity),
            identity: refusedIdentity, measurements: nil, asShotTemperature: nil,
            checks: [CameraBenchChecks.refused(
                refusedIdentity,
                error: EngineError.notSupportedYet("Nikon's High Efficiency raw files (HE and HE*)", tracker: "CAM-12"),
            )],
            conditions: [], decodeSeconds: nil, renderSeconds: nil,
        )
        return CameraBenchReport(
            environment: CameraBenchEnvironment(
                redlamp: "0.2.2-prealpha", commit: "3b6a9de", decoder: "LibRaw 0.22.2-Release",
                processVersion: EditRecipe.currentProcessVersion, bench: CameraBench.version, system: "macOS 26.5",
                chip: "Apple M3 Max",
            ),
            photos: [opened, refused],
            answers: [CameraBenchAnswer(mode: opened.mode.key, choice: .same, note: "Shot in daylight.")],
            contributor: "8E2C1F4A-0B7D-4C3E-9A51-6D2F8B0E7C19", credit: "A. Photographer",
        )
    }()

    static func encoded(_ report: CameraBenchReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report)
    }

    static func validator() throws -> BenchSchema {
        try BenchSchema(JSONSerialization.jsonObject(with: Data(contentsOf: schemaURL)))
    }

    @Test func `a report with every field validates against the schema`() throws {
        let instance = try JSONSerialization.jsonObject(with: Self.encoded(Self.report))
        let errors = try Self.validator().errors(in: instance)
        #expect(errors.isEmpty, "\(errors)")
    }

    @Test func `every key the report writes is in the schema, and every key in the schema is written`() throws {
        let schema = try Self.validator()
        let instance = try JSONSerialization.jsonObject(with: Self.encoded(Self.report))
        let written = schema.writtenKeys(in: instance)
        #expect(
            schema.declaredKeys.subtracting(written).isEmpty,
            "never written: \(schema.declaredKeys.subtracting(written).sorted())",
        )
    }

    @Test func `the schema refuses a report carrying anything else`() throws {
        var instance = try #require(try JSONSerialization.jsonObject(with: Self.encoded(Self.report)) as? [String: Any])
        var photos = try #require(instance["photos"] as? [[String: Any]])
        photos[0]["fileName"] = "DSC00042.ARW"
        instance["photos"] = photos
        #expect(try !Self.validator().errors(in: instance).isEmpty)
    }

    @Test func `the report's JSON stays as recorded`() throws {
        let data = try Self.encoded(Self.report)
        if Self.recording || !FileManager.default.fileExists(atPath: Self.goldenURL.path) {
            try FileManager.default.createDirectory(
                at: Self.goldenURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            try data.write(to: Self.goldenURL)
        }
        #expect(try String(decoding: Data(contentsOf: Self.goldenURL), as: UTF8.self) == String(
            decoding: data,
            as: UTF8.self,
        ))
        #expect(try JSONDecoder().decode(CameraBenchReport.self, from: data) == Self.report)
    }

    @Test(.enabled(if: CameraBenchTests.canRender && !CameraBenchTests.verified.isEmpty))
    func `a report from a real photo validates`() async throws {
        let url = try #require(CameraBenchTests.verified.first)
        let bench = try CameraBench(engine: RedlampEngine())
        let photo = try #require(await bench.run(url)).photo
        let report = CameraBenchReport(
            environment: bench.environment(redlamp: "development", commit: nil),
            photos: [photo],
        )
        let instance = try JSONSerialization.jsonObject(with: Self.encoded(report))
        #expect(try Self.validator().errors(in: instance).isEmpty)
    }
}

/// The subset of JSON Schema 2020-12 the bench's schema uses; any other constraining keyword
/// is an error, so the schema can't come to rely on one this ignores.
struct BenchSchema {
    static let keywords: Set = [
        "$ref", "type", "enum", "const", "minimum", "maximum", "pattern", "maxLength", "properties",
        "additionalProperties", "required", "maxProperties", "items", "minItems", "maxItems",
    ]
    static let annotations: Set = ["$schema", "$id", "$defs", "title", "description"]

    let root: [String: Any]

    init(_ schema: Any) throws {
        root = try #require(schema as? [String: Any])
    }

    func resolve(_ reference: String) -> Any {
        reference.dropFirst(2).split(separator: "/")
            .reduce(root as Any) { ($0 as? [String: Any])?[String($1)] ?? false }
    }

    func errors(in value: Any, against schema: Any? = nil, at path: String = "") -> [String] {
        guard let keywords = (schema ?? root) as? [String: Any] else {
            return (schema as? Bool) == true ? [] : ["\(path): not allowed here"]
        }
        var errors = keywords.keys.filter { !Self.keywords.contains($0) && !Self.annotations.contains($0) }
            .map { "\(path): unsupported keyword \($0)" }
        if let reference = keywords["$ref"] as? String {
            errors += self.errors(in: value, against: resolve(reference), at: path)
        }
        if let type = keywords["type"] as? String, !Self.value(value, isOf: type) {
            errors.append("\(path): isn't of type \(type)")
        }
        if let options = keywords["enum"] as? [Any], !options.contains(where: { Self.same($0, value) }) {
            errors.append("\(path): isn't one of its enum")
        }
        if let constant = keywords["const"], !Self.same(constant, value) {
            errors.append("\(path): isn't \(constant)")
        }
        if let number = value as? NSNumber {
            if let minimum = keywords["minimum"] as? Double,
               number.doubleValue < minimum {
                errors.append("\(path): below minimum")
            }
            if let maximum = keywords["maximum"] as? Double,
               number.doubleValue > maximum {
                errors.append("\(path): above maximum")
            }
        }
        if let text = value as? String {
            if let pattern = keywords["pattern"] as? String,
               text.range(of: pattern, options: .regularExpression) == nil {
                errors.append("\(path): doesn't match \(pattern)")
            }
            if let length = keywords["maxLength"] as? Int,
               text.count > length {
                errors.append("\(path): longer than \(length)")
            }
        }
        if let items = value as? [Any] {
            if let minimum = keywords["minItems"] as? Int,
               items.count < minimum {
                errors.append("\(path): too few items")
            }
            if let maximum = keywords["maxItems"] as? Int,
               items.count > maximum {
                errors.append("\(path): too many items")
            }
            for (index, item) in items.enumerated() {
                if let schema = keywords["items"] {
                    errors += self.errors(in: item, against: schema, at: "\(path)/\(index)")
                }
            }
        }
        if let object = value as? [String: Any] {
            for key in keywords["required"] as? [String] ?? [] where object[key] == nil {
                errors.append("\(path): \(key) is missing")
            }
            if let maximum = keywords["maxProperties"] as? Int,
               object.count > maximum {
                errors.append("\(path): too many keys")
            }
            let properties = keywords["properties"] as? [String: Any] ?? [:]
            for (key, child) in object {
                if let schema = properties[key] {
                    errors += self.errors(in: child, against: schema, at: "\(path)/\(key)")
                } else if let additional = keywords["additionalProperties"] {
                    errors += self.errors(in: child, against: additional, at: "\(path)/\(key)")
                }
            }
        }
        return errors
    }

    /// Every property the schema declares, as "definition key".
    var declaredKeys: Set<String> {
        var keys: Set<String> = []
        func visit(_ schema: Any, _ name: String) {
            guard let object = schema as? [String: Any] else { return }
            for key in (object["properties"] as? [String: Any] ?? [:]).keys {
                keys.insert("\(name) \(key)")
            }
            for (key, child) in object["properties"] as? [String: Any] ?? [:] {
                visit(child, "\(name).\(key)")
            }
        }
        visit(root, "#")
        for (name, definition) in root["$defs"] as? [String: Any] ?? [:] {
            visit(definition, name)
        }
        return keys
    }

    /// The keys an instance holds, named as `declaredKeys` names them.
    func writtenKeys(in value: Any, against schema: Any? = nil, named name: String = "#") -> Set<String> {
        guard var keywords = (schema ?? root) as? [String: Any] else { return [] }
        var name = name
        if let reference = keywords["$ref"] as? String {
            name = String(reference.split(separator: "/").last ?? "")
            keywords = resolve(reference) as? [String: Any] ?? [:]
        }
        var keys: Set<String> = []
        if let items = value as? [Any], let schema = keywords["items"] {
            for item in items {
                keys.formUnion(writtenKeys(in: item, against: schema, named: name))
            }
        }
        if let object = value as? [String: Any], let properties = keywords["properties"] as? [String: Any] {
            for (key, child) in object where properties[key] != nil {
                keys.insert("\(name) \(key)")
                keys.formUnion(writtenKeys(in: child, against: properties[key], named: "\(name).\(key)"))
            }
        }
        return keys
    }

    static func value(_ value: Any, isOf type: String) -> Bool {
        switch type {
        case "object": value is [String: Any]
        case "array": value is [Any]
        case "string": value is String
        case "number": value is NSNumber
        case "integer": (value as? NSNumber).map { $0.doubleValue.rounded() == $0.doubleValue } ?? false
        default: false
        }
    }

    static func same(_ a: Any, _ b: Any) -> Bool {
        if let a = a as? NSNumber, let b = b as? NSNumber {
            return a == b
        }
        if let a = a as? String, let b = b as? String {
            return a == b
        }
        return false
    }
}
