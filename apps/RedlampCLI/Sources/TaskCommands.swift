import Foundation
import RedlampBench

/// `redlamp task`: bench tasks, so an agent can ask the owner for a step in Lightroom or another
/// app. See docs/bench-tasks.md and .cursor/skills/redlamp-bench/SKILL.md.
enum TaskCommands {
    static let usage = """
    usage: redlamp task <command>
      new --title "…" --app "Lightroom mobile" [--step "Title | detail"]… [options] <assets…>
          A task in the outbox, for the iPhone app to pull. Without --no-auto-steps it starts with a
          step sharing the assets to the app and ends with one waiting for the results.
          --kind K (default lightroom-check)  --workstream W  --tracker ID  --issue N  --note "…"
          --question "id | text | choice, choice"   --manual (the owner marks it done)
      new --draft draft.json
          A task from a draft: task.json's fields, with each asset as {"source": path, "id", "label",
          "counts"} and "pictures": [paths] copied into pictures/ for steps to name.
      check <folder or ID>     What's wrong with a task, as the hub sees it (exit 1 on errors)
      list                     The outbox and Done
      show <ID> [--json]       A task's results and how each paired, from Done or the outbox
      wait <ID> [--timeout S]  Returns once the task is back in Done and complete (exit 2 on timeout)
      withdraw <ID>            Takes a task back; the phone drops it unless it has results
      serve [--port N]         The Lab's hub without the Lab, until interrupted: prints the pairing
                               code and what arrives (look references aren't fitted here)
    The folders are in \(BenchStore.standardRoot.path).
    """

    static let valued: Set<String> = [
        "--title", "--app", "--kind", "--step", "--workstream", "--tracker", "--issue", "--note", "--question",
        "--draft", "--timeout", "--id", "--port",
    ]

    static func run(_ arguments: [String]) async throws {
        guard let command = arguments.first, command != "--help" else {
            print(usage)
            return
        }
        let arguments = try Arguments(arguments.dropFirst(), valued: valued)
        let store = BenchStore()
        switch command {
        case "new": try new(arguments, store: store)
        case "check": try check(arguments, store: store)
        case "list": list(store)
        case "show": try show(arguments, store: store)
        case "wait": try await wait(arguments, store: store)
        case "serve": try await serve(arguments, store: store)
        case "withdraw":
            guard let id = arguments.positional.first else { throw CLIError(description: "withdraw needs a task ID") }
            try store.withdraw(id)
            print("withdrew \(id)")
        default:
            throw CLIError(description: "unknown task command \(command)\n\(usage)")
        }
    }

    // MARK: - new

    /// A draft: task.json's fields an agent writes, with assets as paths.
    struct Draft: Decodable {
        struct Asset: Decodable {
            var source: String
            var id: String?
            var label: String?
            var chart: Int?
            var counts: Bool?
        }

        var id: String?
        var title: String
        var kind: String?
        var app: String?
        var requestedBy: BenchManifest.Requester?
        var steps: [BenchManifest.Step]?
        var assets: [Asset]
        var pictures: [String]?
        var questions: [BenchManifest.Question]?
        var completion: BenchManifest.Completion?
        var pairing: [BenchManifest.Pairing]?
        var note: String?
    }

    static func new(_ arguments: Arguments, store: BenchStore) throws {
        let (manifest, assets, pictures) = if let path = arguments.value("--draft") {
            try fromDraft(URL(fileURLWithPath: path))
        } else {
            try fromFlags(arguments)
        }
        let folder = try store.create(manifest, assets: assets, pictures: pictures)
        for issue in folder.validate() {
            print(issue)
        }
        print("""
        made \(folder.id): \(folder.manifest.steps.count) steps, \(folder.manifest.assets.count) asset\(folder.manifest
            .assets.count == 1 ? "" : "s")
        in \(folder.url.path)
        It reaches the iPhone app the next time the phone can reach the Lab (the harness's Recipe Lab, Bench tab).
        """)
    }

