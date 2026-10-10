import Foundation
import RedlampDocument

/// What a photo gets from a Lightroom Classic catalog (LIB-29): Lightroom's value of each field it has
/// one for, its keywords and its collections.
struct LightroomValues: Sendable, Hashable {
    var rating = 0
    var flag: PhotoFlag?
    /// The label's text, a colour's name in any label set or a custom label's.
    var label: String?
    var mark = false
    var title: String?
    var caption: String?
    var creator: String?
    var copyright: String?
    var location: PhotoLocation?
    var keywords: [KeywordPath] = []
    var collections: [CollectionPath] = []

    /// What it does to the photo's sidecar fields, keywords aside, which a keyword batch gives: Lightroom's
    /// value replaces the photo's where Lightroom has one, and its collections join the photo's.
    var edits: [String: FieldEdit] {
        var fields: [MetadataField] = []
        if rating > 0 {
            fields.append(.rating(rating))
        }
        if let flag {
            fields.append(.flag(flag))
        }
        if let label {
            fields.append(.namedLabel(label))
        }
        if mark {
            fields.append(.mark(true))
        }
        fields += [
            title.map(MetadataField.title),
            caption.map(MetadataField.caption),
            creator.map(MetadataField.creator),
            copyright.map(MetadataField.copyright),
        ].compactMap(\.self)
        if let location {
            fields += [
                location.sublocation.map(MetadataField.sublocation),
                location.city.map(MetadataField.city),
                location.state.map(MetadataField.state),
                location.country.map(MetadataField.country),
                location.countryCode.map(MetadataField.countryCode),
            ].compactMap(\.self)
        }
        var edits = MetadataField.edits(fields)
        if !collections.isEmpty {
            edits["collections"] = .add(collections.map(\.text))
        }
        return edits
    }
}

/// A Lightroom Classic catalog's import into the library, worked out from the catalog and the index as they
/// are, with its report (LIB-29). Nothing is written: `LightroomImport` runs it.
///
/// - **Folders:** each root folder is looked for where the catalog says, then where the catalog says it is
///   from the catalog's own folder, then where the user says it went (`moved`). Those on this Mac the library
///   doesn't have are added before importing, and their photos found once they're indexed.
/// - **Photos** are matched by path in the index: the name as the folder lists it, then in Unicode's composed
///   form ignoring case, when only one photo answers. A JPEG Lightroom keeps as one photo with its raw gets
///   the raw's fields, as Redlamp keeps a pair together.
/// - **Fields:** Lightroom's value replaces the library's where Lightroom has one (a rating, a pick or reject,
///   a label, IPTC's fields); keywords and collections join the photo's; the Quick Collection is the mark.
/// - **Collections** keep their places, sets around them; one at a place where the library has another kind
///   of thing is renamed “(Lightroom)”. Smart collections come across when every rule maps.
public struct LightroomPlan: Sendable {
    public let report: LightroomReport
    /// The catalog's name, as titles of its batches name it: `Lightroom Catalog`.
    public let name: String
    /// Each photo found and what it gets, by its ID in the index, in ID order.
    let photos: [(id: Int64, values: LightroomValues)]
    /// The keywords the definitions keep: those with options to keep, and those no photo found has.
    let keywords: [KeywordPath: KeywordOptions]
    /// The sets, smart collections and collections without photos found that the definitions keep.
    let collections: [CollectionPath: CollectionOptions]
    /// The root folders on this Mac the library doesn't have: importing adds them first.
    public let foldersToAdd: [URL]

    /// The plan for `catalog` against the library whose index is `index`, the roots `moved` names (by the
    /// catalog's paths) looked for where they went.
    public static func make(
        _ catalog: LightroomCatalog, index: LibraryIndex, paths: LibraryPaths? = nil, moved: [String: URL] = [:],
    ) async throws -> LightroomPlan {
        var planner = LightroomPlanner(catalog: catalog, moved: moved)
        let library = try await index.read { reader in
            let removed = try Set(reader.removedRoots().values)
            return try reader.roots().map(\.path).filter { !removed.contains($0) }
        }
        planner.locateRoots(library: library)
        let requests = planner.requests()
        let photos = catalog.photos
        let matches = try await index.read { reader in try LightroomPlanner.match(requests, photos, in: reader) }
        let metadata = LibraryMetadata(index: index, paths: paths)
        let existing = try await metadata.collections.list()
        planner.collect(matches, existing: existing)
        let shown = try await index.read { [found = planner.found] reader in
            try LightroomPlanner.shown(found, in: reader)
        }
        planner.count(shown)
        return planner.plan()
    }
}

