import Foundation
import RedlampLibrary

extension LibraryCommand {
    /// `redlamp library stacks`: the stacks in an index (LIB-28), found from it alone: raw and JPEG
    /// pairs, bursts, focus-stack suggestions from capture settings, and the manual stacks its
    /// settings keep, each with its photos' paths, the top first; with a query, those holding a photo
    /// it finds.
    static func stacks(_ arguments: [String]) async throws {
        let options = try Arguments(arguments, valued: ["--index", "--kind"])
        guard let path = options.value("--index") else {
            throw CLIError(description: "stacks needs --index\n\n\(usage)")
        }
        var kinds = Set(Stack.Kind.allCases)
        if let name = options.value("--kind") {
            guard let kind = stackKinds[name] else {
                throw CLIError(description: "unknown kind \(name): pairs, bursts, focus or manual")
            }
            kinds = [kind]
        }
        let text = options.positional.joined(separator: " ")
        let query: LibraryQuery
        do {
            query = try LibraryQuery(parsing: text)
        } catch {
            let caret = String(repeating: " ", count: error.range.lowerBound)
                + String(repeating: "^", count: max(error.range.count, 1))
            throw CLIError(description: "\(text)\n\(caret)\n\(error.message)")
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError(description: "no index at \(url.path) (make one with redlamp library index)")
        }

        let index = try await LibraryIndex.open(at: url)
        let engine = QueryEngine(index: index)
        let clock = ContinuousClock()
        let loading = clock.now
        try await engine.load()
        let loaded = clock.now - loading
        let store = engine.store ?? ColumnStore()
        let started = clock.now
        let stacks = try await StackFinder.find(in: index, store: store)
        let elapsed = clock.now - started
        var shown = stacks.filter { kinds.contains($0.kind) }
        if !text.isEmpty {
            let list = try await engine.list(.query(query))
            shown = shown.filter { stacks.allPhotos(of: $0).contains { list.contains($0) } }
        }
        let photos = shown.map { stacks.allPhotos(of: $0) }
        let paths = try await index.read { reader in
            var paths: [Int64: String] = [:]
            for id in photos.joined() where paths[id] == nil {
                paths[id] = try reader.photoPath(id: id) ?? ""
            }
            return paths
        }
        await index.close()

        var counts: [Stack.Kind: Int] = [:]
        for stack in shown {
            counts[stack.kind, default: 0] += 1
        }
        if options.has("--json") {
            struct Output: Encodable {
                struct Found: Encodable {
                    let kind: String
                    let id: String?
                    /// Its frames, a raw and its JPEG counting once.
                    let frames: Int
                    /// The top photo's first, then every other.
                    let paths: [String]
                }

                let query: String
                let photos: Int
                let milliseconds: Double
                let loadMilliseconds: Double
                let counts: [String: Int]
                let stacks: [Found]
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let output = Output(
                query: query.description, photos: store.count, milliseconds: elapsed.milliseconds,
                loadMilliseconds: loaded.milliseconds,
                counts: Dictionary(uniqueKeysWithValues: Stack.Kind.allCases.filter(kinds.contains).map { kind in
                    (kind.rawValue, counts[kind] ?? 0)
                }),
                stacks: zip(shown, photos).map { stack, photos in
                    Output.Found(
                        kind: stack.kind.rawValue, id: stack.id?.uuidString, frames: stack.photos.count,
                        paths: photos.map { paths[$0] ?? "" },
                    )
                },
            )
            try print(String(decoding: encoder.encode(output), as: UTF8.self))
            return
        }
        for (stack, photos) in zip(shown, photos) {
            let label = switch stack.kind {
            case .pair: "pair"
            case .burst: "burst of \(stack.photos.count)"
            case .focus: "focus suggestion of \(stack.photos.count)"
            case .manual: "manual stack of \(stack.photos.count)"
            }
            print("\(label): \(paths[photos[0]] ?? "")")
            for photo in photos.dropFirst() {
                print("  \(paths[photo] ?? "")")
            }
        }
        let found = Stack.Kind.allCases.filter(kinds.contains).map { kind in
            let count = counts[kind] ?? 0
            let name = switch kind {
            case .pair: count == 1 ? "pair" : "pairs"
            case .burst: count == 1 ? "burst" : "bursts"
            case .focus: count == 1 ? "focus-stack suggestion" : "focus-stack suggestions"
            case .manual: count == 1 ? "manual stack" : "manual stacks"
            }
            return "\(grouped(count)) \(name)"
        }
        let joined = found.count > 1 ? found.dropLast().joined(separator: ", ") + " and " + found[found.count - 1]
            : found.joined()
        let among = text.isEmpty ? "among" : "holding photos \(query.description) finds, among"
        print(
            "\(joined) \(among) \(grouped(store.count)) photos, found in "
                + String(format: "%.1f ms (column store built in %.0f ms)", elapsed.milliseconds, loaded.milliseconds),
        )
    }

    private static let stackKinds: [String: Stack.Kind] = [
        "pairs": .pair, "pair": .pair, "bursts": .burst, "burst": .burst, "focus": .focus, "manual": .manual,
    ]

    /// `20,000`, whatever the locale.
    private static func grouped(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }
}

private extension Duration {
    var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}
