import AppKit
import RedlampDesign
import RedlampLibrary

/// The Library module's toolbar, under the grid or the loupe, as Lightroom Classic's: the grid and the
/// loupe, the cell style and the thumbnail size in the grid or the zoom in the loupe, and the photo in
/// Develop or in Finder. Each button's tooltip names its key. Its controls act on the press itself, as
/// the module picker does, rather than tracking the mouse as AppKit's controls do. In the grid, Group By
/// (LIB-41) and, grouped by moment, the Tighter–Looser slider and the moments without a pick are AppKit's
/// own controls until the library's polish phase (LIB-45).
final class LibraryToolbarView: NSView {
    static let height: CGFloat = 30

    private let model: EditorModel
    private let grid = ToolbarButton(symbol: "square.grid.2x2", identifier: "library.toolbar.grid")
    private let loupe = ToolbarButton(symbol: "photo", identifier: "library.toolbar.loupe")
    private let styles: [GridCellStyle: ToolbarButton]
    private let size = ToolbarSlider(identifier: "library.toolbar.size")
    private let fit = ToolbarButton(title: LoupeZoom.fit.title, identifier: "library.toolbar.fit")
    private let actual = ToolbarButton(title: LoupeZoom.actual.title, identifier: "library.toolbar.actual")
    private let develop = ToolbarButton(symbol: "slider.horizontal.3", identifier: "library.toolbar.develop")
    private let finder = ToolbarButton(symbol: "folder", identifier: "library.toolbar.finder")
    private let groupBy = NSPopUpButton(frame: .zero, pullsDown: false)
    private let looseness = NSSlider(
        value: 0, minValue: Double(MomentSetting.tightest), maxValue: Double(MomentSetting.loosest), target: nil,
        action: nil,
    )
    private let tighter = NSTextField(labelWithString: "Tighter")
    private let looser = NSTextField(labelWithString: "Looser")
    private let unpicked = NSButton(title: "", target: nil, action: nil)
    /// The moments-without-a-pick button's width, measured as its title changes, in steps of 40 points, so a
    /// count that changes as photos are picked doesn't lay the window out again.
    private var unpickedWidth: CGFloat = 120
    /// What the toolbar was last laid out for: the grid or the loupe, and which of Group By's controls show.
    private var laidOut: [CGFloat]?
    private var trackers: [Tracker] = []

