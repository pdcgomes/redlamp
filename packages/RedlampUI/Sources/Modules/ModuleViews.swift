import AppKit
import RedlampDesign
import SwiftUI

/// The window's middle, under the toolbar and between the panels: each module's view, built once with the
/// window and kept. A switch hides one and shows the other, so nothing is built, loaded or read on the way,
/// and the keyboard follows: the Library module takes it, and Develop gives it back to the window.
final class ModuleContentController: NSViewController {
    private let model: EditorModel
    private let develop: NSViewController
    let library: LibraryModuleView
    private var tracker: Tracker?
    private var shown: AppModule?

    init(model: EditorModel, theme: ThemeSettings, develop: NSViewController) {
        self.model = model
        self.develop = develop
        library = LibraryModuleView(model: model, theme: theme)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Develop's view.
    var developView: NSView {
        develop.view
    }

    override func loadView() {
        let view = ModuleContainerView(frame: CGRect(x: 0, y: 0, width: 1600, height: 1000))
        addChild(develop)
        for content in [develop.view, library] {
            content.frame = view.bounds
            content.autoresizingMask = [.width, .height]
            view.addSubview(content)
        }
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tracker = Tracker { [weak self] in
            guard let self else { return }
            show(model.module)
        }
    }

    private func show(_ module: AppModule) {
        guard module != shown else { return }
        let first = shown == nil
        shown = module
        // Hiding the view with the keyboard hands it to the window, so where it was is read first.
        let focusedInLibrary = (view.window?.firstResponder as? NSView)?.isDescendant(of: library) == true
        developView.isHidden = module != .develop
        library.isHidden = module != .library
        guard !first, let window = view.window else { return }
        if module == .library {
            library.takeFocus()
        } else if focusedInLibrary || window.firstResponder === window {
            window.makeFirstResponder(view)
        }
    }
}

/// The middle's own first responder in Develop: it takes keys without drawing anything, as the window's
/// root does, so they reach the shortcut monitor and the menus.
private final class ModuleContainerView: NSView {
    override var acceptsFirstResponder: Bool {
        true
    }
}

/// A side panel's column for each module, both built with the window and kept: the shown module's is
/// visible.
final class ModuleColumnView: NSView {
    private let model: EditorModel
    let develop: NSView
    let library: NSView
    private var tracker: Tracker?

    init(model: EditorModel, develop: NSView, library: NSView) {
        self.model = model
        self.develop = develop
        self.library = library
        super.init(frame: .zero)
        addSubview(develop)
        addSubview(library)
        develop.isHidden = model.module != .develop
        library.isHidden = model.module != .library
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tracker?.cancel()
        tracker = nil
        guard window != nil else { return }
        tracker = Tracker { [weak self] in
            guard let self else { return }
            let module = model.module
            develop.isHidden = module != .develop
            library.isHidden = module != .library
        }
    }

    override func layout() {
        super.layout()
        develop.frame = bounds
        library.frame = bounds
    }
}

@_spi(Harness) public enum ModuleViews {
    /// The editor window's content as the app builds it, both modules and their panels, for measurements.
    @MainActor public static func make(model: EditorModel, theme: ThemeSettings) -> NSViewController {
        let develop = NSHostingController(rootView: EditorContentView(model: model, theme: theme, onOpen: {}))
        develop.sizingOptions = []
        let content = ModuleContentController(model: model, theme: theme, develop: develop)
        return EditorSplitViewController(model: model, theme: theme, content: content)
    }
}
