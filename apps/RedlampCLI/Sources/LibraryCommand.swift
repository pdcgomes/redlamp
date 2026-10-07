import Foundation
import RedlampLibrary
import Synchronization

/// `redlamp library`: synthetic libraries for the stress harness (LIB-03) and the benchmarks that
/// run on them (LIB-04), as docs/plans/2026-10-05-library-design.md describes.
enum LibraryCommand {
    static let usage = """
    usage: redlamp library fixture <folder> --photos <n> [--seed <s>] [--raw-sources <folder>] [--duplicates <share>]
           redlamp library bench <fixture> [--profile <profile>] [--scenario <name>…] [--photos <n>] [--index <folder>]
                                 [--json <path>]
           redlamp library index <folder>… --index <path> [--profile <profile>]
           redlamp library search <query> --index <path> [--collection <name or path>]
                                  [--sort captured|name|rating|edited|modified|size] [--descending]
                                  [--json] [--limit <n>]
           redlamp library stats --index <path> [--json]
           redlamp library sidecars <root> --index <path> [--move beside|mac] [--dry-run] [--json]
           redlamp library names <template> --index <path> [<query>] [--json] [--limit <n>]
                                 [--text [<name>=]<text>]
           redlamp library duplicates --index <path> [--confirm] [--json]
           redlamp library duplicates --index <path> --trash [--confirm] [--dry-run] [--json]
           redlamp library health --index <path> [--rule both|raw|jpeg] [--hash] [--limit <n>] [--json]
           redlamp library health --index <path> --trash duplicates|pairs|damaged | --rename [--rule raw|jpeg]
                                  [--choose <photo>]… [--confirm] [--dry-run] [--json]
           redlamp library health --index <path> --keep|--unkeep <check> [--rule raw|jpeg] <photo>…
           redlamp library health --index <path> --kept [--json]
           redlamp library xmp --index <path> [<query>] [--write] [--dry-run] [--json]
           redlamp library rename <template> --index <path> [<query>] [--text [<name>=]<text>]… [--limit <n>]
                                  [--dry-run] [--json]
           redlamp library move <query> --to <folder> --index <path> [--dry-run] [--json]
           redlamp library move --folder <folder> --to <path> --index <path> [--dry-run] [--json]
           redlamp library trash <query> --index <path> [--dry-run] [--json]
           redlamp library undo --index <path> [--json]
           redlamp library journal --index <path> [--finish | --roll-back] [--json]
           redlamp library trashed --index <path> [--json]
           redlamp library put-back <photo>… --index <path> [--dry-run] [--json]
           redlamp library put-back --batch <id> --index <path> [--dry-run] [--json]
           redlamp library keywords --index <path> [--tree] [--json]
           redlamp library keywords import|export <file> --index <path>
           redlamp library keywords add|remove <keyword> --index <path> <query> [--dry-run] [--json]
           redlamp library keywords rename <keyword> <path> --index <path> [--dry-run]
           redlamp library keywords merge <keyword>… --into <keyword> --index <path> [--dry-run]
           redlamp library keywords delete <keyword>… --index <path> [--dry-run]
           redlamp library keywords undo --index <path>
           redlamp library stacks --index <path> [<query>] [--kind pairs|bursts|focus|manual] [--json]
           redlamp library stacks stack|unstack|top <query> --index <path> [--top <name>] [--dry-run] [--json]
           redlamp library groups --index <path> [<query>] [--collection <name or path>]
                                  [--by none|moment|day|folder|camera|lens|orientation|moment-camera]
                                  [--tighter <n> | --looser <n>] [--sort captured|name|rating|edited|modified|size]
                                  [--descending] [--json]
           redlamp library metadata --index <path> [<query>] [--limit <n>] [--json]
           redlamp library metadata set --index <path> <query> [--rating <n>] [--flag <flag>] [--label <name>]
                                    [--mark | --unmark] [--<field> <text>]… [--codes <file>] [--dry-run] [--json]
           redlamp library metadata shift --index <path> <query> --by <amount> | --to <date time> [--photo <name>]
                                    [--dry-run] [--json]
           redlamp library metadata zone --index <path> <query> --offset <±hh:mm> | --file [--dry-run] [--json]
           redlamp library metadata preset <name> --index <path> <query> [--codes <file>] [--dry-run] [--json]
           redlamp library metadata presets [save <name> [--<field> <text>]… [--append|--prefix <field>]…
                                    | remove <name>] --index <path> [--json]
           redlamp library metadata undo --index <path> [--dry-run] [--json]
           redlamp library collections --index <path> [--tree] [--json]
           redlamp library collections new <path> [--set] | smart <path> <query> --index <path> [--dry-run]
           redlamp library collections add|remove <collection> --index <path> <query> [--dry-run] [--json]
           redlamp library collections rename <collection> <path> | delete <collection>… --index <path>
                                       [--dry-run] [--json]
           redlamp library collections target <collection>|none --index <path>
           redlamp library import <source> --to <folder> [--backup <folder>] [--folders <template>]
                                  [--names <template>] [--raw-only] [--keywords <k>,…] [--index <path>]
                                  [--dry-run] [--json]
      fixture  makes a synthetic library in <folder>: a fifth of the photos APFS clones of the raws in
               --raw-sources (tests/fixtures/raw) with their capture dates rewritten, the rest small JPEGs
               and HEICs with varied EXIF, GPS and IPTC; sidecars on 15% and other apps' .xmp on 5%; folders
               of every shape; and manifest.json, with what each query must return. Running it again
               finishes an interrupted fixture. --duplicates makes that share of the photos byte-for-byte copies
               of earlier ones, with sidecars of their own (none by default).
      bench    measures the fixture through a simulated volume (ssd, spinning, nas, wifi or vpn; ssd by
               default) and prints one line per measurement, ending PASS or FAIL where there's a budget;
               exits 1 when a budget fails. --json writes the report. --photos sets how many thumbnails the
               store scenario writes to the Mac's own disk (100,000 by default). --index keeps warm-launch's
               index of the fixture in <folder>, built there the first time, and launches a copy of it after
               that; search and facets search the index there, or without --index the one kept under
               $TMPDIR/redlamp-bench-query, and never index the fixture themselves: with no index of it they
               say so. Scenarios: \(scenarioNames).
      index    adds the folders to the library index at <path> (made if there's none) and indexes them: every
               folder listed, and each photo that's new or changed since it was indexed read once. Prints its
               progress and a summary; exits 1 when a photo couldn't be read or a volume stopped answering.
               --profile reads through a simulated volume, as bench does.
      search   runs <query>, in the library's query language (rating>=3 label:red,blue -flag:reject
               camera:"X-T5" date:2024-06..2024-08 sunset), over the index at <path> and prints the photos'
               paths in order (when they were taken, unless --sort says otherwise), then how many photos it
               found and how long it took. --collection searches a collection, a set or a smart collection
               instead of the whole library, and <query> may then be left out. --limit prints only the first
               <n>; --json prints JSON.
      stats    prints what the index at <path> holds: its photos and folders, its roots and where each keeps
               its sidecars, its volumes and which are offline, how many photos are edited, rated, picked,
               rejected and labelled, and the sizes of the index and of the store beside it. --json prints JSON.
      sidecars prints where <root> keeps its .redlamp sidecars and how many are beside the photos, on this Mac
               and in both places. --move takes them beside the photos or to this Mac: each copied, checked and
               only then removed where it was, never over another, and other apps' .xmp left beside the
               photos; a sidecar in both places stops the move before it starts. --dry-run says what would
               move. A move a forced quit interrupted is finished first. Exits 1 when something wasn't moved.
      names    prints each photo <query> finds: its path, the name <template> gives it, any number added to
               tell it apart, and tokens that came out empty. --text gives {text} and {text:shoot}. A dry
               run: nothing is renamed.
      duplicates groups the photos in the index at <path> whose content keys and sizes agree, and prints each
               group's copies, the copy proposed to keep and why, and what removing all but the proposed copies
               would free. --confirm reads every candidate whole and compares full SHA-256 hashes, which the
               index keeps, so an unchanged file is never read again; without it only hashes recorded earlier
               count. Lists the candidates that turned out different and those offline or not read; --json
               prints JSON. --trash prints every file that moves, then moves all but each group's proposed
               copy to the Trash as one batch undo reverses, only with --confirm, after checking every copy
               again; --dry-run moves nothing. Without --trash it removes nothing.
      health   lists Library Health's checks of the index at <path>, each with the photos needing a
               decision, why, what it proposes and how long it took: exact duplicates, from the hashes the
               index recorded (--hash first reads whole the candidates not compared yet); raw and JPEG pairs
               under --rule (raw keeps the raws, jpeg the JPEGs, and both, the default, proposes nothing);
               damaged files, unreadable, empty or ending early; and wrong extensions, files holding another
               family's format. A check with nothing to decide isn't listed; --json prints JSON. --trash moves
               a check's proposed photos to the Trash, and --rename gives wrong extensions those their formats
               take, sidecars and .xmp following, each as one batch undo reverses, only with --confirm; a
               photo rated, flagged or labelled, or a pair's half with decisions of its own, is listed apart
               and acted on only when --choose names it. --keep keeps a check's findings for the photos named
               anyway, in the library's Definitions/Health.json, --unkeep takes them back and --kept lists
               what's kept.
      xmp      compares each photo <query> finds (every photo without one) with what other apps wrote in its
               .xmp, embedded XMP and IPTC, and merges their changes into its .redlamp sidecar. --write also
               writes standard .xmp beside the photos, keeping other apps' fields, as the library does once
               writing them is turned on; --dry-run says what would change and writes nothing. Exits 1 when
               a sidecar couldn't be written.
      rename   renames the photos <query> finds with <template>, as names shows them, each raw with its JPEG,
               its .redlamp sidecar and other apps' .xmp, recording each photo's original name. move takes
               photos, or a folder with --folder, to another folder; across volumes each file is copied and
               checked before the original goes. trash moves photos to the Trash. Each is a batch in a
               journal written before anything moves: nothing is ever overwritten, a collision stops it
               before it starts, and --dry-run shows the plan. undo takes the last batch back; journal lists
               the batches, and finishes (--finish) or rolls back (--roll-back) one a forced quit cut short,
               which every command does first.
      trashed  lists what the batches moved to the Trash that's still there, newest first, from the
               journal: each photo where it was and where it is in the Trash, its batch, and the sidecars,
               other apps' .xmp and pair that went with it; --json prints JSON. put-back puts photos back
               where they were, named by either path, or every photo of a batch with --batch, each with its
               pair, sidecars and .xmp, as a batch undo reverses; a name taken where a photo was stops it
               before anything moves, and --dry-run shows the plan.
      keywords prints the keyword list with how many photos have each, indented by level with --tree;
               imports and exports Lightroom Classic's keyword-list file; adds or removes a keyword on the
               photos <query> finds; renames, moves, merges and deletes keywords, rewriting their photos'
               sidecars as one journaled batch; and undoes the last batch.
      stacks   finds the stacks in the index at <path> from it alone: raw and JPEG pairs, bursts (a camera's
               frames in one folder with one exposure length, each within a second of the last one's end),
               focus-stack suggestions from capture settings, which the app confirms from thumbnails, and the
               manual stacks the index keeps. Prints each with its photos' paths, the top photo first, then how
               many of each it found and how long that took. <query> keeps the stacks holding a photo it
               finds; --kind keeps one kind; --json prints JSON. stack, unstack and top make a manual stack
               of the photos <query> finds (--top names the one shown), take them out of theirs, or show
               the first for its stack, each photo's .redlamp keeping its place.
      groups   groups the photos <query> finds (every photo without one), or a collection's with --collection,
               in their order (--sort, as search has it): by moment, the default (photos taken together, a new
               moment starting at a pause longer than 60 s and four times the pace of the photos around it, the
               two moved together by up to 4 steps of --tighter or --looser), day, folder, camera, lens,
               orientation, moment-camera (each moment's photos by camera, for two bodies whose clocks disagree)
               or none, a stack always whole. Prints each group with how many photos and picks it has and the
               filter that finds it, the moments without a pick, and a summary: the days, cameras, lenses, ISO,
               shutter and aperture ranges, pairs and stacks. --json prints JSON.
      metadata prints each photo <query> finds with its rating, flag, label, mark, IPTC Core's fields,
               collections and stack as the index shows them; set gives them ratings, flags, labels (a
               colour's name in any label set, or a custom label), marks and IPTC Core's fields (--title,
               --caption, --creator, --copyright, --sublocation, --city, --state, --country,
               --country-code; an empty text clears one), \\code\\ expanded from a tab-separated --codes
               file; preset applies a preset's fields, each replacing, appending or prefixing; presets lists,
               saves and removes them; shift moves capture times by an amount, or sets one photo's and moves
               the rest as much, and zone gives the camera's clock its zone, the photos' files never touched.
               Each change rewrites the photos' .redlamp sidecars as one journaled batch, which undo takes
               back, with collections' and stacks' changes.
      collections prints the collection list, makes collections, sets and smart collections, renames,
               moves and deletes them with their photos' sidecars rewritten, puts the photos <query> finds
               in a collection or takes them out, and sets the target collection; --dry-run shows a plan.
      import   copies the photos of a card or folder to <folder> in folders and names from the templates,
               and to --backup as real copies, each read back and checked by size and SHA-256 before the
               card counts as safe to erase; photos the library at --index already has are skipped;
               --raw-only copies raw files alone, leaving a raw's JPEG and photos that aren't raws on the
               source; --keywords adds keywords. A journal lets an import
               a forced quit cut short finish on the next run; --dry-run shows the plan.
    """

