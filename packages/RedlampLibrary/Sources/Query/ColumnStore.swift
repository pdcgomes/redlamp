import Foundation
import RedlampDocument

/// The library's hot columns in memory (LIB-06): an array for each field the query language filters
/// and sorts on, indexed by a dense row number, and the sort orders as permutations of the rows.
/// It's built from the index's hot-column scan, in the background at launch, and changed as the
/// writer commits (`apply`).
///
/// A value: copies share their arrays until one of them changes, so a query reads a snapshot while
/// changes go to another. Rows are never renumbered by a change: a removed photo's row is dead
/// until enough rows are, when the store is compacted.
///
/// Numbers are kept as the language compares them (`ColumnEncoding`), and the SQL a query falls
/// back to computes the same encodings, so both answer alike.
public struct ColumnStore: Sendable {
    /// What the store keeps of a photo: its hot columns and the few more the language filters and
    /// sorts on.
    public struct Row: Sendable, Hashable {
        public var hot: HotColumns
        /// Seconds.
        public var shutter: Double?
        public var details: Details
        /// When its sidecar was last saved, in seconds since 1970: the edited sort's key, for a
        /// photo with an edit.
        public var sidecarModified: Double?
        /// The file's size in bytes, and when it was last modified, in seconds since 1970.
        public var size: Int64
        public var modified: Double?
        /// Whether it's missing or offline.
        public var state: PhotoRecord.State
        /// IPTC Core's creator, copyright notice and location.
        public var creator: String?
        public var copyright: String?
        public var location: PhotoLocation?
        /// A label's name outside the five colours.
        public var customLabel: String?
        /// Pixels.
        public var width: Int?
        public var height: Int?

        public init(
            _ hot: HotColumns, shutter: Double? = nil, details: Details = [], sidecarModified: Double? = nil,
            size: Int64 = 0, modified: Double? = nil, state: PhotoRecord.State = [], creator: String? = nil,
            copyright: String? = nil, location: PhotoLocation? = nil, customLabel: String? = nil, width: Int? = nil,
            height: Int? = nil,
        ) {
            self.hot = hot
            self.shutter = shutter
            self.details = details
            self.sidecarModified = sidecarModified
            self.size = size
            self.modified = modified
            self.state = state
            self.creator = creator
            self.copyright = copyright
            self.location = location
            self.customLabel = customLabel
            self.width = width
            self.height = height
        }
    }

    /// What `has` asks about.
    public struct Details: OptionSet, Sendable, Hashable {
        public let rawValue: UInt16

        public init(rawValue: UInt16) {
            self.rawValue = rawValue
        }

        public static let location = Details(rawValue: 1 << 0)
        public static let keywords = Details(rawValue: 1 << 1)
        public static let title = Details(rawValue: 1 << 2)
        public static let caption = Details(rawValue: 1 << 3)
        /// Another app's `.xmp` beside it.
        public static let xmp = Details(rawValue: 1 << 4)
    }

    /// The photo in each row; 0 in a dead row.
    public private(set) var ids: ContiguousArray<Int64> = []
    private(set) var folders: ContiguousArray<Int32> = []
    /// Milliseconds (`ColumnEncoding.captured`).
    private(set) var captured: ContiguousArray<Int64> = []
    /// Codes into `cameraIDs` and `lensIDs`; 0 for none.
    private(set) var cameras: ContiguousArray<UInt16> = []
    private(set) var lenses: ContiguousArray<UInt16> = []
    /// Rating, flag, label, marked, edited and details (`Packed`).
    private(set) var packed: ContiguousArray<UInt16> = []
    private(set) var iso: ContiguousArray<UInt16> = []
    private(set) var aperture: ContiguousArray<UInt16> = []
    private(set) var focal: ContiguousArray<UInt16> = []
    private(set) var shutter: ContiguousArray<UInt32> = []
    private(set) var kinds: ContiguousArray<UInt8> = []
    /// Each row's place in the name order.
    private(set) var nameRanks: ContiguousArray<Int32> = []
    private(set) var editedAt: ContiguousArray<Int32> = []
    /// `ColumnEncoding.fileSize`, `ColumnEncoding.modifiedAt` and `PhotoRecord.State`'s bits.
    private(set) var sizes: ContiguousArray<UInt32> = []
    private(set) var modifiedAt: ContiguousArray<Int32> = []
    private(set) var states: ContiguousArray<UInt8> = []
    /// Codes into `creatorNames`, `copyrightNames` and `customLabelNames`, and into `placeNames` for
    /// IPTC Core's location; 0 for none.
    private(set) var creators: ContiguousArray<UInt16> = []
    private(set) var copyrights: ContiguousArray<UInt16> = []
    private(set) var customLabels: ContiguousArray<UInt8> = []
    private(set) var places: ContiguousArray<UInt32> = []
    /// `ColumnEncoding.megapixels` and `ColumnEncoding.aspect`.
    private(set) var megapixels: ContiguousArray<UInt16> = []
    private(set) var aspects: ContiguousArray<UInt16> = []
    /// `ColumnEncoding.orientation`.
    private(set) var orientations: ContiguousArray<UInt8> = []
    /// The rows holding a photo.
    private(set) var live = RowBits(rows: 0)

