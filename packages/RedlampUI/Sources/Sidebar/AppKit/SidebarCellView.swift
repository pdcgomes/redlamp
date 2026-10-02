import AppKit
import RedlampDesign
import RedlampDocument
import RedlampRecipes

/// One row of a sidebar list. Its chevron, icon and title line up with the panel header's
/// chevron, glyph and title, so the lists read as the inspector's panels do.
final class SidebarCellView: NSTableCellView {
    /// Positions from where the row starts (the panel's padding, then a level further in for
    /// each level down), taken from the panel header's layout.
    @MainActor enum Layout {
        /// The Develop panels' control rows, with their labels' font and their glyphs' size.
        static let rowHeight = Metrics.controlRowMinHeight
        static let rowFont = Typography.label.nsFont
        static let iconPointSize: CGFloat = 11
        static let indent: CGFloat = 13
        static let chevronSize = Symbol.layoutSize("chevron.right", pointSize: 9, weight: .bold)
        static let iconCenter = chevronSize.width + 8 + Metrics.panelSymbolSlot / 2
        static let titleInset = chevronSize.width + 8 + Metrics.panelSymbolSlot + 6
        /// A label's text sits this far into its frame.
        static let labelPadding: CGFloat = 2
        /// When even its value after doesn't fit beside it, a history step's title keeps this
        /// share of the row (at least `minimumTitle`) and both truncate.
        static let titleShare: CGFloat = 0.6
        static let minimumTitle: CGFloat = 56
        static let valuesGap: CGFloat = 8
    }

    private let node: SidebarNode
    private let model: EditorModel
    private let label = NSTextField(labelWithString: "")
    private var chevron: ChevronView?
    private var icon: SymbolImageView?
    private var trailing: NSView?
    private var values: HistoryValuesView?
    private var amountSlider: NSSlider?
    private var hoverArea: NSTrackingArea?

    /// A group's or earlier session's chevron points down while its rows show.
    var isExpanded: Bool {
        didSet { chevron?.isExpanded = isExpanded }
    }

    init(node: SidebarNode, model: EditorModel, isExpanded: Bool = false) {
        self.node = node
        self.model = model
        self.isExpanded = isExpanded
        super.init(frame: .zero)
        label.lineBreakMode = .byTruncatingTail
        label.font = Layout.rowFont
        addSubview(label)
        var symbol: String?
        switch node.kind {
        case let .group(name):
            label.stringValue = name
            label.textColor = Palette.secondaryLabel.nsColor
            showChevron()
            symbol = "folder"
        case let .recipe(recipe):
            label.stringValue = recipe.name
            label.textColor = Palette.label.nsColor
            toolTip = [recipe.summary, "Hover to preview, click to apply"].compactMap(\.self).joined(separator: "\n")
            if model.recipes.isFavorite(recipe) {
                trailing = SymbolImageView("star.fill", pointSize: 9, color: Palette.secondaryLabel.nsColor)
            } else if recipe.usesLookTable {
                trailing = SymbolImageView("cube", pointSize: 9, color: Palette.tertiaryLabel.nsColor)
            }
        case let .recipeAmount(title, amount):
            label.stringValue = "Amount  \(Int(amount.rounded()))"
            label.font = .systemFont(ofSize: 11)
            label.textColor = Palette.secondaryLabel.nsColor
            toolTip = "Strength of “\(title)”. 0 leaves the photo as it was; 200 goes twice as far."
            let slider = NSSlider(value: amount, minValue: 0, maxValue: 200, target: nil, action: nil)
            slider.controlSize = .small
            slider.isContinuous = true
            slider.setAccessibilityLabel("Recipe Amount")
            let model = model
            let label = label
            slider.onAction { slider in
                if model.editStart == nil {
                    model.beginEdit()
                }
                model.setRecipeAmount(slider.doubleValue)
                label.stringValue = "Amount  \(Int(slider.doubleValue.rounded()))"
                if NSApp.currentEvent?.type == .leftMouseUp {
                    model.endEdit(.recipe, "Recipe Amount", value: EditorModel.recipeAmountText)
                }
            }
            amountSlider = slider
            addSubview(slider)
        case let .placeholder(text):
            label.stringValue = text
            label.textColor = Palette.tertiaryLabel.nsColor
        case let .snapshot(snapshot):
            label.stringValue = snapshot.name
            symbol = "camera.viewfinder"
        case .history, .session, .earlierStep:
            showHistory(node.kind)
        }
        if let symbol {
            showIcon(symbol)
        }
        if let trailing {
            addSubview(trailing)
        }
        if let values {
            addSubview(values)
        }
        needsLayout = true
    }

