import Foundation
import RedlampDocument

/// The photos shown, in order (`FolderLibrary.items`): every one's row, as a folder lists them or a small source's
/// list reads them; or, for a large source shown from the library, the photos' IDs and the rows read so far, the
/// others read as their cells appear (`FolderLibrary.row(at:)`), since reading a million rows takes most of a
/// second.
///
/// Code that can be shown a large source asks for a row with `row(_:)`, which has none until it's read; the
/// subscript stands in a placeholder for a row not read, which only code for folders' and small sources' photos
/// may meet.
public struct LibraryItems: RandomAccessCollection, MutableCollection, RangeReplaceableCollection,
    ExpressibleByArrayLiteral, Sendable {
    /// Every row, in order, unless the photos are a large source's.
    private var listed: [LibraryItem]
    /// A large source's photos' IDs, in order, and the rows read so far, by ID.
    private var sparse: (ids: ContiguousArray<Int64>, read: [Int64: LibraryItem])?

    public init() {
        listed = []
    }

    public init(_ items: [LibraryItem]) {
        listed = items
    }

    public init(arrayLiteral items: LibraryItem...) {
        listed = items
    }

    /// A large source's photos, `ids` in order, with the rows of those in `read`.
    init(ids: ContiguousArray<Int64>, read: [Int64: LibraryItem]) {
        listed = []
        sparse = (ids, read)
    }

    public var startIndex: Int {
        0
    }

    public var endIndex: Int {
        sparse?.ids.count ?? listed.count
    }

    /// Whether some rows are read only once they're asked for: the photos are a large source's.
    public var readsOnRequest: Bool {
        sparse != nil
    }

    /// Every row, for photos whose rows are all read: a folder's or a small source's. None for a large source's.
    public var allRows: [LibraryItem] {
        listed
    }

    /// Row `position`; nil while it isn't read, which only a large source's can be.
    public func row(_ position: Int) -> LibraryItem? {
        guard let sparse else { return listed[position] }
        return sparse.read[sparse.ids[position]]
    }

    /// Photo `id`'s row, while the photos are a large source's and it's been read.
    func readRow(_ id: Int64) -> LibraryItem? {
        sparse?.read[id]
    }

    /// The rows read of a large source's photos, by ID; every row is read for others.
    var rowsRead: [Int64: LibraryItem] {
        sparse?.read ?? [:]
    }

    public subscript(position: Int) -> LibraryItem {
        get {
            guard let sparse else { return listed[position] }
            if let item = sparse.read[sparse.ids[position]] {
                return item
            }
            assertionFailure("Row \(position) of a large source was asked for before it was read")
            return .unread
        }
        set {
            guard let id = sparse?.ids[position] else {
                listed[position] = newValue
                return
            }
            if sparse?.read[id] != nil {
                sparse?.read[id] = newValue
            }
        }
    }

    public mutating func replaceSubrange(_ range: Range<Int>, with items: some Collection<LibraryItem>) {
        guard sparse == nil else {
            return assertionFailure("A large source's photos change only as its list hands them over")
        }
        listed.replaceSubrange(range, with: items)
    }

    public mutating func reserveCapacity(_ count: Int) {
        listed.reserveCapacity(count)
    }

    /// Keeps `rows`, read for photos of a large source; those it no longer has are left out.
    mutating func read(_ rows: some Sequence<(id: Int64, item: LibraryItem)>) {
        guard sparse != nil else { return }
        for (id, item) in rows {
            sparse?.read[id] = item
        }
    }

    /// Forgets the rows read of the photos `ids`, so they're read again when they're next asked for.
    mutating func forget(_ ids: some Sequence<Int64>) {
        guard sparse != nil else { return }
        for id in ids {
            sparse?.read[id] = nil
        }
    }

    /// Changes the badges of each row of `rows` that's been read, as `change` does, in one pass; `change` hears each
    /// row's place in `rows`. With `comparing`, returns the rows whose badges it changed.
    mutating func changeMetadata(
        _ rows: [Int], comparing: Bool, _ change: (Int, inout PhotoMetadata) -> Void,
    ) -> [Int] {
        var changed: [Int] = []
        guard sparse != nil else {
            listed.withUnsafeMutableBufferPointer { items in
                for (place, row) in rows.enumerated() where items.indices.contains(row) {
                    guard comparing else {
                        change(place, &items[row].metadata)
                        continue
                    }
                    let before = items[row].metadata
                    change(place, &items[row].metadata)
                    if items[row].metadata != before {
                        changed.append(row)
                    }
                }
            }
            return changed
        }
        let ids = sparse?.ids ?? []
        for (place, row) in rows.enumerated() where ids.indices.contains(row) {
            guard var item = sparse?.read[ids[row]] else { continue }
            let before = item.metadata
            change(place, &item.metadata)
            if item.metadata != before {
                sparse?.read[ids[row]] = item
                changed.append(row)
            }
        }
        return changed
    }

    /// The URLs of the rows read at `places`, in order: every one's but a large source's not read yet.
    func urls(at places: some Sequence<Int>) -> [URL] {
        var urls: [URL] = []
        urls.reserveCapacity(places.underestimatedCount)
        guard let sparse else {
            listed.withUnsafeBufferPointer { items in
                for place in places where items.indices.contains(place) {
                    urls.append(items[place].url)
                }
            }
            return urls
        }
        for place in places where sparse.ids.indices.contains(place) {
            if let item = sparse.read[sparse.ids[place]] {
                urls.append(item.url)
            }
        }
        return urls
    }
}