    /// The camera and lens IDs by code, code 0 being none.
    private(set) var cameraIDs: ContiguousArray<Int64> = [0]
    private(set) var lensIDs: ContiguousArray<Int64> = [0]
    private var cameraCodes: [Int64: UInt16] = [:]
    private var lensCodes: [Int64: UInt16] = [:]
    /// The names the code columns stand for.
    private(set) var creatorNames = NameCodes(limit: UInt32(UInt16.max))
    private(set) var copyrightNames = NameCodes(limit: UInt32(UInt16.max))
    private(set) var customLabelNames = NameCodes(limit: UInt32(UInt8.max))
    private(set) var placeNames = PlaceCodes()

    /// The row of each photo ID, -1 for none: 4 bytes for every ID up to the largest.
    private var rowOfID: ContiguousArray<Int32> = []

    /// The live rows in each sort's order, ascending.
    private(set) var byCaptured: ContiguousArray<Int32> = []
    private(set) var byName: ContiguousArray<Int32> = []
    private(set) var byRating: ContiguousArray<Int32> = []
    private(set) var byEdited: ContiguousArray<Int32> = []
    /// Kept once a search sorts by them (`prepareOrder`): until then they're sorted when asked for.
    private(set) var byModified: ContiguousArray<Int32>?
    private(set) var bySize: ContiguousArray<Int32>?

    /// The orders sorted as the store is built; the others wait until they're used.
    static let builtOrders: [QuerySort.Key] = [.captured, .name, .rating, .edited]

    /// Photos in the store.
    public private(set) var count = 0

    public init() {}

    /// The store of `rows`, in any order; a photo given twice keeps its last row. The index's row IDs
    /// are never negative, and a row with one is left out.
    public init(rows: some Sequence<Row>) {
        var builder = Builder(capacity: rows.underestimatedCount)
        for row in rows {
            builder.add(row)
        }
        self = builder.finish()
    }

    /// A store built a row at a time, its orders sorted once at the end.
    struct Builder {
        private var store = ColumnStore()
        private var names = ContiguousArray<String>()

        /// Room for `capacity` photos with IDs up to it, so the columns take no more than they need.
        init(capacity: Int = 0) {
            store.reserveCapacity(capacity)
            names.reserveCapacity(capacity)
        }

        mutating func add(_ row: Row) {
            guard row.hot.id >= 0 else { return }
            if let existing = store.row(of: row.hot.id) {
                store.set(row, at: existing)
                names[existing] = row.hot.name
            } else {
                store.append(row)
                names.append(row.hot.name)
            }
        }

        mutating func finish() -> ColumnStore {
            store.sortOrders(keys: NameKeys(names))
            names = []
            return store
        }
    }

    /// The rows of a range of photo IDs, for `joining` with the parts beside it: added in increasing
    /// ID order, each photo once, with their names' keys and codes of their own for cameras and
    /// lenses. Parts of one store are built side by side.
    struct Part: Sendable {
        fileprivate var store = ColumnStore()
        fileprivate var keys = NameKeys()

        init(capacity: Int = 0) {
            store.reserveColumns(capacity)
            keys.reserveCapacity(capacity)
        }

        var count: Int {
            store.ids.count
        }

        mutating func add(_ row: Row) {
            guard row.hot.id >= 0 else { return }
            store.appendColumns(row)
            keys.append(name: row.hot.name)
        }
    }

