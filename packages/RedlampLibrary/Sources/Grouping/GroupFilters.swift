import Foundation

/// The filters finding a list's groups by folder, camera or lens (LIB-41). The language's `folder:`,
/// `camera:` and `lens:` find a substring of a folder's path or a camera's or a lens's name, ignoring
/// case, so a group's filter leaves out the other values among the list's that its term also finds: a
/// folder's subfolders in one term.
struct GroupFilters {
    let field: LibraryQuery.Field
    private let values: [String]
    /// For folders: every path's parts from each `/` on, folded, in order, with the path's place in
    /// `values`. A path that holds another holds it from one of its slashes.
    private let suffixes: [(key: ContiguousArray<UInt8>, place: Int)]

    /// The filters among photos whose `field` values are `values`, each once.
    init(field: LibraryQuery.Field, values: [String]) {
        self.field = field
        self.values = values
        var suffixes: [(key: ContiguousArray<UInt8>, place: Int)] = []
        if field == .folder {
            for (place, value) in values.enumerated() {
                let key = Self.folded(value)
                for (offset, byte) in key.enumerated() where byte == UInt8(ascii: "/") {
                    suffixes.append((ContiguousArray(key[offset...]), place))
                }
            }
            suffixes.sort { $0.key.lexicographicallyPrecedes($1.key) }
        }
        self.suffixes = suffixes
    }

    /// `field:value`, the other values it also finds left out; nil when the language can't tell
    /// `value` from one of them.
    func filter(for value: String) -> LibraryQuery? {
        func term(_ text: String) -> LibraryQuery {
            .filter(LibraryQuery.Filter(field, .equal, [.text(text)]))
        }
        let others = others(of: value)
        var excluded: [String] = []
        if field == .folder, !value.hasSuffix("/"), others.contains(where: { QueryText.contains($0, value + "/") }) {
            excluded.append(value + "/")
        }
        for other in others.sorted(by: { ($0.utf8.count, $0) < ($1.utf8.count, $1) })
            where !excluded.contains(where: { QueryText.contains(other, $0) }) {
            excluded.append(other)
        }
        guard !excluded.contains(where: { QueryText.contains(value, $0) }) else { return nil }
        return excluded.isEmpty ? term(value) : .and([term(value)] + excluded.map { .not(term($0)) })
    }

    /// The values but `value` that `field:value` finds.
    private func others(of value: String) -> [String] {
        let key = Self.folded(value)
        guard field == .folder, key.first == UInt8(ascii: "/") else {
            return values.filter { $0 != value && QueryText.contains($0, value) }
        }
        var (low, high) = (0, suffixes.count)
        while low < high {
            let middle = (low + high) / 2
            (low, high) = suffixes[middle].key.lexicographicallyPrecedes(key) ? (middle + 1, high) : (low, middle)
        }
        var places = Set<Int>()
        while low < suffixes.count, suffixes[low].key.starts(with: key) {
            places.insert(suffixes[low].place)
            low += 1
        }
        return places.sorted().map { values[$0] }.filter { $0 != value && QueryText.contains($0, value) }
    }

    /// `text` as paths are compared to find which hold which: ASCII lowercased as the language does,
    /// anything else composed with its case folded, so a path the language finds is always among them.
    private static func folded(_ text: String) -> ContiguousArray<UInt8> {
        QueryText.asciiLowercased(text)
            ?? ContiguousArray(text.precomposedStringWithCanonicalMapping.folding(
                options: .caseInsensitive,
                locale: nil,
            )
            .utf8)
    }
}
