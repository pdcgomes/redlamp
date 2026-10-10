import CoreGraphics
import Foundation
import Observation
import RedlampLibrary

/// Which of Compare's two photos.
public enum CompareSide: String, Sendable {
    case select, candidate

    var other: CompareSide {
        self == .select ? .candidate : .select
    }
}

/// Compare's two photos, which of them is active and how they're zoomed (LIB-16). Survey keeps nothing of its own:
/// it shows the selection.
@MainActor
@Observable
public final class LibraryCompare {
    /// The most photos Survey lays out: a selection of thousands shows these, from the active one's place.
    public static let surveyLimit = 64

    /// The photo the candidates are compared with.
    public internal(set) var select: URL?
    /// The photo compared with the select; nil when the source has no other.
    public internal(set) var candidate: URL?
    /// The side whose photo is active, which a photo chosen elsewhere, in the filmstrip, takes the place of.
    public internal(set) var activeSide = CompareSide.select
    /// Whether the two zoom and pan together, as Lightroom Classic's lock has them.
    public internal(set) var isLinked = true
    /// The active photo's place at 1:1: the point of it at the middle of its view, 0 ... 1 across and down. Its zoom
    /// is the loupe's (`LibraryViewState.loupeZoom`), so Z, Space, a click and the toolbar's Fit and 1:1 reach it.
    public internal(set) var focus = CGPoint(x: 0.5, y: 0.5)
    /// The other photo's zoom and place while unlinked; linked, it shows the active one's.
    var unlinked = (zoom: LoupeZoom.fit, focus: CGPoint(x: 0.5, y: 0.5))

    public func photo(_ side: CompareSide) -> URL? {
        side == .select ? select : candidate
    }
}

/// Compare (C) and Survey (N) in the Library module (LIB-16, LIB-13), as Lightroom Classic has them. Both show the
/// grid's cells: a closed stack, or a raw and its JPEG, is one photo there, its first, and stands for all of them,
/// as in the grid.
///
/// - **Compare** shows the select and a candidate side by side. Both are selected, and the active one is the model's
///   `selection`, which a click on the other changes. ← and → change the candidate, in the grid's order past the
///   select; ↑ makes the candidate the select and the photo after it the candidate; ↓ swaps the two, the active
///   photo staying active. The two zoom (Z, Space, a click) and pan (a drag) together until they're unlinked;
///   linked again, the other takes the active one's zoom and place. A photo chosen elsewhere, in the filmstrip,
///   takes the active one's place, and the selection is kept to the two.
/// - **Survey** lays out the photos selected as large as they fit, the active one marked. A click makes another
///   active, the arrow keys move between them, and a photo's × takes it out of the selection, and so out of Survey,
///   which stays, until one is left.
/// - **In both** the culling keys reach the active photo alone; with ⇧ or Auto Advance, Compare's candidate moves on
///   and Survey's next photo becomes active. The right panels follow the active photo, as they do in the loupe; E,
///   G and Esc leave with the selection as it is.
public extension EditorModel {
    /// Compare's photos and zoom.
    var libraryCompare: LibraryCompare {
        if let compare = Self.compares.object(forKey: self) {
            return compare
        }
        let compare = LibraryCompare()
        Self.compares.setObject(compare, forKey: self)
        return compare
    }

    private static let compares = NSMapTable<EditorModel, LibraryCompare>.weakToStrongObjects()

    /// Whether Library shows Compare or Survey, whose keys reach the active photo alone.
    internal var showsCompareOrSurvey: Bool {
        module == .library && (libraryView == .compare || libraryView == .survey)
    }

    /// The photo whose cell stands for `url`'s in the grid: itself, or the first of the closed stack it's in.
    internal func cellPhoto(of url: URL?, in order: GridOrder) -> URL? {
        guard let url, let id = library.photoID(of: url) else { return nil }
        guard let cell = order.cell(for: id), cell != id else { return url }
        return library.url(ofPhoto: cell)
    }

    /// The photos cell `id` stands for: a closed stack's, a raw and its JPEG; else the photo alone.
    private func photos(ofCell id: Int64, in order: GridOrder) -> [Int64] {
        let photos = order.stacks?.photos(of: id) ?? []
        return photos.isEmpty ? [id] : photos
    }

    // MARK: - Compare