    /// The store of `parts`, given in increasing order of their photo IDs: their columns one after
    /// another, and every order sorted, the four side by side.
    static func joining(_ parts: [Part]) async -> ColumnStore {
        var store = ColumnStore()
        let total = parts.reduce(0) { $0 + $1.count }
        store.reserveColumns(total)
        var keys = NameKeys()
        keys.reserveCapacity(total)
        var largest: Int64 = -1
        for part in parts {
            let columns = part.store
            let cameras = columns.cameraIDs.indices.map { code in
                code == 0 ? 0 : store.code(for: columns.cameraIDs[code], in: &store.cameraIDs, &store.cameraCodes)
            }
            let lenses = columns.lensIDs.indices.map { code in
                code == 0 ? 0 : store.code(for: columns.lensIDs[code], in: &store.lensIDs, &store.lensCodes)
            }
            let creators = columns.creatorNames.names.map { UInt16(store.creatorNames.code(for: $0)) }
            let copyrights = columns.copyrightNames.names.map { UInt16(store.copyrightNames.code(for: $0)) }
            let customLabels = columns.customLabelNames.names.map { UInt8(store.customLabelNames.code(for: $0)) }
            let places = (0 ..< columns.placeNames.count).map { place in
                store.placeNames.code(for: columns.placeNames.location(of: place))
            }
            store.ids.append(contentsOf: columns.ids)
            store.folders.append(contentsOf: columns.folders)
            store.captured.append(contentsOf: columns.captured)
            store.cameras.append(contentsOf: columns.cameras.lazy.map { cameras[Int($0)] })
            store.lenses.append(contentsOf: columns.lenses.lazy.map { lenses[Int($0)] })
            store.packed.append(contentsOf: columns.packed)
            store.iso.append(contentsOf: columns.iso)
            store.aperture.append(contentsOf: columns.aperture)
            store.focal.append(contentsOf: columns.focal)
            store.shutter.append(contentsOf: columns.shutter)
            store.kinds.append(contentsOf: columns.kinds)
            store.editedAt.append(contentsOf: columns.editedAt)
            store.sizes.append(contentsOf: columns.sizes)
            store.modifiedAt.append(contentsOf: columns.modifiedAt)
            store.states.append(contentsOf: columns.states)
            store.creators.append(contentsOf: columns.creators.lazy.map { creators[Int($0)] })
            store.copyrights.append(contentsOf: columns.copyrights.lazy.map { copyrights[Int($0)] })
            store.customLabels.append(contentsOf: columns.customLabels.lazy.map { customLabels[Int($0)] })
            store.places.append(contentsOf: columns.places.lazy.map { places[Int($0)] })
            store.megapixels.append(contentsOf: columns.megapixels)
            store.aspects.append(contentsOf: columns.aspects)
            store.orientations.append(contentsOf: columns.orientations)
            keys.append(contentsOf: part.keys)
            largest = max(largest, columns.ids.max() ?? -1)
        }
        store.count = total
        store.nameRanks = ContiguousArray(repeating: 0, count: total)
        store.live = RowBits(rows: total, filled: true)
        store.rowOfID = ContiguousArray(repeating: -1, count: Int(largest) + 1)
        store.rowOfID.withUnsafeMutableBufferPointer { rowOfID in
            for (row, id) in store.ids.enumerated() {
                rowOfID[Int(id)] = Int32(row)
            }
        }
        return await store.sortingOrders(keys: keys)
    }

    /// Sorts every order from scratch, the rows' names' keys being `keys`.
    private mutating func sortOrders(keys: NameKeys) {
        for key in Self.builtOrders {
            setOrder(rows(sortedBy: key, keys: keys), for: key)
        }
        renumberNames()
    }

    /// `sortOrders`, each order sorted beside the others.
    private func sortingOrders(keys: NameKeys) async -> ColumnStore {
        let store = self
        return await withTaskGroup(of: (QuerySort.Key, ContiguousArray<Int32>).self) { group in
            for key in Self.builtOrders {
                group.addTask { (key, store.rows(sortedBy: key, keys: keys)) }
            }
            var sorted = store
            for await (key, order) in group {
                sorted.setOrder(order, for: key)
            }
            sorted.renumberNames()
            return sorted
        }
    }

    /// Every row in `key`'s ascending order, before the name order's ranks are known.
    private func rows(sortedBy key: QuerySort.Key, keys: NameKeys) -> ContiguousArray<Int32> {
        var order = ContiguousArray(Int32(0) ..< Int32(ids.count))
        if key == .name {
            ids.withUnsafeBufferPointer { ids in
                order.sort { keys.compare(Int($0), Int($1)) ?? (ids[Int($0)] < ids[Int($1)]) }
            }
        } else {
            sort(&order, by: key)
        }
        return order
    }

    // MARK: - Reading

    /// Rows, live and dead: one more than the largest row number.
    var rowCount: Int {
        ids.count
    }

    public func row(of id: Int64) -> Int? {
        guard id >= 0, id < rowOfID.count else { return nil }
        let row = rowOfID[Int(id)]
        return row < 0 ? nil : Int(row)
    }

    public func contains(_ id: Int64) -> Bool {
        row(of: id) != nil
    }

    /// Which way photo `id` is turned, from its size once its EXIF orientation is applied; nil for a
    /// photo the store doesn't hold or whose size the index doesn't have.
    public func orientation(of id: Int64) -> PhotoOrientation? {
        row(of: id).flatMap { PhotoOrientation(code: orientations[$0]) }
    }

    /// The live rows in `key`'s ascending order: sorted now for an order the store doesn't keep yet.
    func order(_ key: QuerySort.Key) -> ContiguousArray<Int32> {
        switch key {
        case .captured: byCaptured
        case .name: byName
        case .rating: byRating
        case .edited: byEdited
        case .modified: byModified ?? liveRows(sortedBy: key)
        case .size: bySize ?? liveRows(sortedBy: key)
        }
    }

    /// Whether `key`'s order is kept, rather than sorted each time it's asked for.
    public func keepsOrder(_ key: QuerySort.Key) -> Bool {
        switch key {
        case .captured, .name, .rating, .edited: true
        case .modified: byModified != nil
        case .size: bySize != nil
        }
    }

