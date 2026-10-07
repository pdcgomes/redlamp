import AppKit
import RedlampDesign

/// The Folders panel's Recently Trashed row (LIB-26), after the folders while the library is open.
struct TrashRow: Equatable {
    /// How many photos it holds; nil until the library has looked.
    let count: Int?
    /// It's the source shown.
    let isOpen: Bool
}

/// What the Folders panel says of Recently Trashed: its help, and shown empty, the line under it.
@_spi(Harness) public enum RecentlyTrashedText {
    public static let help = "The photos Redlamp moved to the Trash that are still there. Put Back (⌘⌫) puts them "
        + "where they were, with their edits; emptying the Trash removes them for good."
    public static let empty = "Photos Redlamp moves to the Trash show here until it's emptied"
}

extension SidebarCellView {
    /// Recently Trashed's icon, name and count.
    static func trashDecoration(_ row: TrashRow) -> FolderDecoration {
        FolderDecoration(
            name: "Recently Trashed",
            nameColor: row.isOpen ? Palette.labelHover : Palette.label,
            help: RecentlyTrashedText.help,
            accessibilityLabel: "Recently Trashed" + (row.count.map { ", " + photos($0) } ?? "")
                + (row.isOpen ? ", open" : ""),
            symbol: row.isOpen ? "trash.fill" : "trash",
            color: Palette.secondaryLabel,
            count: row.count?.formatted(),
        )
    }
}