    static func fromDraft(_ url: URL) throws -> (BenchManifest, [BenchFolder.NewAsset], [URL]) {
        let draft = try JSONDecoder.bench.decode(Draft.self, from: Data(contentsOf: url))
        let base = url.deletingLastPathComponent()
        func resolve(_ path: String) -> URL {
            path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appending(path: path)
        }
        let manifest = BenchManifest(
            id: draft.id ?? BenchManifest.newID(title: draft.title), title: draft.title,
            kind: draft.kind ?? BenchManifest.Kind.lightroomCheck, requestedBy: draft.requestedBy, app: draft.app,
            steps: draft.steps ?? [], completion: draft.completion ?? .everyAsset,
            pairing: draft.pairing ?? [.fileName, .similarity], questions: draft.questions ?? [], note: draft.note,
        )
        let assets = draft.assets.map {
            BenchFolder.NewAsset(
                file: resolve($0.source),
                id: $0.id,
                label: $0.label,
                chart: $0.chart,
                counts: $0.counts ?? true,
            )
        }
        return (manifest, assets, (draft.pictures ?? []).map(resolve))
    }

    static func fromFlags(_ arguments: Arguments) throws -> (BenchManifest, [BenchFolder.NewAsset], [URL]) {
        guard let title = arguments.value("--title")
        else { throw CLIError(description: "new needs --title, or --draft") }
        let files = arguments.positional.map { URL(fileURLWithPath: $0) }
        guard !files.isEmpty else { throw CLIError(description: "new needs the asset files") }
        let app = arguments.value("--app")
        var steps = try arguments.values("--step").enumerated().map { index, text in
            let parts = text.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let title = parts.first, !title.isEmpty else { throw CLIError(description: "--step needs a title") }
            return BenchManifest.Step(id: "step-\(index + 1)", title: title, detail: parts.count > 1 ? parts[1] : nil)
        }
        if !arguments.has("--no-auto-steps") {
            let what = files.count == 1 ? "the photo" : "the \(files.count) photos"
            steps.insert(.init(
                id: "share", title: "Share \(what) to \(app ?? "the app")",
                detail: "Select them in the grid and share them, or save them to Photos if the app only reads the library.",
                action: .share(assets: nil),
            ), at: 0)
            steps.append(.init(
                id: "results", title: "Share the results back",
                detail: "Share the exports to Redlamp Bench. They pair with their photos by name or by look.",
                action: .results(assets: nil),
            ))
        }
        let questions = try arguments.values("--question").map { text in
            let parts = text.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 3 else { throw CLIError(description: "--question is \"id | text | choice, choice\"") }
            return BenchManifest.Question(
                id: parts[0], text: parts[1],
                choices: parts[2].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
            )
        }
        let requester = try BenchManifest.Requester(
            workstream: arguments.value("--workstream"), tracker: arguments.value("--tracker"),
            issue: arguments.int("--issue"),
        )
        let manifest = BenchManifest(
            id: arguments.value("--id") ?? BenchManifest.newID(title: title), title: title,
            kind: arguments.value("--kind") ?? BenchManifest.Kind.lightroomCheck,
            requestedBy: requester.workstream == nil && requester.tracker == nil && requester
                .issue == nil ? nil : requester,
            app: app, steps: steps, completion: arguments.has("--manual") ? .manual : .everyAsset,
            questions: questions, note: arguments.value("--note"),
        )
        return (manifest, files.map { BenchFolder.NewAsset(file: $0) }, [])
    }

    // MARK: - Reading

    static func folder(_ argument: String?, store: BenchStore) throws -> BenchFolder {
        guard let argument else { throw CLIError(description: "name a task ID or folder") }
        if argument.contains("/"), let folder = try? BenchFolder.load(URL(fileURLWithPath: argument)) {
            return folder
        }
        for area in [BenchStore.Area.done, .outbox, .templates] {
            if let folder = store.folder(argument, in: area) {
                return folder
            }
        }
        throw CLIError(description: "no task \(argument) in Done, the outbox or the templates")
    }

    static func check(_ arguments: Arguments, store: BenchStore) throws {
        let folder = try folder(arguments.positional.first, store: store)
        let issues = folder.validate()
        for issue in issues {
            print(issue)
        }
        let errors = issues.filter { $0.severity == .error }.count
        print(errors == 0 ? "\(folder.id): OK" : "\(folder.id): \(errors) error(s)")
        if errors > 0 {
            throw ExitCode(1)
        }
    }