    /// Sorts `key`'s order and keeps it, so changes keep it in order from now on.
    public mutating func prepareOrder(_ key: QuerySort.Key) {
        guard !keepsOrder(key) else { return }
        setOrder(liveRows(sortedBy: key), for: key)
    }

    /// The live rows in `key`'s order, sorted from the captured order. Not for the name order,
    /// whose ranks come from it.
    private func liveRows(sortedBy key: QuerySort.Key) -> ContiguousArray<Int32> {
        var order = byCaptured
        sort(&order, by: key)
        return order
    }

    /// Every photo's ID in `sort`'s order.
    public func ids(sortedBy sort: QuerySort) -> ContiguousArray<Int64> {
        let order = order(sort.key)
        var result = ContiguousArray<Int64>()
        result.reserveCapacity(order.count)
        if sort.ascending {
            result.append(contentsOf: order.lazy.map { ids[Int($0)] })
        } else {
            result.append(contentsOf: order.reversed().lazy.map { ids[Int($0)] })
        }
        return result
    }

    func cameraCode(for id: Int64) -> UInt16? {
        cameraCodes[id]
    }

    func lensCode(for id: Int64) -> UInt16? {
        lensCodes[id]
    }

    /// Bytes its arrays hold, as allocated.
    public var memoryFootprint: Int {
        func bytes<T>(_ array: ContiguousArray<T>) -> Int {
            array.capacity * MemoryLayout<T>.stride
        }
        let columns = bytes(ids) + bytes(folders) + bytes(captured) + bytes(cameras) + bytes(lenses) + bytes(packed)
            + bytes(iso) + bytes(aperture) + bytes(focal) + bytes(shutter) + bytes(kinds) + bytes(nameRanks)
            + bytes(editedAt) + bytes(sizes) + bytes(modifiedAt) + bytes(states) + bytes(live.words)
            + bytes(creators) + bytes(copyrights) + bytes(customLabels) + bytes(places) + bytes(megapixels)
            + bytes(aspects) + bytes(orientations)
        let orders = bytes(byCaptured) + bytes(byName) + bytes(byRating) + bytes(byEdited)
            + (byModified.map(bytes) ?? 0) + (bySize.map(bytes) ?? 0)
        let codes = bytes(cameraIDs) + bytes(lensIDs) + (cameraCodes.capacity + lensCodes.capacity) * 16
            + creatorNames.memoryFootprint + copyrightNames.memoryFootprint + customLabelNames.memoryFootprint
            + placeNames.memoryFootprint
        return columns + orders + bytes(rowOfID) + codes
    }

    // MARK: - Rows

    private mutating func reserveCapacity(_ count: Int) {
        reserveColumns(count)
        nameRanks.reserveCapacity(count)
        rowOfID.reserveCapacity(count + 1)
    }

    private mutating func reserveColumns(_ count: Int) {
        ids.reserveCapacity(count)
        folders.reserveCapacity(count)
        captured.reserveCapacity(count)
        cameras.reserveCapacity(count)
        lenses.reserveCapacity(count)
        packed.reserveCapacity(count)
        iso.reserveCapacity(count)
        aperture.reserveCapacity(count)
        focal.reserveCapacity(count)
        shutter.reserveCapacity(count)
        kinds.reserveCapacity(count)
        editedAt.reserveCapacity(count)
        sizes.reserveCapacity(count)
        modifiedAt.reserveCapacity(count)
        states.reserveCapacity(count)
        creators.reserveCapacity(count)
        copyrights.reserveCapacity(count)
        customLabels.reserveCapacity(count)
        places.reserveCapacity(count)
        megapixels.reserveCapacity(count)
        aspects.reserveCapacity(count)
        orientations.reserveCapacity(count)
    }

    /// Adds a row for a photo the store doesn't hold.
    mutating func append(_ row: Row) {
        let index = ids.count
        appendColumns(row)
        nameRanks.append(0)
        live.grow(to: index + 1)
        live.insert(index)
        let id = Int(row.hot.id)
        if id >= rowOfID.count {
            rowOfID.append(contentsOf: repeatElement(-1, count: id + 1 - rowOfID.count))
        }
        rowOfID[id] = Int32(index)
        count += 1
    }

    /// Adds `row`'s columns after the others, without its rank in the name order or its place among
    /// the photos the store holds.
    private mutating func appendColumns(_ row: Row) {
        ids.append(row.hot.id)
        folders.append(0)
        captured.append(0)
        cameras.append(0)
        lenses.append(0)
        packed.append(0)
        iso.append(0)
        aperture.append(0)
        focal.append(0)
        shutter.append(0)
        kinds.append(0)
        editedAt.append(0)
        sizes.append(0)
        modifiedAt.append(0)
        states.append(0)
        creators.append(0)
        copyrights.append(0)
        customLabels.append(0)
        places.append(0)
        megapixels.append(0)
        aspects.append(0)
        orientations.append(0)
        set(row, at: ids.count - 1)
    }