    private func showChevron() {
        let view = ChevronView()
        view.isExpanded = isExpanded
        addSubview(view)
        chevron = view
    }

    private func showIcon(_ symbol: String, color: RGBA = Palette.secondaryLabel) {
        let image = SymbolImageView(symbol, pointSize: Layout.iconPointSize, color: color.nsColor)
        addSubview(image)
        icon = image
    }

    override var isFlipped: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    /// Laid out by hand on the pixel grid, as SwiftUI rounds (a leftover half point goes
    /// down), rather than by Auto Layout, which rounds it up.
    override func layout() {
        super.layout()
        let scale = backingScale
        func centeredY(_ size: CGSize) -> CGFloat {
            PixelGrid.round((bounds.height - size.height) / 2, scale: scale)
        }
        var titleX = Layout.titleInset
        if let amountSlider {
            let width = min(max(bounds.width * 0.55, 80), 160)
            amountSlider.frame = CGRect(
                x: bounds.width - width - 2, y: centeredY(CGSize(width: width, height: 16)), width: width, height: 16,
            )
        }
        if let chevron {
            let size = Layout.chevronSize
            chevron.frame = CGRect(x: 0, y: centeredY(size), width: size.width, height: size.height)
        }
        if let image = icon {
            let size = image.intrinsicContentSize
            image.frame = CGRect(
                x: PixelGrid.round(Layout.iconCenter - size.width / 2, scale: scale), y: centeredY(size),
                width: size.width, height: size.height,
            )
        }
        var titleMaxX = amountSlider.map { $0.frame.minX - 4 } ?? bounds.width
        if let trailing {
            let size = trailing.intrinsicContentSize
            trailing.frame = CGRect(
                x: PixelGrid.round(bounds.width - size.width, scale: scale), y: centeredY(size),
                width: size.width, height: size.height,
            )
            titleMaxX = trailing.frame.minX - 6
        }
        let size = label.intrinsicContentSize
        if let values {
            titleMaxX = place(values, from: titleX, to: titleMaxX, title: size.width)
        }
        titleX -= Layout.labelPadding
        label.frame = CGRect(x: titleX, y: centeredY(size), width: max(titleMaxX - titleX, 0), height: size.height)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func contextMenu() -> NSMenu? {
        let menu = NSMenu()
        switch node.kind {
        case let .snapshot(snapshot):
            menu.addItem(NSMenuItem(title: "Delete Snapshot") { [model] in model.deleteSnapshot(snapshot) })
        case let .recipe(recipe):
            let favorite = model.recipes.isFavorite(recipe)
            menu.addItem(NSMenuItem(title: favorite ? "Remove from Favorites" : "Add to Favorites") { [model] in
                model.recipes.setFavorite(recipe, !favorite)
            })
            menu.addItem(NSMenuItem(title: "Export…") { [model] in RecipeActions.export(recipe, model: model) })
            menu.addItem(NSMenuItem(title: "Duplicate to My Recipes") { [model] in
                var copy = recipe
                copy.id = RecipeNamespace.newLocalID()
                copy.version = 1
                copy.name = "\(recipe.name) Copy"
                copy.group = "My Recipes"
                copy.embeddedBaseLooks = model.recipes.library.exportable(recipe).embeddedBaseLooks
                model.recipes.save(copy)
            })
            if model.recipes.isUserRecipe(recipe) {
                menu.addItem(.separator())
                menu.addItem(NSMenuItem(title: "Delete Recipe") { [model] in model.recipes.delete(recipe) })
            }
        default:
            return nil
        }
        return menu
    }

    // MARK: - Hover preview

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea {
            removeTrackingArea(hoverArea)
        }
        guard case .recipe = node.kind else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with _: NSEvent) {
        label.textColor = Palette.labelHover.nsColor
        guard model.info != nil, case let .recipe(recipe) = node.kind else { return }
        model.previewRecipe(recipe)
    }

