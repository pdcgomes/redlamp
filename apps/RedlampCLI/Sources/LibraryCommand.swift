import Foundation
import RedlampLibrary
import Synchronization

/// `redlamp library`: synthetic libraries for the stress harness (LIB-03) and the benchmarks that
/// run on them (LIB-04), as docs/plans/2026-10-05-library-design.md describes.
enum LibraryCommand {
    static let usage = """
    usage: redlamp library fixture <folder> --photos <n> [--seed <s>] [--raw-sources <folder>]
           redlamp library bench <fixture> [--profile <profile>] [--scenario <name>…] [--json <path>]
      fixture  makes a synthetic library in <folder>: a fifth of the photos APFS clones of the raws in
               --raw-sources (tests/fixtures/raw) with their capture dates rewritten, the rest small JPEGs
               and HEICs with varied EXIF, GPS and IPTC; sidecars on 15% and other apps' .xmp on 5%; folders
               of every shape; and manifest.json, with what each query must return. Running it again
               finishes an interrupted fixture.
      bench    measures the fixture through a simulated volume (ssd, spinning, nas, wifi or vpn; ssd by
               default) and prints one line per measurement, ending PASS or FAIL where there's a budget;
               exits 1 when a budget fails. --json writes the report. Scenarios: \(scenarioNames).
    """

    private static var scenarioNames: String {
        BenchScenarios.all.map(\.name).joined(separator: ", ")
    }

    static func run(_ arguments: [String]) async throws {
        guard let command = arguments.first, !arguments.contains("--help") else {
            print(usage)
            return
        }
        switch command {
        case "fixture": try fixture(Array(arguments.dropFirst()))
        case "bench": try await bench(Array(arguments.dropFirst()))
        default: throw CLIError(description: "unknown library command \(command)\n\n\(usage)")
        }
    }

    private static func fixture(_ arguments: [String]) throws {
        let options = try Arguments(arguments, valued: ["--photos", "--seed", "--raw-sources"])
        guard options.positional.count == 1, let photos = try options.int("--photos"), photos > 0 else {
            throw CLIError(description: "fixture needs a folder and --photos\n\n\(usage)")
        }
        let seed = try options.value("--seed").map { text -> UInt64 in
            guard let seed = UInt64(text) else { throw CLIError(description: "--seed needs a whole number") }
            return seed
        } ?? 1
        let folder = URL(fileURLWithPath: options.positional[0], isDirectory: true)
        let rawFolder = options.value("--raw-sources").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? Repository.root.appending(path: "tests/fixtures/raw")
        var isDirectory: ObjCBool = false
        let sources = FileManager.default.fileExists(atPath: rawFolder.path, isDirectory: &isDirectory)
            && isDirectory.boolValue ? try RawSource.sources(in: rawFolder) : []
        if sources.isEmpty {
            FileHandle.standardError.write(Data("no raws in \(rawFolder.path): the fixture has none\n".utf8))
        }

        let fixture = LibraryFixture(spec: LibraryFixture.Spec(photos: photos, seed: seed), rawSources: sources)
        let reported = Mutex(0)
        let clock = ContinuousClock()
        let started = clock.now
        let summary = try fixture.write(to: folder) { done in
            let report = reported.withLock { reported in
                guard done >= reported + 10000 || done == photos else { return false }
                reported = done
                return true
            }
            if report {
                FileHandle.standardError.write(Data("  \(grouped(done)) of \(grouped(photos))\n".utf8))
            }
        }
        let elapsed = clock.now - started
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let totals = summary.manifest.totals
        let written = summary.skipped > 0
            ? "\(grouped(summary.written)) photos written, \(grouped(summary.skipped)) already there"
            : "\(grouped(summary.written)) photos written"
        print("""
        \(written) in \(String(format: "%.1f", seconds)) s (\(grouped(Int(Double(summary.written) / max(
            seconds,
            1e-9,
        )))) a second) to \(folder.path)
          \(grouped(totals.raws)) raws (clones of \(sources
            .count) sources), \(grouped(totals.jpegs)) JPEGs, \(grouped(totals.heics)) HEICs, in \(grouped(totals
                .folders)) folders
          \(grouped(totals.sidecars)) .redlamp sidecars (\(grouped(totals.edited)) edited), \(grouped(totals
                  .xmpSidecars)) other apps' .xmp
          \(grouped(totals.withLocation)) with a location, \(grouped(totals
                  .withKeywords)) with keywords, \(grouped(totals.withCaption)) with a caption
          \(summary.manifest.queries.count) queries counted in \(FixtureManifest.fileName)
        """)
    }

    private static func bench(_ arguments: [String]) async throws {
        let options = try Arguments(arguments, valued: ["--profile", "--scenario", "--json"])
        guard options.positional.count == 1 else { throw CLIError(description: "bench needs a fixture\n\n\(usage)") }
        let fixture = URL(fileURLWithPath: options.positional[0], isDirectory: true)
        let manifest: FixtureManifest
        do {
            manifest = try FixtureManifest.load(from: fixture)
        } catch {
            throw CLIError(
                description: "no fixture at \(fixture.path) (make one with redlamp library fixture): \(error)",
            )
        }
        let name = options.value("--profile") ?? VolumeProfile.ssd.name
        guard let profile = VolumeProfile.named(name) else {
            throw CLIError(
                description: "unknown profile \(name): \(VolumeProfile.presets.map(\.name).joined(separator: ", "))",
            )
        }
        let scenarios = try options.values("--scenario").map { name in
            guard let scenario = BenchScenarios.named(name) else {
                throw CLIError(description: "unknown scenario \(name): \(scenarioNames)")
            }
            return scenario
        }

        let context = BenchContext(fixture: fixture, manifest: manifest, profile: profile)
        let report = try await BenchReport.run(scenarios.isEmpty ? BenchScenarios.all : scenarios, in: context)
        print(report.text)
        if let json = options.value("--json") {
            try report.json().write(to: URL(fileURLWithPath: json), options: .atomic)
        }
        if report.exitStatus != 0 {
            throw ExitCode(report.exitStatus)
        }
    }

    private static func grouped(_ value: Int) -> String {
        let digits = Array(String(value.magnitude))
        return String(digits.enumerated().flatMap { index, digit in
            index > 0 && (digits.count - index) % 3 == 0 ? [",", digit] : [digit]
        })
    }
}