    /// Writes `row`'s columns at `index`, which keeps its place in every order.
    mutating func set(_ row: Row, at index: Int) {
        let hot = row.hot
        folders[index] = Int32(clamping: hot.folder)
        captured[index] = ColumnEncoding.captured(hot.captured)
        cameras[index] = hot.camera.map { code(for: $0, in: &cameraIDs, &cameraCodes) } ?? 0
        lenses[index] = hot.lens.map { code(for: $0, in: &lensIDs, &lensCodes) } ?? 0
        packed[index] = Packed.pack(row)
        iso[index] = ColumnEncoding.iso(hot.iso)
        aperture[index] = ColumnEncoding.aperture(hot.aperture)
        focal[index] = ColumnEncoding.focal(hot.focal)
        shutter[index] = ColumnEncoding.shutter(row.shutter)
        kinds[index] = UInt8(clamping: hot.kind)
        editedAt[index] = ColumnEncoding.editedAt(edited: hot.edited, sidecarModified: row.sidecarModified)
        sizes[index] = ColumnEncoding.fileSize(row.size)
        modifiedAt[index] = ColumnEncoding.modifiedAt(row.modified)
        states[index] = UInt8(clamping: row.state.rawValue & 0xFF)
        creators[index] = UInt16(creatorNames.code(for: row.creator))
        copyrights[index] = UInt16(copyrightNames.code(for: row.copyright))
        customLabels[index] = UInt8(customLabelNames.code(for: row.customLabel))
        places[index] = placeNames.code(for: row.location)
        megapixels[index] = ColumnEncoding.megapixels(width: row.width, height: row.height)
        aspects[index] = ColumnEncoding.aspect(width: row.width, height: row.height)
        orientations[index] = ColumnEncoding.orientation(width: row.width, height: row.height)
    }

    /// Takes a row out: its photo is gone from the store, and from every order once `removeFromOrders`
    /// runs.
    mutating func kill(_ index: Int) {
        let id = Int(ids[index])
        if id < rowOfID.count {
            rowOfID[id] = -1
        }
        ids[index] = 0
        live.remove(index)
        count -= 1
    }

    /// The code of camera or lens `id`, given one the first time it's seen. Past 65,535 of them,
    /// the rest share the last code.
    private func code(
        for id: Int64, in ids: inout ContiguousArray<Int64>, _ codes: inout [Int64: UInt16],
    ) -> UInt16 {
        if let code = codes[id] {
            return code
        }
        guard ids.count <= Int(UInt16.max) else { return UInt16.max }
        let code = UInt16(ids.count)
        ids.append(id)
        codes[id] = code
        return code
    }

    // MARK: - Orders

    /// Whether row `lhs` comes before row `rhs` in `key`'s ascending order. Ties in capture time
    /// go by ID, as the SQL the language falls back to orders them.
    func precedes(_ lhs: Int, _ rhs: Int, by key: QuerySort.Key) -> Bool {
        switch key {
        case .captured:
            (captured[lhs], ids[lhs]) < (captured[rhs], ids[rhs])
        case .name:
            nameRanks[lhs] < nameRanks[rhs]
        case .rating:
            (Packed.rating(packed[lhs]), captured[lhs], ids[lhs]) < (
                Packed.rating(packed[rhs]),
                captured[rhs],
                ids[rhs],
            )
        case .edited:
            (editedAt[lhs], captured[lhs], ids[lhs]) < (editedAt[rhs], captured[rhs], ids[rhs])
        case .modified:
            (modifiedAt[lhs], captured[lhs], ids[lhs]) < (modifiedAt[rhs], captured[rhs], ids[rhs])
        case .size:
            (sizes[lhs], captured[lhs], ids[lhs]) < (sizes[rhs], captured[rhs], ids[rhs])
        }
    }

    func sort(_ order: inout ContiguousArray<Int32>, by key: QuerySort.Key) {
        captured.withUnsafeBufferPointer { captured in
            ids.withUnsafeBufferPointer { ids in
                switch key {
                case .captured:
                    order.sort { (captured[Int($0)], ids[Int($0)]) < (captured[Int($1)], ids[Int($1)]) }
                case .name:
                    nameRanks.withUnsafeBufferPointer { ranks in order.sort { ranks[Int($0)] < ranks[Int($1)] } }
                case .rating:
                    packed.withUnsafeBufferPointer { packed in
                        order.sort {
                            (Packed.rating(packed[Int($0)]), captured[Int($0)], ids[Int($0)])
                                < (Packed.rating(packed[Int($1)]), captured[Int($1)], ids[Int($1)])
                        }
                    }
                case .edited:
                    editedAt.withUnsafeBufferPointer { edited in
                        order.sort {
                            (edited[Int($0)], captured[Int($0)], ids[Int($0)])
                                < (edited[Int($1)], captured[Int($1)], ids[Int($1)])
                        }
                    }
                case .modified:
                    modifiedAt.withUnsafeBufferPointer { modified in
                        order.sort {
                            (modified[Int($0)], captured[Int($0)], ids[Int($0)])
                                < (modified[Int($1)], captured[Int($1)], ids[Int($1)])
                        }
                    }
                case .size:
                    sizes.withUnsafeBufferPointer { sizes in
                        order.sort {
                            (sizes[Int($0)], captured[Int($0)], ids[Int($0)])
                                < (sizes[Int($1)], captured[Int($1)], ids[Int($1)])
                        }
                    }
                }
            }
        }
    }

