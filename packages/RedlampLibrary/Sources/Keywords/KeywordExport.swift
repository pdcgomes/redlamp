import Foundation

/// The keywords an exported photo carries (LIB-21), as each keyword's options say.
public struct ExportedKeywords: Sendable, Hashable {
    /// Flat names, for `dc:subject` and IPTC's keywords: each exported keyword, its synonyms and the
    /// keywords containing it where its options say so, each once.
    public var names: [String]
    /// Paths, for `lr:hierarchicalSubject`: each exported keyword's, without the keywords containing
    /// it that aren't exported themselves.
    public var paths: [KeywordPath]
}

public extension KeywordList {
    /// What an export writes for a photo with `keywords`: nothing of a private keyword or anything
    /// inside it, nor of a person when `people` is false; a category's name never, though the
    /// keywords inside it go. Keywords the list doesn't have go with the default options.
    func exported(_ keywords: [KeywordPath], people: Bool = true) -> ExportedKeywords {
        var names: [String] = []
        var paths: [KeywordPath] = []
        var seen = Set<String>()
        func add(_ name: String) {
            if seen.insert(name).inserted {
                names.append(name)
            }
        }
        func options(_ path: KeywordPath) -> KeywordOptions {
            self[path]?.options ?? KeywordOptions()
        }
        for keyword in keywords {
            let chain = keyword.ancestors + [keyword]
            guard !chain.contains(where: { options($0).isPrivate }) else { continue }
            let own = options(keyword)
            guard people || !own.isPerson, own.isExported else { continue }
            add(keyword.name)
            if own.exportSynonyms {
                own.synonyms.forEach(add)
            }
            let exported = chain.filter { options($0).isExported && (people || !options($0).isPerson) }
            if own.exportContainingKeywords {
                for container in exported.dropLast() {
                    add(container.name)
                    if options(container).exportSynonyms {
                        options(container).synonyms.forEach(add)
                    }
                }
            }
            if let path = KeywordPath(names: exported.map(\.name)), !paths.contains(path) {
                paths.append(path)
            }
        }
        return ExportedKeywords(names: names, paths: paths)
    }
}

public extension LibraryKeywords {
    /// Reads a Lightroom Classic keyword-list file and keeps its keywords in the list, with its
    /// synonyms and its say on whether each is exported: one batch with Undo.
    @discardableResult
    func importLightroomFile(_ data: Data) async throws -> KeywordOutcome {
        let keywords = try LightroomKeywordFile.read(data)
        return try await apply(.importList(keywords))
    }

    /// The keyword list as a Lightroom Classic keyword-list file holds it.
    func exportLightroomFile() async throws -> LightroomKeywordFile.Export {
        try await LightroomKeywordFile.write(list().ordered.map(LightroomKeywordFile.Keyword.init))
    }
}