    private static var scenarioNames: String {
        BenchScenarios.all.map(\.name).joined(separator: ", ")
    }

    static func run(_ arguments: [String]) async throws {
        BenchScenarios.registerIndexing()
        BenchScenarios.registerQueries()
        BenchScenarios.registerStore()
        BenchScenarios.registerLists()
        BenchScenarios.registerNaming()
        BenchScenarios.registerDuplicates()
        BenchScenarios.registerXMP()
        BenchScenarios.registerFiles()
        BenchScenarios.registerKeywords()
        BenchScenarios.registerMetadata()
        BenchScenarios.registerCollections()
        BenchScenarios.registerStacks()
        BenchScenarios.registerGroups()
        BenchScenarios.registerImport(rawFolder: Repository.root.appending(path: "tests/fixtures/raw"))
        guard let command = arguments.first, !arguments.contains("--help") else {
            print(usage)
            return
        }
        switch command {
        case "fixture": try fixture(Array(arguments.dropFirst()))
        case "bench": try await bench(Array(arguments.dropFirst()))
        case "index": try await index(Array(arguments.dropFirst()))
        case "search": try await search(Array(arguments.dropFirst()))
        case "stats": try await stats(Array(arguments.dropFirst()))
        case "sidecars": try await sidecars(Array(arguments.dropFirst()))
        case "names": try await names(Array(arguments.dropFirst()))
        case "duplicates": try await duplicates(Array(arguments.dropFirst()))
        case "health": try await health(Array(arguments.dropFirst()))
        case "xmp": try await xmp(Array(arguments.dropFirst()))
        case "rename": try await rename(Array(arguments.dropFirst()))
        case "move": try await move(Array(arguments.dropFirst()))
        case "trash": try await trash(Array(arguments.dropFirst()))
        case "undo": try await undo(Array(arguments.dropFirst()))
        case "journal": try await journal(Array(arguments.dropFirst()))
        case "trashed": try await trashed(Array(arguments.dropFirst()))
        case "put-back": try await putBack(Array(arguments.dropFirst()))
        case "keywords": try await keywords(Array(arguments.dropFirst()))
        case "stacks" where stackVerbs.contains(arguments.dropFirst().first ?? ""):
            try await stackChange(Array(arguments.dropFirst()))
        case "stacks": try await stacks(Array(arguments.dropFirst()))
        case "groups": try await groups(Array(arguments.dropFirst()))
        case "metadata": try await metadata(Array(arguments.dropFirst()))
        case "collections": try await collections(Array(arguments.dropFirst()))
        case "import": try await importing(Array(arguments.dropFirst()))
        default: throw CLIError(description: "unknown library command \(command)\n\n\(usage)")
        }
    }

    private static func fixture(_ arguments: [String]) throws {
        let options = try Arguments(arguments, valued: ["--photos", "--seed", "--raw-sources", "--duplicates"])
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

        let duplicates = try options.double("--duplicates") ?? 0
        let fixture = LibraryFixture(
            spec: LibraryFixture.Spec(photos: photos, seed: seed, duplicateShare: duplicates), rawSources: sources,
        )
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
        let options = try Arguments(arguments, valued: ["--profile", "--scenario", "--photos", "--index", "--json"])
        guard options.positional.count == 1 else { throw CLIError(description: "bench needs a fixture\n\n\(usage)") }
        if let photos = try options.int("--photos") {
            guard photos > 0 else { throw CLIError(description: "--photos needs a number above 0") }
            BenchScenarios.registerStore(photos: photos)
        }
        if let index = options.value("--index") {
            let folder = URL(fileURLWithPath: index, isDirectory: true)
            BenchScenarios.register(IndexLaunchScenario(indexFolder: folder))
            BenchScenarios.register(SearchScenario(indexFolder: folder))
            BenchScenarios.register(FacetScenario(indexFolder: folder))
        }
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
