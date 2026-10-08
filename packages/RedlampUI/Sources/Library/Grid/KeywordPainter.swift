import AppKit
import Observation
import RedlampLibrary

/// The painter (LIB-21), as Lightroom Classic's: a tool of the grid's toolbar and the Keywording panel that puts
/// keywords on each photo clicked or dragged over in the grid, ⌥ held at the press taking them off. It paints the
/// keywords typed in its field, as Keywording's field reads them, or the active keyword set's while the field is
/// empty. A stroke, from the press to the release, is one change of the panels' with Undo, made on every photo it
/// reached (`LibraryGridView+Painter`); the selection stays as it was. Esc, ⌥⌘K or the tool's button puts it away.
@MainActor
@Observable
public final class KeywordPainter {
    public private(set) var isOn = false
    /// The keywords typed in its field.
    public var text = ""
    @ObservationIgnored weak var model: EditorModel?
    /// The stroke under way, from the press to the release.
    @ObservationIgnored private(set) var stroke: Stroke?

    struct Stroke {
        let keywords: [KeywordPath]
        let removing: Bool
        /// The photos reached, in order, by their IDs in the list shown and their URLs.
        var photos: [(list: Int64, url: URL)] = []
        var reached: Set<Int64> = []
    }

    init(model: EditorModel) {
        self.model = model
    }

    /// The keywords a stroke paints: those typed in the field, else the active keyword set's.
    public var keywords: [KeywordPath] {
        guard let panels = model?.libraryPanels else { return [] }
        let typed = text.trimmingCharacters(in: .whitespaces)
        guard typed.isEmpty else {
            return (panels.keywordList ?? KeywordList(counts: [:], definitions: KeywordDefinitions())).entered(typed)
        }
        return panels.activeSet?.keywords.compactMap(\.self) ?? []
    }

    /// Whether it can be taken out now: in Library, with the library open, photos shown that aren't in the Trash.
    public var isAvailable: Bool {
        guard let model else { return false }
        return model.module == .library && !model.isModalDialogOpen && model.library.service?.isReady == true
            && !model.library.showsRecentlyTrashed
    }

    /// Takes the painter out, showing the grid, or puts it away; false when it can't come out.
    @discardableResult
    public func setOn(_ on: Bool) -> Bool {
        guard on != isOn else { return true }
        guard !on || isAvailable else { return false }
        isOn = on
        stroke = nil
        if on, model?.libraryView != .grid {
            model?.showLibrary(.grid)
        }
        return true
    }

    /// A press in the grid while it's out begins a stroke, taking the keywords off with `removing`; false when there
    /// are none to paint.
    func begin(removing: Bool) -> Bool {
        let keywords = keywords
        guard isOn, !keywords.isEmpty else {
            stroke = nil
            return false
        }
        stroke = Stroke(keywords: keywords, removing: removing)
        return true
    }

    /// The stroke reaches a photo, by its ID in the list shown: true the first time.
    func paint(_ list: Int64, url: URL) -> Bool {
        guard stroke?.reached.insert(list).inserted == true else { return false }
        stroke?.photos.append((list, url))
        return true
    }

    /// The press released: the stroke's photos get its keywords, or lose them, as one change.
    func end() {
        guard let stroke, let panels = model?.libraryPanels else { return }
        self.stroke = nil
        guard !stroke.photos.isEmpty else { return }
        Task { await panels.change(stroke.keywords, removing: stroke.removing, on: stroke.photos) }
    }

    /// The pointer over the grid while it's out: a brush, its tip the point it paints.
    static let cursor: NSCursor = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            .applying(.init(paletteColors: [.white]))
        guard let image = NSImage(systemSymbolName: "paintbrush.pointed.fill", accessibilityDescription: "Painter")?
            .withSymbolConfiguration(configuration)
        else { return .crosshair }
        return NSCursor(image: image, hotSpot: CGPoint(x: 1, y: image.size.height - 1))
    }()
}

public extension EditorModel {
    /// Library's painter (LIB-21).
    var keywordPainter: KeywordPainter {
        if let painter = Self.painters.object(forKey: self) {
            return painter
        }
        let painter = KeywordPainter(model: self)
        Self.painters.setObject(painter, forKey: self)
        return painter
    }

    private static let painters = NSMapTable<EditorModel, KeywordPainter>.weakToStrongObjects()
}

extension EditorModel {
    /// The painter's key, ⌥⌘K, and Esc in Library while it's out; nil for every other action.
    func performPainterShortcut(_ action: ShortcutAction) -> Bool? {
        switch action {
        case .keywordPainter: keywordPainter.setOn(!keywordPainter.isOn)
        case .cancel where module == .library && keywordPainter.isOn: keywordPainter.setOn(false)
        default: nil
        }
    }

    func canPerformPainterShortcut(_ action: ShortcutAction) -> Bool? {
        switch action {
        case .keywordPainter: keywordPainter.isOn || keywordPainter.isAvailable
        case .cancel where module == .library && keywordPainter.isOn: true
        default: nil
        }
    }
}