/// Works out a plan, step by step.
struct LightroomPlanner {
    let catalog: LightroomCatalog
    let moved: [String: URL]
    var report: LightroomReport
    /// Each root's folder on this Mac, by the root's ID in the catalog.
    var rootPaths: [Int64: String] = [:]
    /// The roots whose photos the index can have.
    var indexed: Set<Int64> = []
    var foldersToAdd: [URL] = []
    /// What each photo found gets, by its ID in the index.
    var found: [Int64: LightroomValues] = [:]
    /// The row each photo found had, by its ID in the index.
    var rows: [Int64: PhotoRecord] = [:]
    var keywordDefinitions: [KeywordPath: KeywordOptions] = [:]
    var collectionDefinitions: [CollectionPath: CollectionOptions] = [:]

    init(catalog: LightroomCatalog, moved: [String: URL]) {
        self.catalog = catalog
        self.moved = moved
        report = LightroomReport(catalog: catalog.url.path, version: catalog.version)
        report.notes = catalog.notes
    }

    // MARK: - Folders

    /// Finds each root on this Mac, and whether the library has it.
    mutating func locateRoots(library: [String]) {
        let catalogFolder = catalog.url.deletingLastPathComponent()
        for root in catalog.roots {
            var path: String?
            var wasMoved = false
            if let url = moved[root.path] ?? moved[Self.trimmed(root.path)] {
                path = LibraryIndexer.path(url)
                wasMoved = true
            } else if root.path.hasPrefix("/"), Self.isFolder(root.path) {
                path = LibraryIndexer.path(URL(fileURLWithPath: root.path, isDirectory: true))
            } else if let relative = Self.relativePath(of: root), !relative.isEmpty {
                let beside = catalogFolder.appending(path: relative, directoryHint: .isDirectory)
                if Self.isFolder(beside.path) {
                    path = LibraryIndexer.path(beside)
                    wasMoved = true
                }
            }
            var state = LightroomReport.Root.State.missing
            if let path {
                rootPaths[root.id] = path
                if library.contains(where: { path == $0 || path.hasPrefix($0 == "/" ? $0 : $0 + "/") }) {
                    state = .inLibrary
                    indexed.insert(root.id)
                } else if Self.isFolder(path) {
                    state = .notInLibrary
                    foldersToAdd.append(URL(fileURLWithPath: path, isDirectory: true))
                }
            }
            report.roots.append(LightroomReport.Root(
                id: root.id, name: root.name, lightroomPath: root.path, path: path, moved: wasMoved, state: state,
                photos: 0, found: 0,
            ))
        }
    }

    /// The catalog's own path to the root from its folder, which Lightroom keeps beside the absolute one.
    static func relativePath(of root: LightroomCatalog.Root) -> String? {
        root.relativePath.map { $0.replacingOccurrences(of: "\\", with: "/") }
    }

    static func isFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// A folder whose photos are looked for in the index: its path, and its photos' places in the catalog.
    struct Request: Sendable {
        let path: String
        let photos: [Int]
    }