    /// C: the active photo as the select beside a candidate, the photo selected after it, else the one after it in
    /// the grid's order (before it, at the end); both selected, the select active.
    @discardableResult
    func showCompare() -> Bool {
        let order = gridOrder
        guard let active = cellPhoto(of: selection, in: order),
              let id = library.photoID(of: active) else { return false }
        let compare = libraryCompare
        let candidate = selectedCell(after: id, in: order) ?? order.cell(1, from: id) ?? order.cell(-1, from: id)
        compare.select = active
        compare.candidate = candidate.flatMap(library.url(ofPhoto:))
        if compare.activeSide != .select {
            activateCompared(.select)
        }
        selectCompared()
        showLibrary(.compare)
        return true
    }

    /// The cell of the photo selected after cell `id`'s in the list's order, back to the first after the last; nil
    /// unless a photo of another cell is selected.
    private func selectedCell(after id: Int64, in order: GridOrder) -> Int64? {
        guard photoSelection.count > 1 else { return nil }
        let cells = photoSelection.ids(in: library.photoList).map { order.cell(for: $0) ?? $0 }
        guard let place = cells.firstIndex(of: id) else { return cells.first }
        return (1 ..< max(cells.count, 1)).lazy.map { cells[(place + $0) % cells.count] }.first { $0 != id }
    }

    /// ← and →: the candidate becomes the photo before or after it in the grid's order, past the select. False at
    /// either end.
    @discardableResult
    func stepCandidate(by offset: Int) -> Bool {
        let compare = libraryCompare
        let order = gridOrder
        guard let from = (compare.candidate ?? compare.select).flatMap(library.photoID(of:)) else { return false }
        let select = compare.select.flatMap(library.photoID(of:)).flatMap(order.cell(for:))
        var next = order.cell(offset, from: from)
        if let found = next, found == select {
            next = order.cell(offset, from: found)
        }
        guard let next else { return false }
        guard let url = library.url(ofPhoto: next) else {
            library.askForRows(ofPhotos: [next])
            return false
        }
        compare.candidate = url
        selectCompared()
        return true
    }

    /// ↑: the candidate becomes the select and the photo after it the candidate, the select active (Lightroom
    /// Classic's Make Select).
    @discardableResult
    func makeCandidateSelect() -> Bool {
        let compare = libraryCompare
        guard let promoted = compare.candidate, let id = library.photoID(of: promoted) else { return false }
        let order = gridOrder
        let next = order.cell(1, from: id) ?? order.cell(-1, from: id)
        let old = compare.select
        compare.select = promoted
        compare.candidate = next.flatMap(library.url(ofPhoto:)) ?? old
        compare.activeSide = .select
        selectCompared()
        return true
    }

    /// ↓: the select and the candidate change places, the active photo staying active.
    @discardableResult
    func swapCompared() -> Bool {
        let compare = libraryCompare
        guard let select = compare.select, let candidate = compare.candidate else { return false }
        compare.select = candidate
        compare.candidate = select
        compare.activeSide = compare.activeSide.other
        selectCompared()
        return true
    }

    /// A click on `side`'s photo: it becomes the active photo. Unlinked, it takes the loupe's zoom, the active photo's,
    /// and the one it leaves keeps its own.
    func activateCompared(_ side: CompareSide) {
        let compare = libraryCompare
        if side != compare.activeSide {
            if !compare.isLinked {
                let leaving = (zoom: libraryViews.loupeZoom, focus: compare.focus)
                libraryViews.setLoupeZoom(compare.unlinked.zoom)
                compare.focus = compare.unlinked.focus
                compare.unlinked = leaving
            }
            compare.activeSide = side
        }
        if libraryView == .compare {
            selectCompared()
        }
    }

    /// The lock: the two zoom and pan together, or each on its own. Linked again, the other takes the active one's
    /// zoom and place, as Lightroom Classic's Sync does.
    func toggleCompareLink() {
        let compare = libraryCompare
        compare.isLinked.toggle()
        compare.unlinked = (libraryViews.loupeZoom, compare.focus)
    }

    /// The active photo's place at 1:1, and the other's while linked: a drag.
    func setCompareFocus(_ focus: CGPoint) {
        let compare = libraryCompare
        let kept = CGPoint(x: min(max(focus.x, 0), 1), y: min(max(focus.y, 0), 1))
        if compare.focus != kept {
            compare.focus = kept
        }
    }