    override func mouseExited(with _: NSEvent) {
        label.textColor = Palette.label.nsColor
        guard model.info != nil else { return }
        model.previewRecipe(nil)
    }
}

// MARK: - History

extension SidebarCellView {
    /// A step of this session, an earlier session, or one of its steps.
    private func showHistory(_ kind: SidebarNode.Kind) {
        switch kind {
        case let .history(step, _, current, future):
            showStep(step, current: current, undone: future)
            toolTip = future ? "\(step.name)\nUndone: click to go back to it" : step.name
            setAccessibilityLabel(step.name + (current ? ", current step" : future ? ", undone" : ""))
        case let .session(session):
            label.stringValue = session.title
            label.textColor = Palette.secondaryLabel.nsColor
            showChevron()
            showIcon("clock")
            let count = session.steps.count
            let steps = NSTextField(labelWithString: "\(count) step\(count == 1 ? "" : "s")")
            steps.font = Typography.caption.nsFont
            steps.textColor = Palette.tertiaryLabel.nsColor
            trailing = steps
            toolTip = "An earlier session with this photo, started \(session.title)"
        case let .earlierStep(step, session):
            showStep(step, current: false, undone: false)
            toolTip = "\(step.name)\nFrom \(session.title): click to bring it back as a new step"
            setAccessibilityLabel("\(step.name), from \(session.title)")
        default:
            break
        }
    }

    /// Puts a step's values at the end of the row and returns where its title must end. The
    /// title comes first: short of room, the value before goes, then both truncate.
    private func place(
        _ values: HistoryValuesView,
        from titleX: CGFloat,
        to titleMaxX: CGFloat,
        title: CGFloat,
    ) -> CGFloat {
        let scale = backingScale
        let available = titleMaxX - titleX
        // A label draws its text inset by `labelPadding` on both sides of its intrinsic width.
        let title = title + Layout.labelPadding
        let width = if title + Layout.valuesGap + values.fullWidth <= available {
            values.fullWidth
        } else {
            max(min(
                values.afterWidth,
                available - Layout.valuesGap - min(title, max(available * Layout.titleShare, Layout.minimumTitle)),
            ), 0)
        }
        let height = values.intrinsicContentSize.height
        values.frame = CGRect(
            x: PixelGrid.round(titleMaxX - width, scale: scale),
            y: PixelGrid.round((bounds.height - height) / 2, scale: scale), width: width, height: height,
        )
        return values.frame.minX - Layout.valuesGap
    }

    /// The step's action's icon, its title, and the value it changed before and after.
    private func showStep(_ step: HistoryStep, current: Bool, undone: Bool) {
        label.stringValue = step.title
        label.textColor = (undone ? Palette.tertiaryLabel : current ? Palette.labelHover : Palette.label).nsColor
        showIcon(step.action.symbol, color: undone ? Palette.tertiaryLabel : Palette.secondaryLabel)
        if let after = step.after {
            values = HistoryValuesView(before: step.before, after: after, dimmed: undone)
        }
    }
}

/// A group's chevron, drawn as a panel header's is, and turned down while the group is open.
private final class ChevronView: LayerDrawnView {
    var isExpanded = false {
        didSet {
            if isExpanded != oldValue {
                setNeedsContentDisplay()
            }
        }
    }

    override func drawContent(in _: CGRect) {
        Symbol.draw(
            "chevron.right", pointSize: 9, weight: .bold, color: Palette.secondaryLabel,
            centeredAt: CGPoint(x: bounds.midX, y: bounds.midY), rotation: isExpanded ? 90 : 0, scale: backingScale,
        )
    }
}