    /// The catalog's folders in the roots the library has, with their photos.
    mutating func requests() -> [Request] {
        var byFolder: [Int64: [Int]] = [:]
        var perRoot: [Int64: Int] = [:]
        for (place, photo) in catalog.photos.enumerated() {
            byFolder[photo.folder, default: []].append(place)
            if let folder = catalog.folders[photo.folder] {
                perRoot[folder.root, default: 0] += 1
            }
        }
        for place in report.roots.indices {
            report.roots[place].photos = perRoot[report.roots[place].id] ?? 0
            switch report.roots[place].state {
            case .inLibrary: break
            case .notInLibrary: report.waiting += report.roots[place].photos
            case .missing: report.unlocated += report.roots[place].photos
            }
        }
        report.photos = catalog.photos.count
        return byFolder.sorted { $0.key < $1.key }.compactMap { folderID, places in
            guard let folder = catalog.folders[folderID], indexed.contains(folder.root),
                  let root = rootPaths[folder.root]
            else { return nil }
            let inside = folder.path.replacingOccurrences(of: "\\", with: "/")
            let path = inside.isEmpty ? root : (root == "/" ? "" : root) + "/" + inside
            return Request(path: LibraryIndexer.path(URL(fileURLWithPath: path, isDirectory: true)), photos: places)
        }
    }

    // MARK: - Photos

    /// A photo of the catalog found in the index: its row, and the rows of the JPEGs Lightroom kept with it.
    struct Match: Sendable {
        let row: PhotoRecord
        let pairs: [PhotoRecord]
    }

    /// The extensions of the files Lightroom keeps with a raw as one photo that Redlamp keeps as photos.
    static let pairedExtensions: Set = ["jpg", "jpeg", "heic", "heif", "tif", "tiff", "png"]

    /// Each photo the index has, by its place in the catalog.
    static func match(_ requests: [Request], _ photos: [LightroomCatalog.Photo], in reader: LibraryIndex.Reader)
        throws -> [Int: Match] {
        var matches: [Int: Match] = [:]
        for request in requests {
            guard let folder = try reader.folder(path: request.path) else { continue }
            var exact: [String: PhotoRecord] = [:]
            var folded: [String: [PhotoRecord]] = [:]
            for row in try reader.photos(inFolder: folder.id) where !row.state.contains(.missing) {
                exact[row.name] = row
                folded[fold(row.name), default: []].append(row)
            }
            func find(_ name: String) -> PhotoRecord? {
                if let row = exact[name] {
                    return row
                }
                let candidates = folded[fold(name)] ?? []
                return candidates.count == 1 ? candidates[0] : nil
            }
            for place in request.photos {
                let photo = photos[place]
                guard let row = find(photo.name) else { continue }
                let stem = (photo.name as NSString).deletingPathExtension
                let pairs = photo.sidecarExtensions.filter { pairedExtensions.contains($0.lowercased()) }
                    .compactMap { find(stem + "." + $0) }.filter { $0.id != row.id }
                matches[place] = Match(row: row, pairs: pairs)
            }
        }
        return matches
    }

