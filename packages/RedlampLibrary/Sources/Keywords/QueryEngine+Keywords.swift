import Foundation

public extension QueryEngine {
    /// How many of photos `ids` have each keyword, from each photo's keywords as the engine keeps them in
    /// memory for the filter bar's columns (read from the index the first time, then only the photos changed
    /// since): the keywording panel's and the keyword list's view of a selection, a search per photo rather
    /// than a pass over the library. A keyword counts the photos that have it, not those with a keyword
    /// inside it.
    func keywordCounts(ofPhotos ids: some Sequence<Int64>) async throws -> [KeywordPath: Int] {
        let pairs = try await postings(.keywords).pairs
        let wanted = Array(Set(ids)).sorted()
        var byID: [Int64: Int] = [:]
        pairs.withUnsafeBufferPointer { pairs in
            var low = 0
            for (offset, id) in wanted.enumerated() {
                if offset & 0xFFF == 0, Task.isCancelled {
                    return
                }
                var high = pairs.count
                while low < high {
                    let middle = (low + high) / 2
                    if pairs[middle].photo < id {
                        low = middle + 1
                    } else {
                        high = middle
                    }
                }
                while low < pairs.count, pairs[low].photo == id {
                    byID[pairs[low].keyword, default: 0] += 1
                    low += 1
                }
            }
        }
        try Task.checkCancellation()
        var names = snapshot()?.1.names.keywords ?? [:]
        if byID.keys.contains(where: { names[$0] == nil }) {
            names = try await source.names().keywords
        }
        var counts: [KeywordPath: Int] = [:]
        for (id, count) in byID {
            if let path = names[id].flatMap(KeywordPath.init) {
                counts[path, default: 0] += count
            }
        }
        return counts
    }
}
