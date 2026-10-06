import AppKit
import RedlampDesign
import SwiftUI

/// The Library module's middle: the grid or the loupe between the panels, and the filmstrip docked beneath
/// them, the same filmstrip Develop floats, with the same photos, selection and place. Built once with the
/// window and kept; G, E, C and N show the grid or the loupe.
final class LibraryModuleView: NSView {
    let grid: LibraryGridView
    let loupe: LibraryLoupeView
    private let filmstrip: NSHostingView<LibraryFilmstrip>
    private let model: EditorModel
    private var trackers: [Tracker] = []
    private var withFilmstrip: [NSLayoutConstraint] = []
    private var withoutFilmstrip: [NSLayoutConstraint] = []

    private static let filmstripHeight: CGFloat = 110

    init(model: EditorModel, theme: ThemeSettings) {
        self.model = model
        grid = LibraryGridView(model: model)
        loupe = LibraryLoupeView(model: model)
        filmstrip = NSHostingView(rootView: LibraryFilmstrip(model: model, theme: theme))
        filmstrip.sizingOptions = []
        super.init(frame: CGRect(x: 0, y: 0, width: 1600, height: 1000))
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        let stage = safeAreaLayoutGuide
        let inset = PanelMetrics.inset
        for view in [grid, loupe, filmstrip] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        var constraints = [
            filmstrip.leadingAnchor.constraint(equalTo: stage.leadingAnchor, constant: inset),
            filmstrip.trailingAnchor.constraint(equalTo: stage.trailingAnchor, constant: -inset),
            filmstrip.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            filmstrip.heightAnchor.constraint(equalToConstant: Self.filmstripHeight),
        ]
        for view in [grid, loupe] as [NSView] {
            constraints += [
                view.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
                view.topAnchor.constraint(equalTo: stage.topAnchor),
            ]
            withFilmstrip.append(view.bottomAnchor.constraint(equalTo: filmstrip.topAnchor, constant: -inset))
            withoutFilmstrip.append(view.bottomAnchor.constraint(equalTo: bottomAnchor))
        }
        NSLayoutConstraint.activate(constraints + withFilmstrip)
        grid.isHidden = model.libraryView != .grid
        loupe.isHidden = model.libraryView != .loupe
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
                show(model.libraryView)
            },
            Tracker { [weak self] in
                guard let self else { return }
                showFilmstrip(model.filmstripVisible && model.lightsOut == 0
                    && (model.library.count > 0 || model.library.isOpenFolderUnavailable))
            },
        ]
    }

    private func show(_ view: LibraryView) {
        guard grid.isHidden != (view != .grid) else { return }
        grid.isHidden = view != .grid
        loupe.isHidden = view != .loupe
        if !isHiddenOrHasHiddenAncestor {
            takeFocus()
        }
    }

    private func showFilmstrip(_ shown: Bool) {
        guard filmstrip.isHidden == shown else { return }
        filmstrip.isHidden = !shown
        NSLayoutConstraint.deactivate(shown ? withoutFilmstrip : withFilmstrip)
        NSLayoutConstraint.activate(shown ? withFilmstrip : withoutFilmstrip)
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