    static func fold(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Gives each photo found what the catalog has for it, and works out the keywords and collections.
    mutating func collect(_ matches: [Int: Match], existing: CollectionList) {
        let keywordPaths = keywordPaths()
        let (collectionPaths, marked) = collectionPaths(existing: existing)
        collectionPathsByID = collectionPaths
        var collectionsOf: [Int64: [CollectionPath]] = [:]
        for collection in catalog.collections.values {
            guard let path = collectionPaths[collection.id] else { continue }
            for photo in collection.photos {
                collectionsOf[photo, default: []].append(path)
            }
        }
        var rootsFound: [Int64: Int] = [:]
        var placed = 0
        var notFound: [String] = []
        for (place, photo) in catalog.photos.enumerated() {
            guard let match = matches[place] else {
                if let folder = catalog.folders[photo.folder], indexed.contains(folder.root) {
                    report.notFound += 1
                    if notFound.count < LightroomReport.listed, let root = rootPaths[folder.root] {
                        notFound.append(root + "/" + folder.path + photo.name)
                    }
                }
                continue
            }
            if let folder = catalog.folders[photo.folder] {
                rootsFound[folder.root, default: 0] += 1
            }
            var values = LightroomValues(
                rating: photo.rating, flag: photo.flag, label: photo.label, mark: marked.contains(photo.id),
                title: photo.title, caption: photo.caption, creator: photo.creator, copyright: photo.copyright,
                location: photo.location,
            )
            values.keywords = KeywordPath.paths(photo.keywords.compactMap { keywordPaths[$0]?.text })
            values.collections = Array(Set(collectionsOf[photo.id] ?? [])).sorted()
            if photo.hasGPS, match.row.latitude == nil {
                placed += 1
            }
            for row in [match.row] + match.pairs where found[row.id] == nil {
                found[row.id] = values
                rows[row.id] = row
            }
            report.pairs += match.pairs.count
        }
        report.found = matches.count
        report.notFoundPaths = notFound
        for place in report.roots.indices {
            report.roots[place].found = rootsFound[report.roots[place].id] ?? 0
        }
        if placed > 0 {
            report.left.append(LightroomReport.Left(
                what: "places Lightroom's map gave photos", count: placed,
                why: "Redlamp reads where a photo was taken from its file",
            ))
        }
        defineKeywords(keywordPaths)
    }

    /// Each keyword's path, the keyword list's own top left out.
    func keywordPaths() -> [Int64: KeywordPath] {
        var paths: [Int64: KeywordPath] = [:]
        func path(_ id: Int64, depth: Int) -> KeywordPath? {
            if let known = paths[id] {
                return known
            }
            guard depth < 64, let keyword = catalog.keywords[id], let name = keyword.name else { return nil }
            let parent = keyword.parent.flatMap { path($0, depth: depth + 1) }
            let made = parent.map { $0.appending(name) } ?? KeywordPath(names: [name])
            paths[id] = made ?? nil
            return made ?? nil
        }
        for id in catalog.keywords.keys.sorted() {
            _ = path(id, depth: 0)
        }
        return paths
    }

    /// Keywords with options other than the defaults, and those no photo found has, for the definitions.
    mutating func defineKeywords(_ paths: [Int64: KeywordPath]) {
        var used = Set<KeywordPath>()
        for values in found.values {
            for keyword in values.keywords {
                used.insert(keyword)
                used.formUnion(keyword.ancestors)
            }
        }
        for (id, path) in paths {
            guard let keyword = catalog.keywords[id] else { continue }
            let options = KeywordOptions(
                synonyms: keyword.synonyms, includeOnExport: keyword.includeOnExport,
                exportContainingKeywords: keyword.exportContainingKeywords, exportSynonyms: keyword.exportSynonyms,
                isPerson: keyword.isPerson,
            )
            report.keywords += 1
            report.synonyms += options.synonyms.count
            report.notExported += keyword.includeOnExport ? 0 : 1
            report.people += keyword.isPerson ? 1 : 0
            if !options.isDefault || !used.contains(path) {
                keywordDefinitions[path] = options
            }
        }
    }

    // MARK: - Collections

    /// Each collection's place in the library's list, and the photos in the Quick Collection; sets, smart
    /// collections and output collections reported, renames made where the library has another kind of
    /// thing at a place.
    mutating func collectionPaths(existing: CollectionList) -> ([Int64: CollectionPath], Set<Int64>) {
        var paths: [Int64: CollectionPath] = [:]
        var kinds: [CollectionPath: CollectionKind] = existing.collections.mapValues(\.kind)
        var marked = Set<Int64>()
        var system: [String] = []
        let ordered = catalog.collections.values.sorted { depth(of: $0) != depth(of: $1)
            ? depth(of: $0) < depth(of : $1): $0.id < $1.id
        }
        for collection in ordered {
            let kind: CollectionKind
            switch collection.kind {
            case .set: kind = .set
            case .collection, .output: kind = .collection
            case .smart: kind = .smart
            case .quick:
                marked.formUnion(collection.photos)
                continue
            case .system:
                system.append(collection.name)
                continue
            }
            let parent = collection.parent.flatMap { paths[$0] }
            guard collection.parent == nil || parent != nil || catalog.collections[collection.parent ?? 0] == nil,
                  var path = parent.map({ $0.appending(collection.name) }) ?? CollectionPath(names: [collection.name])
            else { continue }
            if let other = kinds[path], other != kind {
                let original = path
                var number = 1
                repeat {
                    let suffix = number == 1 ? " (Lightroom)" : " (Lightroom \(number))"
                    path = (parent.map { $0.appending(collection.name + suffix) }
                        ?? CollectionPath(names: [collection.name + suffix])) ?? original
                    number += 1
                } while kinds[path].map {
                    $0 != kind
                } ?? false
                report.renamed[original.text] = path.name
            }
            kinds[path] = kind
            paths[collection.id] = path
            switch collection.kind {
            case .set:
                report.sets += 1
                collectionDefinitions[path] = .set
            case .smart:
                var smart = LightroomReport.Smart(path: path.text)
                let mapped = collection.rules.map(LightroomSmartRules.query)
                    ?? LightroomSmartQuery(reasons: ["the catalog doesn't hold its rules"])
                smart.query = mapped.query
                smart.differences = mapped.differences
                smart.reasons = mapped.reasons
                report.smart.append(smart)
                if let query = mapped.query {
                    collectionDefinitions[path] = .smart(query)
                } else {
                    paths[collection.id] = nil
                    kinds[path] = existing[path]?.kind
                }
            case .output:
                report.outputs.append(path.text)
                report.collections += 1
            default:
                report.collections += 1
            }
            for ancestor in path.ancestors where collectionDefinitions[ancestor] == nil && existing[ancestor] == nil {
                collectionDefinitions[ancestor] = .set
            }
        }
        if !system.isEmpty {
            report.left.append(LightroomReport.Left(
                what: "of Lightroom's own collections (\(system.sorted().joined(separator: ", ")))",
                count: system.count,
                why: "Lightroom keeps them for itself",
            ))
        }
        return (paths, marked)
    }

    private func depth(of collection: LightroomCatalog.Collection) -> Int {
        var depth = 0
        var parent = collection.parent
        while let id = parent, depth < 64 {
            depth += 1
            parent = catalog.collections[id]?.parent
        }
        return depth
    }

    // MARK: - What the library shows now

    /// What the index shows of each photo found: its keywords and, for those Lightroom puts in collections,
    /// its collections.
    struct Shown: Sendable {
        var keywords: [Int64: [KeywordPath]] = [:]
        var collections: [Int64: [CollectionPath]] = [:]
    }

    static func shown(_ found: [Int64: LightroomValues], in reader: LibraryIndex.Reader) throws -> Shown {
        var shown = Shown()
        let ids = found.keys.sorted()
        shown.keywords = try reader.keywordPaths(ofPhotos: ids.filter { !(found[$0]?.keywords.isEmpty ?? true) })
        for id in ids where !(found[id]?.collections.isEmpty ?? true) {
            shown.collections[id] = try reader.collections(ofPhoto: id)
        }
        return shown
    }

    /// Counts each field Lightroom gives, those replacing another value, and the photos that change.
    mutating func count(_ shown: Shown) {
        var tally = FieldTally()
        for (id, values) in found {
            guard let row = rows[id] else { continue }
            tally.add(values, row: row, keywords: shown.keywords[id] ?? [], collections: shown.collections[id] ?? [])
        }
        report.fields = tally.fields
        report.differing = tally.differing
        report.changing = tally.changing
        addEmptyCollections(except: tally.collectionsWithPhotos)
        addLeftovers()
    }

    /// The catalog's collections no photo found is in, kept in the definitions so they're in the list.
    private mutating func addEmptyCollections(except used: Set<CollectionPath>) {
        let paths = collectionPathsByID
        for collection in catalog.collections.values {
            switch collection.kind {
            case .collection, .output:
                guard let path = paths[collection.id], !used.contains(path) else { continue }
                collectionDefinitions[path] = collectionDefinitions[path] ?? CollectionOptions()
            default:
                continue
            }
        }
    }

    /// The collections' places as `collect` gave them, kept for the definitions.
    var collectionPathsByID: [Int64: CollectionPath] = [:]

    /// What the catalog holds that doesn't come across.
    private mutating func addLeftovers() {
        if !catalog.virtualCopies.isEmpty {
            report.left.append(LightroomReport.Left(
                what: "virtual copies", count: catalog.virtualCopies.count,
                why: "a virtual copy is another edit of its photo in Lightroom, and Lightroom's edits stay there",
            ))
        }
        if catalog.edited > 0 {
            report.left.append(LightroomReport.Left(
                what: "photos edited in Lightroom", count: catalog.edited,
                why: "Lightroom's Develop settings stay in Lightroom: Redlamp shows the photos as they were shot",
            ))
        }
        if catalog.stacks > 0 {
            report.left.append(LightroomReport.Left(
                what: "stacks", count: catalog.stacks, why: "Lightroom's stacks aren't brought across",
            ))
        }
    }

    func plan() -> LightroomPlan {
        let name = (catalog.url.lastPathComponent as NSString).deletingPathExtension
        return LightroomPlan(
            report: report, name: name,
            photos: found.sorted { $0.key < $1.key }.map { (id: $0.key, values: $0.value) },
            keywords: keywordDefinitions, collections: collectionDefinitions, foldersToAdd: foldersToAdd,
        )
    }
}

/// Counts the fields Lightroom gives the photos found, those replacing another value, and the photos that change.
struct FieldTally {
    var fields = LightroomReport.Fields()
    var differing = LightroomReport.Fields()
    var changing = 0
    var collectionsWithPhotos = Set<CollectionPath>()
    private var changes = false