    init(model: EditorModel) {
        self.model = model
        var styles: [GridCellStyle: ToolbarButton] = [:]
        let symbols: [GridCellStyle: String] = [
            .compact: "square.grid.3x3.square", .expanded: "rectangle.grid.1x2", .none: "square.grid.3x3",
        ]
        for style in GridCellStyle.allCases {
            styles[style] = ToolbarButton(symbol: symbols[style] ?? "square", identifier: "library.toolbar.\(style)")
        }
        self.styles = styles
        super.init(frame: CGRect(x: 0, y: 0, width: 800, height: Self.height))
        grid.toolTip = Self.tip(.gridView)
        loupe.toolTip = Self.tip(.loupeView)
        develop.toolTip = "Open in Develop (\(ShortcutAction.editTool.combos.first?.display ?? ""))"
        finder.toolTip = Self.tip(.showInFinder)
        fit.toolTip = "Fit (\(ShortcutAction.toggleZoom.combos.first?.display ?? "") or a click)"
        actual.toolTip = "1:1 (\(ShortcutAction.toggleZoom.combos.first?.display ?? "") or a click)"
        size.toolTip = "Thumbnail Size (\(ShortcutAction.smallerThumbnails.combos.first?.display ?? "") and "
            + "\(ShortcutAction.largerThumbnails.combos.first?.display ?? ""))"
        grid.onPress = { model.perform(.gridView) }
        loupe.onPress = { model.perform(.loupeView) }
        develop.onPress = { model.perform(.editTool) }
        finder.onPress = { model.perform(.showInFinder) }
        fit.onPress = { model.setLoupeZoom(.fit) }
        actual.onPress = { model.setLoupeZoom(.actual) }
        for (style, button) in styles {
            button.toolTip = "\(style.title) (\(ShortcutAction.cycleGridStyle.combos.first?.display ?? "") cycles)"
            button.onPress = { model.setCellStyle(style) }
        }
        size.range = GridSize.range
        size.onChange = { model.setThumbnailSize($0) }
        for view in [grid, loupe, fit, actual, develop, finder, size] + GridCellStyle.allCases
            .compactMap({ styles[$0] })
            as [NSView] {
            addSubview(view)
        }
        setUpGroups()
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Library Toolbar")
        setAccessibilityIdentifier("library.toolbar")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private static func tip(_ action: ShortcutAction) -> String {
        "\(action.title) (\(action.combos.first?.display ?? ""))"
    }

    private func setUpGroups() {
        let model = model
        groupBy.controlSize = .small
        groupBy.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        for key in GroupKey.allCases {
            groupBy.addItem(withTitle: key.title)
            groupBy.lastItem?.representedObject = key.rawValue
        }
        groupBy.toolTip = "Group By"
        groupBy.setAccessibilityLabel("Group By")
        groupBy.setAccessibilityIdentifier("library.toolbar.groupBy")
        groupBy.onAction { [weak self] _ in
            guard let self, let raw = groupBy.selectedItem?.representedObject as? String,
                  let key = GroupKey(rawValue: raw) else { return }
            model.setGroupKey(key)
        }
        looseness.controlSize = .small
        looseness.numberOfTickMarks = MomentSetting.loosest - MomentSetting.tightest + 1
        looseness.allowsTickMarkValuesOnly = true
        looseness.isContinuous = true
        looseness.toolTip = "Moments: tighter splits at shorter pauses, looser only at longer ones"
        looseness.setAccessibilityLabel("Tighter or Looser Moments")
        looseness.setAccessibilityIdentifier("library.toolbar.looseness")
        looseness.onAction { [weak self] _ in
            guard let self else { return }
            let value = Int(looseness.doubleValue.rounded())
            if value != model.libraryViews.looseness {
                model.setLooseness(value)
            }
        }
        for label in [tighter, looser] {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
        }
        unpicked.controlSize = .small
        unpicked.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        unpicked.setButtonType(.pushOnPushOff)
        unpicked.bezelStyle = .push
        unpicked.toolTip = ShortcutAction.unpickedMoments.title
        unpicked.setAccessibilityIdentifier("library.toolbar.unpicked")
        unpicked.onAction { _ in model.perform(.unpickedMoments) }
        for view in [groupBy, looseness, tighter, looser, unpicked] as [NSView] {
            addSubview(view)
        }
    }

    /// Group By's controls as the grid's view and its groups have them now.
    private func updateGroups(inGrid: Bool) {
        let state = model.libraryViews
        let groups = model.gridGroups
        let index = GroupKey.allCases.firstIndex(of: state.groupKey) ?? 0
        if groupBy.indexOfSelectedItem != index {
            groupBy.selectItem(at: index)
        }
        groupBy.isHidden = !inGrid
        groupBy.isEnabled = model.canGroupPhotos || state.groupKey != .ungrouped
        let moments = inGrid && state.groupKey.usesMoments
        for view in [looseness, tighter, looser] as [NSView] {
            view.isHidden = !moments
        }
        if Int(looseness.doubleValue.rounded()) != state.looseness {
            looseness.doubleValue = Double(state.looseness)
        }
        let coverage = groups.coverage
        unpicked.isHidden = !moments || coverage == nil
        if let coverage {
            let title = "\(coverage.unpicked.formatted()) of \(coverage.moments.formatted()) "
                + "\(coverage.moments == 1 ? "moment" : "moments") without a pick"
            if unpicked.title != title {
                unpicked.title = title
                unpicked.setAccessibilityLabel(title)
                let font = unpicked.font ?? .systemFont(ofSize: NSFont.smallSystemFontSize)
                let width = (title as NSString).size(withAttributes: [.font: font]).width + 24
                unpickedWidth = max((width / 40).rounded(.up) * 40, 120)
            }
        }
        unpicked.state = groups.showsUnpicked ? .on : .off
    }

    override var isFlipped: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        trackers.forEach { $0.cancel() }
        trackers = []
        guard window != nil else { return }
        trackers = [Tracker { [weak self] in
            guard let self else { return }
            let state = model.libraryViews
            let inGrid = model.libraryView == .grid
            grid.isOn = inGrid
            loupe.isOn = !inGrid
            for (style, button) in styles {
                button.isOn = state.cellStyle == style
                button.isHidden = !inGrid
            }
            size.isHidden = !inGrid
            size.value = state.thumbnailSize
            fit.isOn = state.loupeZoom == .fit
            actual.isOn = state.loupeZoom == .actual
            fit.isHidden = inGrid
            actual.isHidden = inGrid
            let hasPhoto = model.selection != nil
            develop.isEnabled = hasPhoto
            finder.isEnabled = hasPhoto
            loupe.isEnabled = hasPhoto
            updateGroups(inGrid: inGrid)
            let layout: [CGFloat] = [inGrid ? 1 : 0, looseness.isHidden ? 0 : 1, unpicked.isHidden ? 0 : unpickedWidth]
            if layout != laidOut {
                laidOut = layout
                needsLayout = true
            }
        }]
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 12
        func place(_ view: NSView, width: CGFloat) {
            view.frame = CGRect(x: x, y: (bounds.height - 22) / 2, width: width, height: 22)
            x += width + 2
        }
        place(grid, width: 28)
        place(loupe, width: 28)
        x += 14
        if model.libraryView == .grid {
            for style in GridCellStyle.allCases {
                if let button = styles[style] {
                    place(button, width: 28)
                }
            }
            x += 14
            place(groupBy, width: 150)
            if !looseness.isHidden {
                x += 8
                for (view, width) in [(tighter, 44), (looseness, 96), (looser, 40)] as [(NSView, CGFloat)] {
                    place(view, width: width)
                    x += 2
                }
            }
            if !unpicked.isHidden {
                x += 8
                place(unpicked, width: unpickedWidth)
            }
        } else {
            place(fit, width: 40)
            place(actual, width: 40)
        }
        let right = bounds.width - 12
        finder.frame = CGRect(x: right - 28, y: (bounds.height - 22) / 2, width: 28, height: 22)
        develop.frame = CGRect(x: right - 58, y: (bounds.height - 22) / 2, width: 28, height: 22)
        let sliderWidth = min(160, max(develop.frame.minX - x - 24, 60))
        size.frame = CGRect(
            x: develop.frame.minX - 16 - sliderWidth,
            y: (bounds.height - 22) / 2,
            width: sliderWidth,
            height: 22,
        )
    }
}