    mutating func setOrder(_ order: ContiguousArray<Int32>, for key: QuerySort.Key) {
        switch key {
        case .captured: byCaptured = order
        case .name: byName = order
        case .rating: byRating = order
        case .edited: byEdited = order
        case .modified: byModified = order
        case .size: bySize = order
        }
    }

    /// Drops the dead rows, numbering the rest again in the same order.
    mutating func compact() {
        var renumbered = ContiguousArray<Int32>(repeating: -1, count: rowCount)
        var next: Int32 = 0
        live.forEach { row in
            renumbered[row] = next
            next += 1
            return true
        }
        let live = live
        let count = count
        func kept<T>(_ column: ContiguousArray<T>) -> ContiguousArray<T> {
            var result = ContiguousArray<T>()
            result.reserveCapacity(count)
            live.forEach { row in
                result.append(column[row])
                return true
            }
            return result
        }
        ids = kept(ids)
        folders = kept(folders)
        captured = kept(captured)
        cameras = kept(cameras)
        lenses = kept(lenses)
        packed = kept(packed)
        iso = kept(iso)
        aperture = kept(aperture)
        focal = kept(focal)
        shutter = kept(shutter)
        kinds = kept(kinds)
        nameRanks = kept(nameRanks)
        editedAt = kept(editedAt)
        sizes = kept(sizes)
        modifiedAt = kept(modifiedAt)
        states = kept(states)
        creators = kept(creators)
        copyrights = kept(copyrights)
        customLabels = kept(customLabels)
        places = kept(places)
        megapixels = kept(megapixels)
        aspects = kept(aspects)
        orientations = kept(orientations)
        self.live = RowBits(rows: ids.count, filled: true)
        rowOfID.withUnsafeMutableBufferPointer { $0.update(repeating: -1) }
        for (row, id) in ids.enumerated() {
            rowOfID[Int(id)] = Int32(row)
        }
        for key in QuerySort.Key.allCases where keepsOrder(key) {
            setOrder(ContiguousArray(order(key).map { renumbered[Int($0)] }), for: key)
        }
    }

    /// Each row's rank is its place in the name order.
    mutating func renumberNames() {
        byName.withUnsafeBufferPointer { order in
            nameRanks.withUnsafeMutableBufferPointer { ranks in
                for (place, row) in order.enumerated() {
                    ranks[Int(row)] = Int32(place)
                }
            }
        }
    }
}

/// The packed `UInt16` of each row: rating (3 bits), flag (2), label (3), marked, edited, and the
/// details `has` asks about.
enum Packed {
    static let flagShift: UInt16 = 3
    static let labelShift: UInt16 = 5
    static let marked: UInt16 = 1 << 8
    static let edited: UInt16 = 1 << 9
    /// `Details` from here up.
    static let detailsShift: UInt16 = 10

    static func pack(_ row: ColumnStore.Row) -> UInt16 {
        let hot = row.hot
        var packed = UInt16(clamping: max(0, min(7, hot.rating)))
        packed |= UInt16(clamping: max(0, min(3, hot.flag))) << flagShift
        packed |= UInt16(clamping: max(0, min(7, hot.label))) << labelShift
        packed |= hot.marked ? marked : 0
        packed |= hot.edited ? edited : 0
        return packed | (row.details.rawValue & 0x1F) << detailsShift
    }

    @inline(__always)
    static func rating(_ packed: UInt16) -> UInt16 {
        packed & 0x7
    }

    @inline(__always)
    static func flag(_ packed: UInt16) -> UInt16 {
        packed >> flagShift & 0x3
    }

    @inline(__always)
    static func label(_ packed: UInt16) -> UInt16 {
        packed >> labelShift & 0x7
    }

    static func details(_ details: ColumnStore.Details) -> UInt16 {
        (details.rawValue & 0x1F) << detailsShift
    }
}

/// How numbers are kept in the store, and the SQL that computes the same from the index's columns
/// (`p` being `photos`). Each is whole: a comparison with a value of the language encodes the value
/// alike, so `f:2.8` matches an aperture of 2.8 however the file rounded it. 0 is none, except
/// where noted.
enum ColumnEncoding {
    /// Milliseconds, truncated as SQLite's `CAST` truncates; `Int64.min` for none.
    static func captured(_ seconds: Double?) -> Int64 {
        guard let seconds, !seconds.isNaN else { return .min }
        return saturated(seconds * 1000)
    }