extension LibraryItems: Equatable {
    public static func == (lhs: LibraryItems, rhs: LibraryItems) -> Bool {
        lhs.listed == rhs.listed && lhs.sparse?.ids == rhs.sparse?.ids && lhs.sparse?.read == rhs.sparse?.read
    }
}

extension LibraryItem {
    /// What a large source's row not yet read reads as: no photo.
    static let unread = LibraryItem(url: URL(fileURLWithPath: "/.redlamp-unread", isDirectory: false))
}

/// What `FolderLibrary` keeps for reading a large source's rows as they're asked for.
struct SourceRows {
    /// The photos whose rows have been asked for and aren't in yet.
    var asked = Set<Int64>()
    /// Those asked for this turn, read together once it ends.
    var waiting: [Int64] = []
    /// The rows each view shows, by its name: the rows near them are the last let go of.
    var onScreen: [String: Range<Int>] = [:]
    /// The active photo, whose row is never let go of.
    var active: Int64?
}

/// A large source's rows read as they're asked for (LIB-10, `LibraryItems`): the grid's and the filmstrip's cells ask
/// for theirs as they appear, a turn's together, and show them once they're read, which the views hear of as rows
/// `read`. Everything that acts on photos out of sight works from their IDs, or has their rows read first
/// (`whenRead`). The rows near those on screen are kept, `keptRows` at most beyond what an action asked for.
extension FolderLibrary {
    /// The rows of a large source kept once they've been read, at most, unless an action asked for more.
    static let keptRows = 10000

    /// Row `position`; while it's a large source's row not yet read, nil, and it's asked for.
    public func row(at position: Int) -> LibraryItem? {
        guard items.indices.contains(position) else { return nil }
        if let item = items.row(position) {
            return item
        }
        askForRows(ofPhotos: [photoIDs[position]])
        return nil
    }

    /// Asks for the rows of the photos at `places` that aren't read yet, for a large source.
    public func askForRows(at places: some Sequence<Int>) {
        guard items.readsOnRequest else { return }
        let ids = photoIDs
        askForRows(ofPhotos: places.lazy.filter { ids.indices.contains($0) }.map { ids[$0] })
    }

    /// The rows `name`'s view shows: those near them are the last let go of.
    public func showRows(_ rows: Range<Int>, in name: String) {
        guard items.readsOnRequest || !fromLibrary.rows.onScreen.isEmpty else { return }
        fromLibrary.rows.onScreen[name] = rows
    }

    /// Calls `body` once the rows of the photos `ids` are read: at once, unless they're a large source's and one
    /// isn't, when it's read first. `body` isn't called when another source is shown meanwhile; what it does with
    /// rows it finds again by their photos' IDs, since photos may have come or gone.
    func whenRead(_ ids: some Collection<Int64>, _ body: @escaping @MainActor () -> Void) {
        guard !hasRead(ids) else { return body() }
        let generation = generation
        Task { [weak self] in
            await self?.read(ids)
            guard let self, self.generation == generation else { return }
            body()
        }
    }

    /// Reads the rows of a large source's photos `ids` not read yet, returning once they're in, or once another source
    /// is shown.
    func read(_ ids: some Collection<Int64>) async {
        guard items.readsOnRequest, let list = fromLibrary.sourceList else { return }
        let shown = photoList
        let missing = ids.filter { shown.contains($0) && items.readRow($0) == nil }
        guard !missing.isEmpty else { return }
        list.hold(missing)
        let generation = generation
        let rows = try? await list.rows(of: missing)
        guard self.generation == generation, fromLibrary.sourceList === list else { return }
        took(rows, asked: missing, keeping: true)
    }

