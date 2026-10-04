import CoreGraphics
import Foundation
import RedlampEngine
import RedlampEngineAPI
import RedlampServices

/// `redlamp bench [--runs N] [files…]`: times the engine on each file and prints one JSON object of
/// metrics by ID (docs/performance/metrics.json), for scripts/perf-record.sh. Each measurement is
/// repeated after a warm-up; a metric's value is the median across files of each file's median,
/// with the slowest and fastest file and the runs' spread.
enum BenchCommand {
    static let usage = """
    usage: redlamp bench [--runs N] [files…]
      Times opening, rendering at Fit (with and without two gradient masks), rendering the whole
      photo at 1:1, and full-resolution exports (with and without noise reduction), and prints the
      results as JSON. Without files, every raw in tests/fixtures/raw. Release builds only.
    """

    private static let rawExtensions: Set<String> = ["arw", "cr2", "cr3", "nef", "raf", "dng", "orf", "rw2", "pef"]
    private static let warmUp = 3

    static func run(_ arguments: [String]) async throws {
        if arguments.contains("--help") {
            print(usage)
            return
        }
        #if DEBUG
            if !arguments.contains("--allow-debug") {
                throw CLIError(
                    description: "bench measures Release builds: build the redlamp scheme with CONFIGURATION=Release",
                )
            }
        #endif
        var runs = 7
        var files: [URL] = []
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--runs":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]), value > 0 else {
                    throw CLIError(description: "--runs needs a positive number\n\n\(usage)")
                }
                runs = value
            case "--allow-debug":
                break
            default:
                files.append(URL(fileURLWithPath: arguments[index]))
            }
            index += 1
        }
        if files.isEmpty {
            let folder = URL(fileURLWithPath: "tests/fixtures/raw")
            files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { rawExtensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        guard !files.isEmpty else { throw CLIError(description: "no raw files to measure\n\n\(usage)") }

        var samples: [String: [String: [Double]]] = [:]
        for file in files {
            FileHandle.standardError.write(Data("bench: \(file.lastPathComponent)\n".utf8))
            for (metric, values) in try await measure(file, runs: runs) {
                samples[metric, default: [:]][file.lastPathComponent] = values
            }
        }

        var metrics: [String: Any] = [:]
        for (metric, byFile) in samples {
            let medians = byFile.mapValues { median($0) }
            let spreads = byFile.values.map { values -> Double in
                let middle = median(values)
                return middle > 0 ? (percentile(values, 0.9) - percentile(values, 0.1)) / middle : 0
            }
            metrics[metric] = [
                "value": median(Array(medians.values)),
                "low": medians.values.min() ?? 0,
                "high": medians.values.max() ?? 0,
                "spread": median(spreads),
                "perFile": medians,
            ] as [String: Any]
        }
        let result: [String: Any] = [
            "tool": "redlamp bench",
            "runs": runs,
            "files": files.map(\.lastPathComponent),
            "metrics": metrics,
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    /// Every metric's samples for one file, in milliseconds.
    private static func measure(_ file: URL, runs: Int) async throws -> [String: [Double]] {
        let clock = ContinuousClock()
        var result: [String: [Double]] = [:]

        // A new engine for each open, so no cached session is reused.
        var engine = try RedlampEngine(decoder: InProcessDecoder())
        var info = try await engine.open(file)
        for _ in 0 ..< runs {
            engine = try RedlampEngine(decoder: InProcessDecoder())
            let started = clock.now
            info = try await engine.open(file)
            result["open", default: []].append(milliseconds(clock.now - started))
        }

        let view = fit(info.pixelSize, in: PixelSize(width: 2560, height: 1600))
        let frames = engine.frames()
        var iterator = frames.makeAsyncIterator()
        var generation: UInt64 = 0
        func interactive(_ recipe: EditRecipe, size: PixelSize) async -> [Double] {
            var durations: [Double] = []
            for run in 0 ..< warmUp + runs {
                generation += 1
                var edited = recipe
                // Each frame a slightly different edit, as while dragging a slider.
                edited[.exposure] = Double(run) * 0.01
                engine.render(RenderRequest(recipe: edited, targetSize: size, generation: generation))
                while let frame = await iterator.next() {
                    if frame.generation == generation {
                        if run >= warmUp {
                            durations.append(milliseconds(frame.renderDuration))
                        }
                        break
                    }
                }
            }
            return durations
        }

        var edit = EditRecipe()
        edit[.contrast] = 15
        edit[.shadows] = 30
        edit[.vibrance] = 20
        result["render-fit"] = await interactive(edit, size: view)

        var masked = edit
        var linear = MaskLayer(name: "Sky", components: [MaskComponent(shape: .linear(LinearMask(
            start: ImagePoint(x: 0.5, y: 0), end: ImagePoint(x: 0.5, y: 0.5),
        )))])
        linear[.localExposure] = -0.5
        var radial = MaskLayer(name: "Subject", components: [MaskComponent(shape: .radial(RadialMask(
            center: ImagePoint(x: 0.5, y: 0.6), radiusX: 0.3, radiusY: 0.3,
        )))])
        radial[.localExposure] = 0.3
        masked.masks = [linear, radial]
        result["render-fit-masks"] = await interactive(masked, size: view)

        result["render-full"] = await interactive(edit, size: info.pixelSize)

        func still(_ recipe: EditRecipe) async throws -> [Double] {
            var durations: [Double] = []
            for run in 0 ..< warmUp + runs {
                let started = clock.now
                _ = try await engine.renderStill(StillRequest(recipe: recipe, purpose: .export))
                if run >= warmUp {
                    durations.append(milliseconds(clock.now - started))
                }
            }
            return durations
        }
        result["export-full"] = try await still(edit)
        var denoised = edit
        denoised[.noiseLuminance] = 50
        result["export-full-nr"] = try await still(denoised)
        return result
    }

    private static func fit(_ size: PixelSize, in bounds: PixelSize) -> PixelSize {
        let scale = min(Double(bounds.width) / Double(size.width), Double(bounds.height) / Double(size.height), 1)
        return PixelSize(
            width: Int((Double(size.width) * scale).rounded()),
            height: Int((Double(size.height) * scale).rounded()),
        )
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    private static func median(_ values: [Double]) -> Double {
        percentile(values, 0.5)
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p + 0.5))]
    }
}
