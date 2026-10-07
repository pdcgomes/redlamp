import AppKit
import RedlampDesign
import SwiftUI

/// The Library module's middle: the grid or the loupe between the panels, the Library toolbar under them,
/// and the filmstrip docked beneath, the same filmstrip Develop floats, with the same photos, selection and
/// place. Built once with the window and kept; G, E, C and N show the grid or the loupe. While Develop is
/// shown it's transparent and its parts follow nothing (`isInShownModule`).
final class LibraryModuleView: NSView {
    let grid: LibraryGridView
    let loupe: LibraryLoupeView
    let toolbar: LibraryToolbarView
    /// The filter bar above the grid (LIB-18), shown by `\`.
    let filterBar: LibraryFilterBarView
    private let filmstrip: NSHostingView<LibraryFilmstrip>
    private let model: EditorModel
    private var trackers: [Tracker] = []
    private var withFilmstrip: [NSLayoutConstraint] = []
    private var withoutFilmstrip: [NSLayoutConstraint] = []
    private var filterHeight: NSLayoutConstraint?
    private var showsFilterBar = false
    /// The Library module is the one shown (`ModuleContentController`).
    private(set) var isShownModule = false
    private(set) var showsFilmstrip = true

    private static let filmstripHeight: CGFloat = 110

    init(model: EditorModel, theme: ThemeSettings) {
        self.model = model
        grid = LibraryGridView(model: model)
        loupe = LibraryLoupeView(model: model)
        toolbar = LibraryToolbarView(model: model)
        filterBar = LibraryFilterBarView(model: model)
        filmstrip = NSHostingView(rootView: LibraryFilmstrip(model: model, theme: theme))
        filmstrip.sizingOptions = []
        super.init(frame: CGRect(x: 0, y: 0, width: 1600, height: 1000))
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        let stage = safeAreaLayoutGuide
        let inset = PanelMetrics.inset
        for view in [grid, loupe, toolbar, filmstrip, filterBar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        addSubview(filterBar.completions)
        filterBar.isHidden = true
        let filterHeight = filterBar.heightAnchor.constraint(equalToConstant: 0)
        self.filterHeight = filterHeight
        var constraints = [
            filmstrip.leadingAnchor.constraint(equalTo: stage.leadingAnchor, constant: inset),
            filmstrip.trailingAnchor.constraint(equalTo: stage.trailingAnchor, constant: -inset),
            filmstrip.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            filmstrip.heightAnchor.constraint(equalToConstant: Self.filmstripHeight),
            toolbar.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: LibraryToolbarView.height),
            filterBar.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            filterBar.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            filterBar.topAnchor.constraint(equalTo: stage.topAnchor),
            filterHeight,
        ]
        for view in [grid, loupe] as [NSView] {
            constraints += [
                view.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
                view.topAnchor.constraint(equalTo: view === grid ? filterBar.bottomAnchor : stage.topAnchor),
                view.bottomAnchor.constraint(equalTo: toolbar.topAnchor),
            ]
        }
        withFilmstrip.append(toolbar.bottomAnchor.constraint(equalTo: filmstrip.topAnchor, constant: -inset / 2))
        withoutFilmstrip.append(toolbar.bottomAnchor.constraint(equalTo: bottomAnchor))
        NSLayoutConstraint.activate(constraints + withFilmstrip)
        updateParts()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        trackers.forEach { $0.cancel() }
        trackers = []
        guard window != nil else { return }
        trackers = [
            Tracker { [weak self] in
                guard let self else { return }
                _ = model.libraryView
                updateParts()
                if isShownModule {
                    takeFocus()
                }
            },
            Tracker { [weak self] in
                guard let self else { return }
                // A filter that finds nothing keeps the strip: the grid keeps its height as keys are typed.
                let library = model.library
                showFilmstrip(model.filmstripVisible && model.lightsOut == 0
                    && (library.count > 0 || library.isFiltered || library.isOpenFolderUnavailable))
            },
            Tracker { [weak self] in
                guard let self, let filters = model.libraryFilters else { return }
                _ = filters.filter.sections
                showFilterBar(filters.isBarShown && model.libraryView == .grid)
            },
        ]
    }

    /// The filter bar shown above the grid, as tall as its sections, its text taking the keyboard as
    /// it's shown; hidden, the grid takes it back.
    private func showFilterBar(_ shown: Bool) {
        let height = shown ? filterBar.intrinsicContentSize.height : 0
        if filterHeight?.constant != height {
            filterHeight?.constant = height
        }
        if filterBar.isHidden == shown {
            filterBar.isHidden = !shown
        }
        let completionsHidden = !shown || filterBar.completions.items.isEmpty
        if filterBar.completions.isHidden != completionsHidden {
            filterBar.completions.isHidden = completionsHidden
        }
        defer { showsFilterBar = shown }
        guard shown != showsFilterBar, isShownModule else { return }
        if shown {
            layoutSubtreeIfNeeded()
            filterBar.focusText()
        } else if let editor = window?.firstResponder as? NSTextView, editor.delegate === filterBar.field {
            takeFocus()
        }
    }

    func setShown(_ shown: Bool) {
        isShownModule = shown
        if !shown, let editor = window?.firstResponder as? NSTextView, editor.delegate === filterBar.field {
            window?.makeFirstResponder(nil)
        }
    }

    private func updateParts() {
        let view = model.libraryView
        for (part, visible) in [(grid, view == .grid), (loupe, view == .loupe), (filmstrip, showsFilmstrip)] as
            [(NSView, Bool)] where part.isHidden == visible {
            part.isHidden = !visible
        }
    }

    private func showFilmstrip(_ shown: Bool) {
        guard showsFilmstrip != shown else { return }
        showsFilmstrip = shown
        NSLayoutConstraint.deactivate(shown ? withoutFilmstrip : withFilmstrip)
        NSLayoutConstraint.activate(shown ? withFilmstrip : withoutFilmstrip)
        updateParts()
    }

    /// Over Develop's canvas, the Library's own cursor, not the canvas's.
    override func resetCursorRects() {
        if isShownModule {
            addCursorRect(visibleRect, cursor: .arrow)
        }
    }

    /// Takes the keyboard as the module is shown: the grid's, or the window's in the loupe, where the
    /// arrow keys go to the previous and next photo.
    func takeFocus() {
        if model.libraryView == .grid {
            grid.takeFocus()
        } else {
            window?.makeFirstResponder(self)
        }
    }

    override var acceptsFirstResponder: Bool {
        true
    }
}

/// The filmstrip in the Library module, in the pane the floating one has.
private struct LibraryFilmstrip: View {
    let model: EditorModel
    let theme: ThemeSettings

    var body: some View {
        FilmstripView()
            .modifier(FloatingPane(opacity: theme.panelOpacity))
            .id(theme.selection)
            .environment(model)
            .environment(theme)
            .tint(Theme.nativeTint)
            .focusEffectDisabled()
    }
}

extension NSView {
    /// Whether the view is on screen in the module shown: not hidden, and not in the other module's view,
    /// which a switch leaves in place, transparent. A view in neither module is on screen when it isn't hidden.
    @MainActor func isInShownModule(_ model: EditorModel) -> Bool {
        guard window != nil, !isHiddenOrHasHiddenAncestor else { return false }
        var view: NSView? = self
        while let current = view {
            if current is LibraryModuleView {
                return model.module == .library
            }
            if current is ModuleContainerView {
                return model.module == .develop
            }
            view = current.superview
        }
        return true
    }
}
