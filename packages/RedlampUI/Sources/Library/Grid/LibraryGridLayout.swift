import AppKit

/// The grid's layout: cells of one size in rows as wide as the grid, centred, each cell's place worked out
/// from its index, so a grid of a million photos lays out what's on screen and nothing more. LIB-14 adds sizes.
final class LibraryGridLayout: NSCollectionViewLayout {
    static let cellSize = CGSize(width: 124, height: 124)
    static let spacing: CGFloat = 6
    static let insets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

    private var count = 0
    private var preparedWidth: CGFloat = 0
    /// The cells' attributes as made since the layout last changed: scrolling asks for them every frame.
    private var made: [Int: NSCollectionViewLayoutAttributes] = [:]

    /// The grid's width: its scroll view's.
    private var width: CGFloat {
        guard let collectionView else { return 0 }
        return collectionView.enclosingScrollView?.contentView.bounds.width ?? collectionView.bounds.width
    }

    /// Cells in a row.
    var columns: Int {
        let usable = width - Self.insets.left - Self.insets.right
        return max(Int((usable + Self.spacing) / (Self.cellSize.width + Self.spacing)), 1)
    }

    var rows: Int {
        (count + columns - 1) / columns
    }

    /// Whole rows in `height` points.
    func rows(in height: CGFloat) -> Int {
        max(Int((height + Self.spacing) / (Self.cellSize.height + Self.spacing)), 1)
    }

    override func prepare() {
        super.prepare()
        count = collectionView.map { $0.numberOfSections > 0 ? $0.numberOfItems(inSection: 0) : 0 } ?? 0
        preparedWidth = width
        made = [:]
    }

    override var collectionViewContentSize: NSSize {
        let height = Self.insets.top + Self.insets.bottom + CGFloat(rows) * Self.cellSize.height
            + CGFloat(max(rows - 1, 0)) * Self.spacing
        return NSSize(width: width, height: height)
    }

    /// Where cell `index` is.
    func frame(forItem index: Int) -> CGRect {
        let columns = columns
        let used = CGFloat(columns) * Self.cellSize.width + CGFloat(columns - 1) * Self.spacing
        let left = max((width - used) / 2, Self.insets.left)
        return CGRect(
            x: left + CGFloat(index % columns) * (Self.cellSize.width + Self.spacing),
            y: Self.insets.top + CGFloat(index / columns) * (Self.cellSize.height + Self.spacing),
            width: Self.cellSize.width,
            height: Self.cellSize.height,
        )
    }

    /// The cells that meet `rect`.
    func items(in rect: CGRect) -> Range<Int> {
        guard count > 0 else { return 0 ..< 0 }
        let pitch = Self.cellSize.height + Self.spacing
        let first = max(Int(((rect.minY - Self.insets.top) / pitch).rounded(.down)), 0)
        let last = min(Int(((rect.maxY - Self.insets.top) / pitch).rounded(.down)), rows - 1)
        guard first <= last else { return 0 ..< 0 }
        return first * columns ..< min((last + 1) * columns, count)
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        items(in: rect).map(attributes)
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        attributes(indexPath.item)
    }

    private func attributes(_ index: Int) -> NSCollectionViewLayoutAttributes {
        if let attributes = made[index] {
            return attributes
        }
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: index, section: 0))
        attributes.frame = frame(forItem: index)
        if made.count >= 4096 {
            made = [:]
        }
        made[index] = attributes
        return attributes
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != preparedWidth
    }
}
