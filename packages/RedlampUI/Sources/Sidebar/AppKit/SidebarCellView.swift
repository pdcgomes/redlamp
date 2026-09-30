import AppKit
import RedlampDesign
import RedlampDocument
import RedlampRecipes

/// One row, with the fonts, colors, icons and accessories of the SwiftUI rows.
final class SidebarCellView: NSTableCellView {
    /// Where SwiftUI's sidebar rows put things, measured in the harness's sidebar parity
    /// scene: a `Label`'s icon is centered at a fixed offset with its title at another, and
    /// rows inside a disclosure group sit a point further out than the outline view indents.
    /// The fonts and icon size are the ones a source list gives its cells' outlets, which
    /// these cells don't use as the outline view would also lay them out.
    @MainActor enum Layout {
        static let iconCenter: CGFloat = 13
        static let titleInset: CGFloat = 30
        static let nestedRowOffset: CGFloat = -1
        /// A label's text sits this far into its frame.
        static let labelPadding: CGFloat = 2
        static let headerFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        static let rowFont = NSFont.systemFont(ofSize: 13)
        static let iconPointSize: CGFloat = 13
    }

    private let node: SidebarNode
    private let model: EditorModel
    private let label = NSTextField(labelWithString: "")
    private var icon: SymbolImageView?
    private var trailing: NSView?
    private var amountSlider: NSSlider?
    private var hoverArea: NSTrackingArea?

    init(node: SidebarNode, model: EditorModel) {
        self.node = node
        self.model = model
        super.init(frame: .zero)
        label.lineBreakMode = .byTruncatingTail
        label.font = Layout.rowFont
        addSubview(label)
        var symbol: String?
        switch node.kind {
        case let .header(title, button):
            label.stringValue = title
            label.font = Layout.headerFont
            label.textColor = .tertiaryLabelColor
            if let button {
                trailing = headerButton(button)
            }
        case let .group(name):
            label.stringValue = name
            label.textColor = .tertiaryLabelColor
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
                    model.endEdit(name: "Recipe Amount")
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
        case let .history(step, _, current, future):
            label.stringValue = step.name
            label.textColor = (future ? Palette.tertiaryLabel : (current ? Palette.labelHover : Palette.label)).nsColor
            if current {
                trailing = SymbolImageView(
                    "checkmark",
                    pointSize: 9,
                    weight: .bold,
                    color: Palette.secondaryLabel.nsColor,
                )
            }
        }
        if let symbol {
            let image = SymbolImageView(symbol, pointSize: Layout.iconPointSize, color: .labelColor)
            addSubview(image)
            icon = image
        }
        if let trailing {
            addSubview(trailing)
        }
        needsLayout = true
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
        var titleX: CGFloat = 0
        switch node.kind {
        case .recipe, .recipeAmount: titleX = Layout.nestedRowOffset
        default: break
        }
        if let amountSlider {
            let width = min(max(bounds.width * 0.55, 80), 160)
            amountSlider.frame = CGRect(
                x: bounds.width - width - 2, y: centeredY(CGSize(width: width, height: 16)), width: width, height: 16,
            )
        }
        if let image = icon {
            let size = image.intrinsicContentSize
            image.frame = CGRect(
                x: PixelGrid.round(Layout.iconCenter - size.width / 2, scale: scale), y: centeredY(size),
                width: size.width, height: size.height,
            )
            titleX = Layout.titleInset
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
        titleX -= Layout.labelPadding
        label.frame = CGRect(x: titleX, y: centeredY(size), width: max(titleMaxX - titleX, 0), height: size.height)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func headerButton(_ button: SidebarNode.HeaderButton) -> NSView {
        let symbol: String, help: String, enabled: Bool
        switch button {
        // Importing works without a photo; creating one is disabled in the menu instead.
        case .recipes: (symbol, help, enabled) = ("plus", "Create or Import a Recipe", true)
        case let .createSnapshot(isEnabled): (symbol, help, enabled) = ("plus", "Create Snapshot (⌘N)", isEnabled)
        case let .clearHistory(isEnabled): (symbol, help, enabled) = ("xmark", "Clear History", isEnabled)
        }
        let control = SymbolImageView(
            symbol, pointSize: Layout.headerFont.pointSize, weight: .semibold, color: .tertiaryLabelColor,
        )
        control.toolTip = help
        control.setAccessibilityRole(.button)
        control.setAccessibilityLabel(help)
        control.isEnabled = enabled
        let model = model
        control.onClick = { [weak control] in
            switch button {
            case let .recipes(hasPhoto):
                guard let control else { return }
                let menu = NSMenu()
                let create = NSMenuItem(title: "Create Recipe from Current Edit…") {
                    RecipeActions.createRecipe(model: model)
                }
                create.isEnabled = hasPhoto
                menu.autoenablesItems = false
                menu.addItem(create)
                menu
                    .addItem(NSMenuItem(title: "Import Recipe, .cube or HaldCLUT…") {
                        RecipeActions.importRecipes(model: model)
                    })
                menu.popUp(positioning: nil, at: CGPoint(x: 0, y: control.bounds.height + 4), in: control)
            case .createSnapshot: model.createSnapshot()
            case .clearHistory: model.clearHistory()
            }
        }
        return control
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
