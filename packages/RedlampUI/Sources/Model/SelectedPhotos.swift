import Foundation

/// The photos an action on the whole of a selection works through, in the filmstrip's order, as they were when it
/// began (LIB-10): their URLs at once, or for a large source's, the URLs of those whose rows aren't read found in the
/// index off the main thread as the action reaches them, a batch at a time, and no row kept for them. An action on a
/// million photos, which waited 3 s for every row, starts at once.
struct SelectedPhotos: Sendable {
    /// How many there are.
    let count: Int
    /// Every URL, when all are known.
    let urls: [URL]?
    private let ids: ContiguousArray<Int64>
    private let read: [Int64: URL]
    private let source: LargeListRows?

    init(_ urls: [URL]) {
        count = urls.count
        self.urls = urls
        ids = []
        read = [:]
        source = nil
    }

    /// A large source's photos `ids`, the URLs of those whose rows are read in `read`, the others read from `source`.
    init(ids: ContiguousArray<Int64>, read: [Int64: URL], source: LargeListRows) {
        count = ids.count
        urls = nil
        self.ids = ids
        self.read = read
        self.source = source
    }

    /// The URLs of the photos at `range` of them, in order; photos the index no longer has are left out.
    func urls(_ range: Range<Int>) async -> [URL] {
        if let urls {
            return Array(urls[range])
        }
        let wanted = ids[range]
        let missing = Array(wanted.lazy.filter { read[$0] == nil })
        let found = missing.isEmpty ? [:] : await (try? source?.urls(of: missing)) ?? [:]
        return wanted.compactMap { read[$0] ?? found[$0] }
    }

    /// Every one's URL, in order.
    func all() async -> [URL] {
        await urls(0 ..< count)
    }

    /// Their URLs `size` at a time, in order, each batch read while the one before is worked through.
    func batches(of size: Int) -> Batches {
        Batches(photos: self, size: max(size, 1))
    }

    struct Batches {
        fileprivate let photos: SelectedPhotos
        fileprivate let size: Int
        private var start = 0
        private var coming: Task<[URL], Never>?

        fileprivate init(photos: SelectedPhotos, size: Int) {
            self.photos = photos
            self.size = size
        }

        /// The next batch; nil after the last.
        mutating func next() async -> [URL]? {
            guard start < photos.count else { return nil }
            let batch = await (coming ?? reading(from: start)).value
            start = min(start + size, photos.count)
            coming = start < photos.count ? reading(from: start) : nil
            return batch
        }

        private func reading(from first: Int) -> Task<[URL], Never> {
            let (photos, range) = (photos, first ..< min(first + size, photos.count))
            return Task { await photos.urls(range) }
        }
    }
}