    /// `side`'s zoom and place now.
    func compareZoom(of side: CompareSide) -> (zoom: LoupeZoom, focus: CGPoint) {
        let compare = libraryCompare
        guard side != compare.activeSide, !compare.isLinked else { return (libraryViews.loupeZoom, compare.focus) }
        return compare.unlinked
    }

    /// Selects the photos Compare's two cells stand for, the active side's photo active, and makes it the active
    /// photo; only what changes is set.
    private func selectCompared() {
        let compare = libraryCompare
        let (list, order) = (library.photoList, gridOrder)
        let cells = [compare.select, compare.candidate].compactMap { $0.flatMap(library.photoID(of:)) }
        let active = compare.photo(compare.activeSide) ?? compare.select
        var selected = PhotoSelection()
        selected.select(
            cells.flatMap { photos(ofCell: $0, in: order) }, active: active.flatMap(library.photoID(of:)), in: list,
        )
        if selected != photoSelection {
            photoSelection = selected
        }
        if let active, active != selection {
            select(active, keepingSelection: true)
        }
    }

    /// Compare after the selection or the photos changed elsewhere: a photo chosen in the filmstrip takes the active
    /// one's place, a photo that left the source gives its place to the next, and the two are selected again.
    internal func keepCompareInStep() {
        guard libraryView == .compare else { return }
        let compare = libraryCompare
        let order = gridOrder
        let listed = { (url: URL?) -> Bool in url.flatMap(self.library.photoID(of:)) != nil }
        if let active = cellPhoto(of: selection, in: order) {
            if active == compare.select {
                activateCompared(.select)
            } else if active == compare.candidate {
                activateCompared(.candidate)
            } else if compare.activeSide == .candidate, listed(compare.select) {
                compare.candidate = active
            } else {
                compare.select = active
                compare.activeSide = .select
            }
        }
        if !listed(compare.select) {
            compare.select = listed(compare.candidate) ? compare.candidate : cellPhoto(of: selection, in: order)
            compare.candidate = nil
            compare.activeSide = .select
        }
        if !listed(compare.candidate) || compare.candidate == compare.select,
           let id = compare.select.flatMap(library.photoID(of:)) {
            compare.candidate = (order.cell(1, from: id) ?? order.cell(-1, from: id)).flatMap(library.url(ofPhoto:))
        }
        selectCompared()
    }

    // MARK: - Survey

    /// N: the photos selected laid out together, the active one marked.
    @discardableResult
    func showSurvey() -> Bool {
        guard selection != nil else { return false }
        showLibrary(.survey)
        return true
    }

    /// The photos Survey shows: a photo for each of the grid's cells the selection has photos of, the active one's
    /// among them, in the list's order, at most `LibraryCompare.surveyLimit` of them from the active one's place.
    var surveyPhotos: [URL] {
        let order = gridOrder
        let active = selection.flatMap(library.photoID(of:)).map { order.cell(for: $0) ?? $0 }
        var cells: [Int64] = []
        var seen = Set<Int64>()
        let selected = photoSelection.isEmpty ? [] : photoSelection.ids(in: library.photoList)
        for id in selected {
            let cell = order.cell(for: id) ?? id
            if seen.insert(cell).inserted {
                cells.append(cell)
            }
        }
        if let active, !seen.contains(active) {
            cells.insert(active, at: 0)
        }
        let limit = LibraryCompare.surveyLimit
        if cells.count > limit {
            let start = min(active.flatMap(cells.firstIndex(of:)) ?? 0, cells.count - limit)
            cells = Array(cells[start ..< start + limit])
        }
        return cells.compactMap(library.url(ofPhoto:))
    }

    /// The photo Survey marks active: the active photo's cell's.
    var surveyActivePhoto: URL? {
        cellPhoto(of: selection, in: gridOrder)
    }

    /// ← and → in Survey: the photo before or after the active one among those shown becomes active. False at either
    /// end.
    @discardableResult
    func stepSurvey(by offset: Int) -> Bool {
        let photos = surveyPhotos
        guard let active = surveyActivePhoto, let place = photos.firstIndex(of: active),
              photos.indices.contains(place + offset) else { return false }
        activateSurveyed(photos[place + offset])
        return true
    }