    static let capturedSQL = """
    (CASE WHEN p.captured IS NULL THEN -9223372036854775807 - 1 ELSE CAST(p.captured * 1000 AS INTEGER) END)
    """

    /// Whole ISO, 1 to 65,535.
    static func iso(_ iso: Double?) -> UInt16 {
        UInt16(scaled(iso, by: 1, limit: Double(UInt16.max)))
    }

    static let isoSQL = scaledSQL("p.iso", by: "1", limit: "65535")

    /// Hundredths of an f-number, 1 to 65,535.
    static func aperture(_ aperture: Double?) -> UInt16 {
        UInt16(scaled(aperture, by: 100, limit: Double(UInt16.max)))
    }

    static let apertureSQL = scaledSQL("p.aperture", by: "100", limit: "65535")

    /// Tenths of a millimetre, 1 to 65,535.
    static func focal(_ focal: Double?) -> UInt16 {
        UInt16(scaled(focal, by: 10, limit: Double(UInt16.max)))
    }

    static let focalSQL = scaledSQL("p.focal", by: "10", limit: "65535")

    /// Microseconds, 1 to 4,294,967,295 (71 minutes).
    static func shutter(_ shutter: Double?) -> UInt32 {
        UInt32(scaled(shutter, by: 1_000_000, limit: Double(UInt32.max)))
    }

    static let shutterSQL = scaledSQL("p.shutter", by: "1000000", limit: "4294967295")

    /// Tenths of a megapixel, rounded half up, 1 to 65,535; 0 without both sides.
    static func megapixels(width: Int?, height: Int?) -> UInt16 {
        guard let width, let height, width > 0, height > 0 else { return 0 }
        return UInt16(max(1, min(65535, (Int64(width) * Int64(height) + 50000) / 100_000)))
    }

    static let megapixelsSQL = """
    (CASE WHEN p.width > 0 AND p.height > 0 \
    THEN max(1, min(65535, (CAST(p.width AS INTEGER) * CAST(p.height AS INTEGER) + 50000) / 100000)) ELSE 0 END)
    """

    /// The long side over the short in hundredths, rounded half up, 100 to 65,535; 0 without both sides.
    static func aspect(width: Int?, height: Int?) -> UInt16 {
        guard let width, let height, width > 0, height > 0 else { return 0 }
        let (long, short) = (Int64(max(width, height)), Int64(min(width, height)))
        return UInt16(min(65535, (long * 100 + short / 2) / short))
    }

    static let aspectSQL = """
    (CASE WHEN p.width > 0 AND p.height > 0 THEN min(65535, \
    (max(CAST(p.width AS INTEGER), CAST(p.height AS INTEGER)) * 100 \
    + min(CAST(p.width AS INTEGER), CAST(p.height AS INTEGER)) / 2) \
    / min(CAST(p.width AS INTEGER), CAST(p.height AS INTEGER))) ELSE 0 END)
    """

    /// Which way a photo is turned (`PhotoOrientation.code`), from its size as the index keeps it, which
    /// the indexer turns upright by EXIF's orientation, a raw's own rather than its sensor's; 0 without
    /// both sides.
    static func orientation(width: Int?, height: Int?) -> UInt8 {
        PhotoOrientation(width: width, height: height)?.code ?? 0
    }

    static let orientationSQL = """
    (CASE WHEN p.width > 0 AND p.height > 0 \
    THEN (CASE WHEN p.width > p.height THEN 1 WHEN p.width < p.height THEN 2 ELSE 3 END) ELSE 0 END)
    """

    /// Seconds since 2001, for a photo with an edit; `Int32.min` without.
    static func editedAt(edited: Bool, sidecarModified: Double?) -> Int32 {
        guard edited, let modified = sidecarModified, !modified.isNaN else { return .min }
        let seconds = modified - 978_307_200
        if seconds >= 2_147_483_647 {
            return .max
        }
        return seconds <= -2_147_483_647 ? -2_147_483_647 : Int32(seconds)
    }

    static let editedAtSQL = """
    (CASE WHEN p.edited != 0 AND p.sidecar_modified IS NOT NULL \
    THEN max(-2147483647, min(2147483647, CAST(p.sidecar_modified - 978307200 AS INTEGER))) ELSE -2147483648 END)
    """

    /// Seconds since 2001 as `editedAt` keeps them; `Int32.min` for none.
    static func modifiedAt(_ modified: Double?) -> Int32 {
        guard let modified, !modified.isNaN else { return .min }
        return editedAt(edited: true, sidecarModified: modified)
    }

    static let modifiedAtSQL = """
    (CASE WHEN p.modified IS NULL THEN -2147483648 \
    ELSE max(-2147483647, min(2147483647, CAST(p.modified - 978307200 AS INTEGER))) END)
    """

    /// Bytes, up to 4 GiB less one: larger files sort together at the end.
    static func fileSize(_ size: Int64) -> UInt32 {
        UInt32(clamping: max(size, 0))
    }