    static func list(_ store: BenchStore) {
        for area in [BenchStore.Area.outbox, .done, .templates] {
            let folders = store.folders(area)
            print("\(area.rawValue) (\(folders.count))")
            for folder in folders {
                let state = area == .done ? folder.summary
                    + (folder.isComplete ? "" : ", not complete")
                    : folder.manifest.withdrawn ? "withdrawn" : "\(folder.manifest.assets.count) asset\(folder.manifest.assets.count == 1 ? "" : "s")"
                print("  \(folder.id)  \(folder.manifest.look?.title ?? folder.manifest.title)  [\(state)]")
            }
        }
    }

    static func show(_ arguments: Arguments, store: BenchStore) throws {
        let folder = try folder(arguments.positional.first, store: store)
        if arguments.has("--json") {
            struct Shown: Encodable {
                var path: String
                var manifest: BenchManifest
                var results: BenchResults
                var complete: Bool
                var missing: [String]
            }
            let shown = Shown(
                path: folder.url.path, manifest: folder.manifest, results: folder.results,
                complete: folder.isComplete, missing: folder.missing,
            )
            try print(String(decoding: JSONEncoder.bench.encode(shown), as: UTF8.self))
            return
        }
        let m = folder.manifest
        print("\(m.look?.title ?? m.title)  (\(m.kind), \(folder.url.path))")
        if let look = m.look {
            print("  settings: \(look.settings ?? "defaults"); kit: \(look.kitSet.rawValue)")
        }
        print(folder.isComplete ? "  complete" : "  waiting for: \(folder.missing.joined(separator: ", "))")
        for asset in m.assets {
            if let result = folder.results.current(for: asset.id) {
                let how = result.pairedBy
                    .map { $0 == .similarity ? "similarity \(String(format: "%.2f", result.score ?? 0))" : $0.rawValue
                    } ?? "?"
                print("  \(asset.id) ← \(result.file) (\(result.originalName), by \(how))")
            } else {
                print("  \(asset.id) ← nothing yet")
            }
        }
        for result in folder.results.unpaired {
            print("  unpaired: \(result.file) (\(result.originalName))")
        }
        for (question, answer) in folder.results.answers.sorted(by: { $0.key < $1.key }) {
            print("  \(question): \(answer)")
        }
        if let note = folder.results.note {
            print("  note: \(note)")
        }
    }

    static func serve(_ arguments: Arguments, store: BenchStore) async throws {
        // Each event as it happens, even when the output is a pipe or a log.
        setvbuf(stdout, nil, _IOLBF, 0)
        let port = try arguments.int("--port").map(UInt16.init) ?? BenchProtocol.defaultPort
        let hub = BenchHub(
            store: store,
            name: "Redlamp hub on \(Host.current().localizedName ?? "this Mac")",
        ) { event in
            switch event {
            case let .state(.ready(port)): print("listening on port \(port)")
            case let .state(.failed(reason)): print("couldn't listen: \(reason)")
            case let .arrival(arrival): print("arrived: \(arrival.summary) (\(arrival.folder.url.path))")
            case let .refused(reason): print("refused: \(reason)")
            case let .paired(device): print("paired \(device)")
            default: break
            }
        }
        try await hub.start(port: port)
        await print("pairing code \(hub.code); the outbox and templates are in \(store.root.path)")
        while true {
            try await Task.sleep(for: .seconds(3600))
        }
    }

    static func wait(_ arguments: Arguments, store: BenchStore) async throws {
        guard let id = arguments.positional.first else { throw CLIError(description: "wait needs a task ID") }
        let timeout = try arguments.int("--timeout") ?? 3600
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        while Date() < deadline {
            if let folder = store.folder(id, in: .done), folder.isComplete {
                print("\(id) is back: \(folder.summary)")
                print(folder.url.path)
                return
            }
            try await Task.sleep(for: .seconds(5))
        }
        print("\(id) isn't back after \(timeout) s")
        throw ExitCode(2)
    }
}
