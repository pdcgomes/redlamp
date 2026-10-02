import AppKit
import RedlampDesign
import RedlampDocument

/// A row of the Folders panel: a folder the user added (a root) or one beneath it.
struct FolderRow: Equatable {
    let url: URL
    let name: String
    /// The root this folder is in.
    let root: WorkingFolder
    /// Photos directly in it, once listed.
    let count: Int?
    let hasSubfolders: Bool
    let isMissing: Bool
    let isOpen: Bool

    var isRoot: Bool {
        url.standardizedFileURL.path == root.path
    }
}

extension SidebarCellView {
    /// What a folder row shows beside its name.
    struct FolderDecoration {
        let symbol: String
        let color: RGBA
        let trailing: NSView?
    }

    /// A folder's icon, name and photo count; a missing root is dimmed with a question mark.
    func showFolder(_ row: FolderRow, label: NSTextField) -> FolderDecoration {
        label.stringValue = row.name
        label.textColor = (row.isMissing ? Palette.tertiaryLabel : row.isOpen ? Palette.labelHover : Palette.label)
            .nsColor
        toolTip = row.isMissing ? "\(row.root.path)\nNot found: it may be on a disk that isn't connected" : row.url.path
        setAccessibilityLabel(row.name + (row.isMissing ? ", missing" : row.isOpen ? ", open" : ""))
        var trailing: NSView?
        if let count = row.count, !row.isMissing {
            let text = NSTextField(labelWithString: count.formatted())
            text.font = Typography.caption.nsFont
            text.textColor = Palette.tertiaryLabel.nsColor
            trailing = text
        } else if row.isMissing {
            trailing = SymbolImageView("questionmark.circle", pointSize: 10, color: Palette.tertiaryLabel.nsColor)
        }
        let symbol = row.isMissing ? "folder.badge.questionmark" : row.isOpen ? "folder.fill" : "folder"
        return FolderDecoration(
            symbol: symbol, color: row.isMissing ? Palette.tertiaryLabel : Palette.secondaryLabel, trailing: trailing,
        )
    }

    /// Show in Finder, Show Photos in Subfolders, Remove from Folders, Locate….
    static func folderMenu(_ row: FolderRow, model: EditorModel) -> NSMenu {
        let menu = NSMenu()
        if !row.isMissing {
            menu.addItem(NSMenuItem(title: "Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([row.url])
            })
            let subfolders = NSMenuItem(title: "Show Photos in Subfolders") {
                if model.folder != row.url {
                    model.showFolder(row.url)
                }
                model.setIncludesSubfolders(!model.library.includesSubfolders)
            }
            subfolders.state = model.library.includesSubfolders ? .on : .off
            menu.addItem(subfolders)
        }
        if row.isRoot {
            menu.addItem(.separator())
            if row.isMissing {
                menu.addItem(NSMenuItem(title: "Locate…") { FolderActions.locate(row.root, model: model) })
            }
            menu.addItem(NSMenuItem(title: "Remove from Folders") { model.library.remove(row.root) })
        }
        return menu
    }
}

/// The Folders panel's actions that need a panel.
@MainActor
enum FolderActions {
    /// Add Folder…: the chosen folders join the working set and the first opens.
    static func add(model: EditorModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders of photos to add to Folders. Nothing in them is moved or changed."
        if panel.runModal() == .OK {
            model.open(panel.urls)
        }
    }

    static func locate(_ root: WorkingFolder, model: EditorModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Locate"
        panel.message = "Where is “\(root.name)” now? It was at \(root.path)."
        if panel.runModal() == .OK, let url = panel.url {
            model.library.locate(root, at: url)
        }
    }
}