    static let fileSizeSQL = "max(0, min(4294967295, p.size))"

    /// `PhotoRecord.State`'s bits, as the state column of the store keeps them.
    static let stateSQL = "(p.state & 255)"

    static let ratingSQL = "max(0, min(7, p.rating))"
    static let flagSQL = "max(0, min(3, p.flag))"
    static let labelSQL = "max(0, min(7, p.label))"
    static let kindSQL = "max(0, min(255, p.kind))"

    /// The details `has` asks about, as the extra columns' scan reads them.
    static let locationSQL = "(p.latitude IS NOT NULL AND p.longitude IS NOT NULL)"
    static let titleSQL = "(coalesce(p.title, '') != '')"
    static let captionSQL = "(coalesce(p.caption, '') != '')"
    static let xmpSQL = "(p.xmp_modified IS NOT NULL)"
    static let keywordsSQL = "EXISTS (SELECT 1 FROM photo_keywords k WHERE k.photo = p.id)"

    /// Whether a text column has a name, as the code columns read it: an empty text is none.
    static func presentSQL(_ column: String) -> String {
        "(coalesce(\(column), '') != '')"
    }

    /// `value` times `scale`, rounded half up and truncated as SQLite's `CAST` does, between 1 and
    /// `limit`; 0 for none.
    static func scaled(_ value: Double?, by scale: Double, limit: Double) -> UInt64 {
        guard let value, !value.isNaN else { return 0 }
        let scaled = value * scale + 0.5
        if scaled >= limit {
            return UInt64(limit)
        }
        return scaled < 1 ? 1 : UInt64(scaled)
    }

    private static func scaledSQL(_ column: String, by scale: String, limit: String) -> String {
        "(CASE WHEN \(column) IS NULL THEN 0 ELSE max(1, min(\(limit), CAST(\(column) * \(scale) + 0.5 AS INTEGER))) END)"
    }

    /// `value` truncated to a whole number, saturating at `Int64`'s ends as SQLite's `CAST` does.
    static func saturated(_ value: Double) -> Int64 {
        if value >= 9_223_372_036_854_775_808.0 {
            return .max
        }
        return value <= -9_223_372_036_854_775_808.0 ? .min : Int64(value)
    }
}

/// The names' Finder keys side by side, so a million of them sort without an array each.
struct NameKeys {
    private var bytes = ContiguousArray<UInt8>()
    private var offsets: ContiguousArray<Int32> = [0]
    /// Each key's first sixteen bytes, big-endian and padded with zeros, in two numbers a key: the
    /// whole key, for most names.
    private var prefixes = ContiguousArray<UInt64>()

    init() {}

    init(_ names: some Sequence<String>) {
        for name in names {
            append(name: name)
        }
    }

    /// Room for `count` names of about 16 bytes.
    mutating func reserveCapacity(_ count: Int) {
        bytes.reserveCapacity(count * 16)
        offsets.reserveCapacity(count + 1)
        prefixes.reserveCapacity(2 * count)
    }

    mutating func append(name: String) {
        let start = bytes.count
        FinderOrder.appendKey(of: name, to: &bytes)
        offsets.append(Int32(clamping: bytes.count))
        for half in 0 ..< 2 {
            var prefix: UInt64 = 0
            for index in start + 8 * half ..< start + 8 * half + 8 {
                prefix = prefix << 8 | UInt64(index < bytes.count ? bytes[index] : 0)
            }
            prefixes.append(prefix)
        }
    }

    /// Adds `other`'s keys after these.
    mutating func append(contentsOf other: NameKeys) {
        let base = Int32(clamping: bytes.count)
        bytes.append(contentsOf: other.bytes)
        offsets.append(contentsOf: other.offsets.dropFirst().lazy.map { $0 + base })
        prefixes.append(contentsOf: other.prefixes)
    }

    /// How key `lhs` orders against key `rhs`: true before, false after, nil the same.
    func compare(_ lhs: Int, _ rhs: Int) -> Bool? {
        if prefixes[2 * lhs] != prefixes[2 * rhs] {
            return prefixes[2 * lhs] < prefixes[2 * rhs]
        }
        if prefixes[2 * lhs + 1] != prefixes[2 * rhs + 1] {
            return prefixes[2 * lhs + 1] < prefixes[2 * rhs + 1]
        }
        let (left, right) = (offsets[lhs + 1] - offsets[lhs], offsets[rhs + 1] - offsets[rhs])
        if left <= 16, right <= 16 {
            return left == right ? nil : left < right
        }
        return bytes.withUnsafeBufferPointer { bytes in
            let left = UnsafeBufferPointer(rebasing: bytes[Int(offsets[lhs]) ..< Int(offsets[lhs + 1])])
            let right = UnsafeBufferPointer(rebasing: bytes[Int(offsets[rhs]) ..< Int(offsets[rhs + 1])])
            if left.elementsEqual(right) {
                return nil
            }
            return left.lexicographicallyPrecedes(right)
        }
    }
}