    /// Whether the rows of the photos `ids` are read: always, unless the photos are a large source's.
    func hasRead(_ ids: some Sequence<Int64>) -> Bool {
        guard items.readsOnRequest else { return true }
        let shown = photoList
        return ids.allSatisfy { !shown.contains($0) || items.readRow($0) != nil }
    }

    /// Asks for the rows of the photos `ids` that aren't read yet, for a large source.
    func askForRows(ofPhotos ids: some Sequence<Int64>) {
        guard items.readsOnRequest, let list = fromLibrary.sourceList else { return }
        var new: [Int64] = []
        for id in ids where items.readRow(id) == nil && fromLibrary.rows.asked.insert(id).inserted {
            new.append(id)
        }
        guard !new.isEmpty else { return }
        list.hold(new)
        let first = fromLibrary.rows.waiting.isEmpty
        fromLibrary.rows.waiting += new
        guard first else { return }
        let generation = generation
        // After this turn, so what's asked for while laying out is read together.
        Task { [weak self] in
            guard let self, self.generation == generation, fromLibrary.sourceList === list else { return }
            let asked = fromLibrary.rows.waiting
            fromLibrary.rows.waiting = []
            let rows = try? await list.rows(of: asked)
            guard self.generation == generation, fromLibrary.sourceList === list else { return }
            took(rows, asked: asked)
        }
    }

    /// Takes the rows read for the photos `asked`: those a change hasn't brought meanwhile, of photos still shown.
    /// Rows are let go of first, unless an action asked for these (`keeping`).
    private func took(_ rows: LibrarySourceList.Rows?, asked: [Int64], keeping: Bool = false) {
        fromLibrary.rows.asked.subtract(asked)
        guard items.readsOnRequest else { return }
        let shown = photoList
        var fresh: [(id: Int64, item: LibraryItem)] = []
        var gone: [Int64] = []
        for id in asked {
            if let item = rows?.items[id], shown.contains(id) {
                if items.readRow(id) == nil {
                    fresh.append((id, item))
                }
            } else if items.readRow(id) == nil {
                gone.append(id)
            }
        }
        fromLibrary.sourceList?.release(gone)
        guard !fresh.isEmpty, let rows else { return }
        if !keeping {
            letGo(making: fresh.count)
        }
        items.read(fresh)
        var paths = fromLibrary.sourcePaths ?? PhotoPaths()
        for (id, item) in fresh {
            fromLibrary.sourceKeys[id] = rows.keys[id]
            paths.insert(id, folder: item.folderPath, name: item.name)
        }
        fromLibrary.sourcePaths = paths
        publish(LibraryDiff(read: IndexSet(rows: fresh.compactMap { shown.index(of: $0.id) })))
    }

    /// Lets go of rows of a large source so that `coming` more stay within `keptRows`: those furthest from the rows
    /// on screen first, never the active photo's.
    func letGo(making coming: Int = 0) {
        let read = items.rowsRead
        guard read.count + coming > Self.keptRows else { return }
        let shown = photoList
        let screens = Array(fromLibrary.rows.onScreen.values)
        func distance(_ id: Int64) -> Int {
            guard let place = shown.index(of: id) else { return .max }
            var nearest = Int.max
            for screen in screens {
                let away = screen.contains(place) ? 0 : place < screen.lowerBound
                    ? screen.lowerBound - place : place - screen.upperBound + 1
                nearest = min(nearest, away)
            }
            return nearest
        }
        let active = activePhoto
        let ranked = read.keys.filter { $0 != active }.map { ($0, distance($0)) }.sorted { $0.1 > $1.1 }
        let leaving = ranked.prefix(max(read.count + coming - Self.keptRows * 3 / 4, 0)).map(\.0)
        guard !leaving.isEmpty else { return }
        var paths = fromLibrary.sourcePaths ?? PhotoPaths()
        for id in leaving {
            if let item = read[id] {
                paths.remove(at: item.url)
            }
            fromLibrary.sourceKeys[id] = nil
        }
        fromLibrary.sourcePaths = paths
        items.forget(leaving)
        fromLibrary.sourceList?.release(leaving)
    }

    /// The list a large source's rows are read from, for reading them off the main thread; nil for photos whose rows
    /// are all read.
    var rowSource: LibrarySourceList? {
        items.readsOnRequest ? fromLibrary.sourceList : nil
    }

    /// The active photo's ID, while it's one of a large source's, whose row is always kept.
    var activePhoto: Int64? {
        get { fromLibrary.rows.active }
        set { fromLibrary.rows.active = newValue }
    }
}
