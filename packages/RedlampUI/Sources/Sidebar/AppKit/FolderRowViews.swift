import AppKit
import RedlampDesign
import RedlampDocument
import RedlampLibrary

/// A row of the Folders panel: a folder the user added (a root) or one beneath it.
struct FolderRow: Equatable {
    let url: URL
    let name: String
    /// The root this folder is in.
    let root: WorkingFolder
    /// The photos it shows, once known: those directly in it, or with Show Photos in Subfolders those
    /// below it too (`FolderLibrary.photoCount(of:)`).
    let count: Int?
    let hasSubfolders: Bool
    let isMissing: Bool
    let isOpen: Bool
    /// Opening it would show photos: it counts some, or, not counted yet, has subfolders that may
    /// with Show Photos in Subfolders. Folders not listed yet count as selectable, so rows don't
    /// flicker.
    let isSelectable: Bool
    /// Show Photos in Subfolders, which its count and its help follow.
    var includesSubfolders = false

    /// Listed, and nothing to show: dimmed, and clicking it doesn't open it.
    var isEmpty: Bool {
        !isMissing && !isSelectable
    }

    var isRoot: Bool {
        url.standardizedFileURL.path == root.path
    }
}

extension SidebarCellView {
    /// What a folder's row shows: its name, its help, its icon, and at its end its count or, for a missing
    /// root, a question mark. A row whose count changes shows the new one without anything else changing.
    struct FolderDecoration: Equatable {
        var name: String
        var nameColor: RGBA
        var help: String
        var accessibilityLabel: String
        var symbol: String
        var color: RGBA
        var count: String?
        var isMissing = false
    }

    /// A folder's icon, name and photo count; a missing root is dimmed with a question mark, and a
    /// folder with no photos to show is dimmed.
    static func folderDecoration(_ row: FolderRow) -> FolderDecoration {
        let dimmed = row.isMissing || row.isEmpty
        let help = if row.isMissing {
            "\(row.root.path)\nNot found: it may be on a disk that isn't connected"
        } else if row.isEmpty {
            row.hasSubfolders && !row.includesSubfolders
                ? "\(row.url.path)\nNo photos directly in this folder. Turn on Show Photos in Subfolders to see the ones below it."
                : row.hasSubfolders ? "\(row.url.path)\nNo photos in this folder or the folders in it"
                : "\(row.url.path)\nNo photos in this folder"
        } else if row.hasSubfolders {
            row.includesSubfolders
                ? "\(row.url.path)\nCounts the photos in this folder and the folders in it"
                : "\(row.url.path)\nCounts the photos directly in this folder"
        } else {
            row.url.path
        }
        return FolderDecoration(
            name: row.name,
            nameColor: dimmed ? Palette.tertiaryLabel : row.isOpen ? Palette.labelHover : Palette.label,
            help: help,
            accessibilityLabel: row.name + (row.isMissing ? ", missing" : row.isEmpty ? ", no photos"
                : row.count.map { ", " + Self.photos($0) } ?? "") + (row.isOpen ? ", open" : ""),
            symbol: row.isMissing ? "folder.badge.questionmark" : row.isOpen ? "folder.fill" : "folder",
            color: dimmed ? Palette.tertiaryLabel : Palette.secondaryLabel,
            count: row.isMissing ? nil : row.count?.formatted(), isMissing: row.isMissing,
        )
    }

    /// "1 photo", "1,204 photos".
    static func photos(_ count: Int) -> String {
        "\(count.formatted()) photo\(count == 1 ? "" : "s")"
    }

    /// Show in Finder, Show Summary… (beside `anchor`, its row), Show Photos in Subfolders, and for a root, Move Edits
    /// and Metadata… with the library open, Remove from Folders, and Locate… when it's missing.
    static func folderMenu(_ row: FolderRow, model: EditorModel, anchor: NSView) -> NSMenu {
        let menu = NSMenu()
        if !row.isMissing {
            menu.addItem(NSMenuItem(title: "Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([row.url])
            })
            if let service = model.library.service, service.isReady {
                let source = PhotoSource.folder(row.url, includingSubfolders: model.library.includesSubfolders)
                menu.addItem(afterMenu("Show Summary…") { [weak anchor] in
                    guard let anchor else { return }
                    SourceSummaryPopover.show(row.name, relativeTo: anchor) { await service.summary(of: source) }
                })
            }
            let subfolders = NSMenuItem(title: ShortcutAction.showPhotosInSubfolders.title) {
                if model.folder != row.url {
                    model.showFolder(row.url)
                }
                model.perform(.showPhotosInSubfolders)
            }
            subfolders.state = model.library.includesSubfolders ? .on : .off
            menu.addItem(subfolders)
        }
        if row.isRoot {
            menu.addItem(.separator())
            if row.isMissing {
                menu.addItem(NSMenuItem(title: "Locate…") { FolderActions.locate(row.root, model: model) })
            } else if model.library.service?.isReady == true {
                menu.addItem(NSMenuItem(title: ShortcutAction.moveEditsAndMetadata.title) {
                    FolderActions.moveEdits(row.root, model: model)
                })
            }
            menu.addItem(NSMenuItem(title: "Remove from Folders") { FolderActions.remove(row.root, model: model) })
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

    /// Remove from Folders: the root leaves Folders and the library, with its photos, as Lightroom Classic's
    /// Remove does; nothing on disk changes, and Add Folder… brings them back with what their sidecars hold.
    /// Like Folders' other changes, it isn't on Undo.
    static func remove(_ root: WorkingFolder, model: EditorModel) {
        model.library.remove(root)
    }

    /// Move Edits and Metadata…: its sheet for the root, as the Library menu's is for the root of the folder open.
    static func moveEdits(_ root: WorkingFolder, model: EditorModel) {
        if model.moveEditsAndMetadata(of: root) {
            model.activity.record(.action, ShortcutAction.moveEditsAndMetadata.title)
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