    mutating func add(
        _ values: LightroomValues, row: PhotoRecord, keywords: [KeywordPath], collections: [CollectionPath],
    ) {
        changes = false
        if values.rating > 0 {
            note(\.ratings, same: row.rating == values.rating, other: row.rating > 0)
        }
        if values.flag == .pick {
            note(\.picks, same: row.flag == .pick, other: row.flag != nil)
        }
        if values.flag == .reject {
            note(\.rejects, same: row.flag == .reject, other: row.flag != nil)
        }
        if let label = values.label {
            let other = row.label != nil || row.customLabel != nil
            if let colour = XMPLabelNames.label(named: label) ?? ColorLabel(rawValue: label.lowercased()) {
                note(\.labels, same: row.label == colour, other: other)
            } else {
                note(\.customLabels, same: row.customLabel == label, other: other)
            }
        }
        if values.mark {
            note(\.marks, same: row.marked, other: false)
        }
        text(\.titles, values.title, row.title)
        text(\.captions, values.caption, row.caption)
        text(\.creators, values.creator, row.creator)
        text(\.copyrights, values.copyright, row.copyright)
        if let location = values.location {
            let current = row.location ?? PhotoLocation()
            note(\.locations, same: Self.holds(current, location), other: !current.isEmpty)
        }
        if !values.keywords.isEmpty {
            note(\.keywords, same: Set(values.keywords).isSubset(of: Set(keywords)), other: false)
        }
        if !values.collections.isEmpty {
            collectionsWithPhotos.formUnion(values.collections)
            note(\.collections, same: Set(values.collections).isSubset(of: Set(collections)), other: false)
        }
        changing += changes ? 1 : 0
    }

    /// One field given: counted, and as differing when the photo shows `other` value than Lightroom's.
    private mutating func note(_ field: WritableKeyPath<LightroomReport.Fields, Int>, same: Bool, other: Bool) {
        fields[keyPath: field] += 1
        guard !same else { return }
        changes = true
        if other {
            differing[keyPath: field] += 1
        }
    }

    private mutating func text(
        _ field: WritableKeyPath<LightroomReport.Fields, Int>,
        _ value: String?,
        _ current: String?,
    ) {
        guard let value else { return }
        note(field, same: current == value, other: !(current ?? "").isEmpty)
    }

    /// Whether `current` already holds each part of `location` it has.
    static func holds(_ current: PhotoLocation, _ location: PhotoLocation) -> Bool {
        func part(_ given: String?, _ held: String?) -> Bool {
            given == nil || given == held
        }
        return part(location.sublocation, current.sublocation) && part(location.city, current.city)
            && part(location.state, current.state) && part(location.country, current.country)
            && part(location.countryCode, current.countryCode)
    }
}