/// A toolbar button: a symbol or a title, lit while it's on, acting as it's pressed.
final class ToolbarButton: NSView {
    var onPress: (() -> Void)?
    var isOn = false {
        didSet {
            if isOn != oldValue {
                update()
            }
        }
    }

    var isEnabled = true {
        didSet {
            if isEnabled != oldValue {
                update()
            }
        }
    }

    private let image = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init(symbol: String? = nil, title: String? = nil, identifier: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        if let symbol {
            image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            addSubview(image)
        }
        if let title {
            label.stringValue = title
            label.font = Typography.caption.nsFont
            label.alignment = .center
            addSubview(label)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier(identifier)
        update()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var toolTip: String? {
        didSet { setAccessibilityLabel(toolTip) }
    }

    private func update() {
        let color = (isEnabled ? (isOn ? Palette.label : Palette.secondaryLabel) : Palette.tertiaryLabel).nsColor
        image.contentTintColor = color
        label.textColor = color
        layer?.backgroundColor = isOn ? NSColor(white: 1, alpha: 0.12).cgColor : nil
        setAccessibilityValue(isOn ? "on" : nil)
        setAccessibilityEnabled(isEnabled)
    }

    override func layout() {
        super.layout()
        image.frame = bounds.insetBy(dx: 4, dy: 3)
        let height = label.intrinsicContentSize.height
        label.frame = CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with _: NSEvent) {
        if isEnabled {
            onPress?()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onPress?()
        return true
    }
}

/// The thumbnail size's slider: a track and a knob, following the pointer from the press to the release.
final class ToolbarSlider: NSView {
    var onChange: ((Double) -> Void)?
    var range: ClosedRange<Double> = 0 ... 1
    var value: Double = 0 {
        didSet {
            if value != oldValue {
                needsLayout = true
                setAccessibilityValue(Int(value.rounded()))
            }
        }
    }

    private let track = CALayer()
    private let knob = CALayer()

    init(identifier: String) {
        super.init(frame: .zero)
        wantsLayer = true
        track.backgroundColor = NSColor(white: 1, alpha: 0.25).cgColor
        track.cornerRadius = 1.5
        knob.backgroundColor = NSColor(white: 0.85, alpha: 1).cgColor
        knob.cornerRadius = 6
        for layer in [track, knob] {
            layer.actions = LibraryGridCell.noActions
            self.layer?.addSublayer(layer)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Thumbnail Size")
        setAccessibilityIdentifier(identifier)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool {
        true
    }

    private var span: (left: CGFloat, width: CGFloat) {
        (6, max(bounds.width - 12, 1))
    }

    override func layout() {
        super.layout()
        let (left, width) = span
        let fraction = (value - range.lowerBound) / max(range.upperBound - range.lowerBound, 1)
        track.frame = CGRect(x: left, y: bounds.midY - 1.5, width: width, height: 3)
        knob.frame = CGRect(x: left + width * fraction - 6, y: bounds.midY - 6, width: 12, height: 12)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        follow(event)
    }

    override func mouseDragged(with event: NSEvent) {
        follow(event)
    }

    private func follow(_ event: NSEvent) {
        let (left, width) = span
        let x = convert(event.locationInWindow, from: nil).x
        let fraction = min(max((x - left) / width, 0), 1)
        onChange?(range.lowerBound + (range.upperBound - range.lowerBound) * fraction)
    }

    override func accessibilityPerformIncrement() -> Bool {
        onChange?(GridSize.larger(than: value))
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        onChange?(GridSize.smaller(than: value))
        return true
    }
}
