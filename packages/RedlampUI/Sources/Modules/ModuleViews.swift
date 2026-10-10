import AppKit
import RedlampDesign
import SwiftUI

/// The window's middle, under the toolbar and between the panels: each module's view, built once with the
/// window and kept, so a switch builds, loads and reads nothing. The Library module lies over Develop's
/// canvas, opaque, and a switch changes only its opacity: hiding and showing a view makes AppKit lay it out
/// and draw it again, more than a switch has. Clicks, scrolls and VoiceOver reach only the module shown,
/// the Library keeps its own cursor over the canvas, and the keyboard follows: the Library module takes
/// it, and Develop gives it back to the window.
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
        (view as? ModuleContainerView)?.shown = module == .library ? library : developView
        library.alphaValue = module == .library ? 1 : 0
        library.setShown(module == .library)
        guard !first, let window = view.window else { return }
        window.invalidateCursorRects(for: library)
        if module == .library {
            library.takeFocus()
        } else if (window.firstResponder as? NSView)?.isDescendant(of: library) == true
            || window.firstResponder === window {
            window.makeFirstResponder(view)
        }
    }
}

/// The middle: it takes keys in Develop without drawing anything, as the window's root does, so they reach
/// the shortcut monitor and the menus; and it hands clicks and VoiceOver to the module shown.
final class ModuleContainerView: NSView {
    weak var shown: NSView?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard frame.contains(point), let shown else { return super.hitTest(point) }
        return shown.hitTest(convert(point, from: superview)) ?? self
    }

    override func accessibilityChildren() -> [Any]? {
        shown.map { [$0] } ?? super.accessibilityChildren()
    }
}

/// A side panel's column for each module, both built with the window and kept: the shown module's is
/// visible. They're switched by opacity rather than hidden, since hiding and showing a column of panels
/// lays it out and draws it again, more than a switch has; clicks, scrolls and VoiceOver reach only the
/// shown column.
final class ModuleColumnView: NSView {
    private let model: EditorModel
    let develop: NSView
    let library: NSView
    private var tracker: Tracker?
    private(set) var shown: AppModule

    init(model: EditorModel, develop: NSView, library: NSView) {
        self.model = model
        self.develop = develop
        self.library = library
        shown = model.module
        super.init(frame: .zero)
        addSubview(develop)
        addSubview(library)
        show(model.module)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool {
        true
    }

    private var shownColumn: NSView {
        shown == .develop ? develop : library
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tracker?.cancel()
        tracker = nil
        guard window != nil else { return }
        tracker = Tracker { [weak self] in
            guard let self else { return }
            show(model.module)
        }
    }

    private func show(_ module: AppModule) {
        let leaving = shown == module ? nil : shownColumn
        shown = module
        develop.alphaValue = module == .develop ? 1 : 0
        library.alphaValue = module == .library ? 1 : 0
        if let leaving, let window, let responder = window.firstResponder as? NSView,
           responder.isDescendant(of: leaving) {
            window.makeFirstResponder(nil)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard frame.contains(point) else { return nil }
        return shownColumn.hitTest(convert(point, from: superview)) ?? self
    }

    override func accessibilityChildren() -> [Any]? {
        [shownColumn]
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
        let develop = NSHostingController(rootView: EditorContentView(model: model, theme: theme, onOpen: {})
            .focusEffectDisabled())
        develop.sizingOptions = []
        let content = ModuleContentController(model: model, theme: theme, develop: develop)
        return EditorSplitViewController(model: model, theme: theme, content: content)
    }
}