    /// A click on a photo Survey shows: it becomes the active photo, the selection staying as it is.
    func activateSurveyed(_ url: URL) {
        guard url != selection else { return }
        if let id = library.photoID(of: url), photoSelection.contains(id) {
            photoSelection.activate(id)
        }
        select(url, keepingSelection: true)
    }

    /// A photo's × in Survey: the photos its cell stands for taken out of the selection, and so out of Survey, which
    /// stays; when the active photo was among them, the photo selected after them becomes active. The last photo
    /// stays.
    @discardableResult
    func removeFromSurvey(_ url: URL) -> Bool {
        let order = gridOrder
        guard surveyPhotos.count > 1, let id = library.photoID(of: url) else { return false }
        let removed = photos(ofCell: order.cell(for: id) ?? id, in: order)
        let list = library.photoList
        var selected = photoSelection
        for photo in removed where selected.contains(photo) {
            selected.toggle(photo, in: list)
        }
        guard !selected.isEmpty, selected != photoSelection else { return false }
        photoSelection = selected
        if let active = selection.flatMap(library.photoID(of:)), removed.contains(active),
           let next = selected.active.flatMap(library.url(ofPhoto:)) {
            select(next, keepingSelection: true)
            selectionAnchor = next
        }
        activity.record(.action, "Remove from Survey")
        return true
    }

    // MARK: - Keys

    /// The keys Compare and Survey give their own meaning: ← and → (the candidate, or the active photo among those
    /// shown), Z and Space in Compare, and the culling keys, which reach the active photo alone. Nil for every other
    /// action, and outside Compare and Survey.
    internal func performCompareShortcut(_ action: ShortcutAction, shifted: Bool) -> Bool? {
        guard showsCompareOrSurvey, !showsMissingPhotos else { return nil }
        let comparing = libraryView == .compare
        let handled = action == .previousPhoto || action == .nextPhoto || CullingChange(action) != nil
            || (comparing && action == .toggleZoom)
        guard handled else { return nil }
        if comparing {
            keepCompareInStep()
        }
        switch action {
        case .previousPhoto, .nextPhoto:
            let offset = action == .nextPhoto ? 1 : -1
            if comparing {
                stepCandidate(by: offset)
            } else {
                stepSurvey(by: offset)
            }
            return true
        case .toggleZoom:
            guard selection != nil else { return false }
            toggleLoupeZoom()
            return true
        default:
            guard let change = CullingChange(action) else { return nil }
            return cullCompared(change, advance: shifted || autoAdvance)
        }
    }

    /// Whether `performCompareShortcut` would do something now; nil for the actions it leaves alone.
    internal func canPerformCompareShortcut(_ action: ShortcutAction) -> Bool? {
        guard showsCompareOrSurvey, !showsMissingPhotos else { return nil }
        let comparing = libraryView == .compare
        switch action {
        case .previousPhoto, .nextPhoto:
            let offset = action == .nextPhoto ? 1 : -1
            if comparing {
                let compare = libraryCompare
                let order = gridOrder
                let select = compare.select.flatMap(library.photoID(of:)).flatMap(order.cell(for:))
                guard let from = (compare.candidate ?? compare.select).flatMap(library.photoID(of:)),
                      let next = order.cell(offset, from: from) else { return false }
                return next != select || order.cell(offset, from: next) != nil
            }
            let photos = surveyPhotos
            guard let place = surveyActivePhoto.flatMap(photos.firstIndex(of:)) else { return false }
            return photos.indices.contains(place + offset)
        case .toggleZoom:
            return comparing ? selection != nil : nil
        default:
            guard CullingChange(action) != nil else { return nil }
            return selection.flatMap(library.index(of:)) != nil
        }
    }

    /// A culling key in Compare or Survey: the photos the active photo's cell stands for, as one change with Undo;
    /// `advance` then moves Compare's candidate on, or makes Survey's next photo active.
    private func cullCompared(_ change: CullingChange, advance: Bool) -> Bool {
        let order = gridOrder
        guard let active = selection.flatMap(library.photoID(of:)) else { return false }
        let list = library.photoList
        let rows = photos(ofCell: order.cell(for: active) ?? active, in: order).compactMap(list.index(of:))
        guard !rows.isEmpty else { return false }
        cull(change, rows: rows)
        if advance {
            if libraryView == .compare {
                stepCandidate(by: 1)
            } else {
                stepSurvey(by: 1)
            }
        }
        return true
    }
}
