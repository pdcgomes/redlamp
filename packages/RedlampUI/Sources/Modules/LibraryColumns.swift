import AppKit
import Observation
import RedlampDesign
import RedlampDocument

/// The Library module's left column: the Folders panel, which chooses the source the grid and the filmstrip
/// show, as Develop's does.
final class LibraryFoldersColumn: PanelColumnScrollView {
    init(model: EditorModel) {
        let add = SymbolImageView("plus", pointSize: 11, color: Palette.secondaryLabel.nsColor)
        add.toolTip = "Add Folder…"
        add.setAccessibilityRole(.button)
        add.setAccessibilityLabel("Add Folder…")
        add.onClick = { FolderActions.add(model: model) }
        let insets = NSEdgeInsets(top: 0, left: 0, bottom: Metrics.panelBottomPadding, right: 0)
        let folders = PanelSectionView(
            section: .folders, model: model, accessory: add, insets: insets, rows: [FolderOutlineView(model: model)],
        )
        super.init(views: [folders])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// The Library module's right column: the active photo's file and badges.
final class LibraryInfoColumn: PanelColumnScrollView {
    private let model: EditorModel
    private let rows: [InfoRow]
    private var tracker: Tracker?

    private enum Field: CaseIterable {
        case name, folder, size, modified, rating, flag, label, marked, edited

        var title: String {
            switch self {
            case .name: "File Name"
            case .folder: "Folder"
            case .size: "File Size"
            case .modified: "Modified"
            case .rating: "Rating"
            case .flag: "Flag"
            case .label: "Label"
            case .marked: "Marked"
            case .edited: "Edited"
            }
        }
    }

    init(model: EditorModel) {
        self.model = model
        let rows = Field.allCases.map { InfoRow(title: $0.title) }
        self.rows = rows
        let panels = LibraryPanels()
        let photo = PanelSectionView(
            title: "Photo", symbol: "info.circle", rows: rows,
            actions: PanelSectionView.Actions(
                isExpanded: { panels.photoExpanded },
                isEdited: { false },
                toggle: { _ in panels.photoExpanded.toggle() },
                reset: {},
            ),
        )
        photo.identify(as: "library.photo")
        super.init(views: [photo])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tracker?.cancel()
        tracker = nil
        guard window != nil else { return }
        tracker = Tracker { [weak self] in
            guard let self else { return }
            _ = model.library.revision
            let item = model.selection.flatMap(model.library.item(for:))
            for (row, field) in zip(rows, Field.allCases) {
                row.value = item.map { Self.value(field, of: $0) } ?? "—"
            }
        }
    }

    private static func value(_ field: Field, of item: LibraryItem) -> String {
        let metadata = item.metadata
        switch field {
        case .name: return item.name
        case .folder: return URL(fileURLWithPath: item.folderPath).lastPathComponent
        case .size: return ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
        case .modified: return item.modified.formatted(date: .abbreviated, time: .shortened)
        case .rating: return metadata.rating > 0 ? String(repeating: "★", count: metadata.rating) : "None"
        case .flag: return metadata.flag.map { $0 == .pick ? "Pick" : "Rejected" } ?? "None"
        case .label: return metadata.label.map(\.rawValue.capitalized) ?? metadata.customLabel ?? "None"
        case .marked: return metadata.mark ? "Yes" : "No"
        case .edited: return item.hasEdits ? "Yes" : "No"
        }
    }
}

/// Which of the Library module's panels are expanded.
@Observable
private final class LibraryPanels {
    var photoExpanded = true
}

/// A field's name and value, as the Develop panels' rows are spaced.
private final class InfoRow: NSView {
    private let title: NSTextField
    private let field = NSTextField(labelWithString: "—")

    var value: String {
        get { field.stringValue }
        set {
            guard field.stringValue != newValue else { return }
            field.stringValue = newValue
            field.toolTip = newValue
        }
    }

    init(title: String) {
        self.title = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        self.title.font = Typography.label.nsFont
        self.title.textColor = Palette.secondaryLabel.nsColor
        self.title.alignment = .right
        field.font = Typography.label.nsFont
        field.textColor = Palette.value.nsColor
        field.lineBreakMode = .byTruncatingMiddle
        addSubview(self.title)
        addSubview(field)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool {
        true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Metrics.rowHeight)
    }

    override func layout() {
        super.layout()
        let height = field.intrinsicContentSize.height
        let y = (bounds.height - height) / 2
        title.frame = CGRect(x: 0, y: y, width: Metrics.labelWidth, height: height)
        let x = Metrics.labelWidth + Metrics.rowSpacing
        field.frame = CGRect(x: x, y: y, width: max(bounds.width - x, 0), height: height)
    }
}
