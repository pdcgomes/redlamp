import Foundation
import RedlampEngineAPI
import RedlampServices

/// `redlamp noise`: calibrates a camera's noise profile from calibration frames (DN-01), and
/// checks which noise the engine would use for a photo.
enum NoiseCommand {
    static let usage = """
    usage: redlamp noise calibrate <raw files…> [-o <profile.json>] [--source <text>]
           redlamp noise check <raw files…> [--profile <profile.json>]

    calibrate  fits a camera's noise at each ISO (photon transfer) from calibration frames shot
               alike in pairs: a flat, evenly lit surface out of focus, at several brightnesses
               per ISO from dark to nearly clipped, and bias frames with the lens capped at the
               shortest shutter speed. Frames are paired by ISO and level; each pair's difference
               cancels the scene and fixed-pattern noise. Writes the profile (by default
               noise-<make>-<model>.json); Redlamp ships the profiles in
               packages/RedlampServices/Resources/NoiseProfiles.
    check      prints, for each raw, the noise its file states (DNG), its camera's profile at its
               ISO and the measurement from the image, as green's a and b, and which one renders.
    """

    static func run(_ arguments: [String]) async throws {
        guard let command = arguments.first, command != "--help" else {
            print(usage)
            return
        }
        var files: [URL] = []
        var output: URL?
        var source = "calibration frames"
        var profile: URL?
        var index = 1
        func value() throws -> String {
            index += 1
            guard index < arguments.count
            else { throw CLIError(description: "missing value for \(arguments[index - 1])") }
            return arguments[index]
        }
        while index < arguments.count {
            switch arguments[index] {
            case "-o", "--output": output = try URL(fileURLWithPath: value())
            case "--source": source = try value()
            case "--profile": profile = try URL(fileURLWithPath: value())
            default: files.append(URL(fileURLWithPath: arguments[index]))
            }
            index += 1
        }
        guard !files.isEmpty else { throw CLIError(description: usage) }
        switch command {
        case "calibrate":
            try calibrate(files, output: output, source: source)
        case "check":
            let catalog = try profile.map { url in
                try NoiseProfileCatalog(profiles: [JSONDecoder().decode(
                    CameraNoiseProfile.self,
                    from: Data(contentsOf: url),
                )])
            } ?? .bundled
            try check(files, catalog: catalog)
        default:
            throw CLIError(description: usage)
        }
    }

    private static func calibrate(_ files: [URL], output: URL?, source: String) throws {
        var summaries: [NoiseCalibration.FrameSummary] = []
        var camera: (make: String, model: String)?
        for file in files {
            let image = try ImageDecoder.decode(file)
            guard let summary = NoiseCalibration.FrameSummary(image) else {
                throw CLIError(description: "\(file.lastPathComponent) has no ISO or isn't a raw")
            }
            let make = image.info.make ?? "", model = image.info.model ?? ""
            if let camera, camera != (make, model) {
                throw CLIError(
                    description: "\(file.lastPathComponent) is from a \(make) \(model), not a \(camera.make) \(camera.model)",
                )
            }
            camera = (make, model)
            summaries.append(summary)
        }
        let pairs = NoiseCalibration.pairs(summaries)
        guard let camera, !pairs.isEmpty else { throw CLIError(description: "no frames shot alike to pair") }
        var measurements: [Double: (pairs: Int, tiles: [[NoiseCalibration.Measurement]])] = [:]
        for (first, second) in pairs {
            let iso = summaries[first].iso.rounded()
            let tiles = try NoiseCalibration.measure(
                ImageDecoder.decode(files[first]),
                ImageDecoder.decode(files[second]),
            )
            var entry = measurements[iso] ?? (0, [[], [], []])
            entry.pairs += 1
            for channel in 0 ..< 3 {
                entry.tiles[channel] += tiles[channel]
            }
            measurements[iso] = entry
        }
        var points: [CameraNoiseProfile.Point] = []
        print("ISO     pairs  tiles   a (R, G, B)                      b (R, G, B)")
        for (iso, entry) in measurements.sorted(by: { $0.key < $1.key }) {
            guard let point = NoiseCalibration.point(iso: iso, pairs: entry.pairs, measurements: entry.tiles) else {
                print(String(
                    format: "%-7.0f %5d  too few levels to fit: shoot brighter and darker pairs",
                    iso,
                    entry.pairs,
                ))
                continue
            }
            points.append(point)
            print(String(
                format: "%-7.0f %5d %6d   %.3e %.3e %.3e   %.3e %.3e %.3e", iso, point.pairs, point.tiles,
                point.a.x, point.a.y, point.a.z, point.b.x, point.b.y, point.b.z,
            ))
        }
        guard !points.isEmpty else { throw CLIError(description: "no ISO could be fitted") }
        let profile = CameraNoiseProfile(make: camera.make, model: camera.model, source: source, points: points)
        let slug = "\(camera.make)-\(camera.model)".lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let url = output ?? URL(fileURLWithPath: "noise-\(slug).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profile).write(to: url)
        print("wrote \(url.path)")
    }

    private static func check(_ files: [URL], catalog: NoiseProfileCatalog) throws {
        func describe(_ model: NoiseModel?) -> String {
            model.map { String(format: "%.3e %.3e", $0.a.y, $0.b.y) } ?? "—"
        }
        func column(_ text: String, _ width: Int) -> String {
            text.count >= width ? text + " " : text.padding(toLength: width, withPad: " ", startingAt: 0)
        }
        let widths = [max(files.map(\.lastPathComponent.count).max() ?? 0, 5) + 2, 7, 23, 23, 23]
        let header = ["photo", "ISO", "file", "profile", "measured"]
        print(zip(header, widths).map(column).joined() + "renders")
        for file in files {
            let image = try ImageDecoder.decode(file)
            let measured = NoiseEstimator.estimate(image)
            let profiled = catalog.model(for: image.info)
            let used = image.noise(profiles: catalog)
            let source = used == image.noiseProfile ? "file" : used == profiled ? "profile" : "measured"
            let iso = image.info.iso.map { String(Int($0.rounded())) } ?? "—"
            let cells = [
                file.lastPathComponent,
                iso,
                describe(image.noiseProfile),
                describe(profiled),
                describe(measured),
            ]
            print(zip(cells, widths).map(column).joined() + source)
        }
    }
}
