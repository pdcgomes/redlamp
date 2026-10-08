import AppKit
import RedlampLibrary

/// The painter in the grid (LIB-21, `KeywordPainter`): while it's out, a press paints the photo under it, a drag every
/// photo it passes over, scrolling on at the grid's edges, and the release makes the stroke's change; ⌥ held at the
/// press takes the keywords off. The selection stays as it was, and the photos painted are outlined until the stroke
/// ends. Without keywords to paint, a press beeps.
extension LibraryGridView {
    /// A press while the painter is out begins its stroke; false while it's put away.
    func paints(_ event: NSEvent, at point: CGPoint) -> Bool {
        let painter = model.keywordPainter
        guard painter.isOn else { return false }
        guard painter.begin(removing: event.modifierFlags.contains(.option)) else {
            NSSound.beep()
            return true
        }
        lastPaint = nil
        paintStroke(to: point)
        return true
    }

    /// The press moved while painting: every photo between where it was and where it is joins the stroke.
    func paintsAlong(_ event: NSEvent) -> Bool {
        let painter = model.keywordPainter
        guard painter.isOn else { return false }
        guard painter.stroke != nil else { return true }
        content.autoscroll(with: event)
        paintStroke(to: content.convert(event.locationInWindow, from: nil))
        return true
    }

    /// The press released while painting: the stroke's change is made, and its outlines go.
    func endsStroke() -> Bool {
        let painter = model.keywordPainter
        guard painter.isOn || painter.stroke != nil else { return false }
        painter.end()
        lastPaint = nil
        showPainted(nil)
        return true
    }

    /// Paints from where the stroke last reached to `point`, a few points at a time, so a quick drag leaves no
    /// photo out.
    private func paintStroke(to point: CGPoint) {
        let from = lastPaint ?? point
        lastPaint = point
        let step = max(min(gridLayout.cellSize.width, gridLayout.cellSize.height) / 4, 4)
        let steps = Int(hypot(point.x - from.x, point.y - from.y) / step)
        let ids = model.library.photoIDs
        var painted: [Int] = []
        for sample in 0 ... steps {
            let t = steps == 0 ? 1 : CGFloat(sample) / CGFloat(steps)
            let at = CGPoint(x: from.x + (point.x - from.x) * t, y: from.y + (point.y - from.y) * t)
            guard let index = gridLayout.item(at: at), index < shownCount, let row = row(ofItem: index),
                  ids.indices.contains(row),
                  model.keywordPainter.paint(ids[row], url: model.items[row].url)
            else { continue }
            painted.append(index)
        }
        showPainted(painted)
    }

    /// Outlines the cells of items `painted`, or with nil, takes every outline away.
    private func showPainted(_ painted: [Int]?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let painted {
            for index in painted {
                cells[index]?.isDropTarget = true
            }
        } else {
            for cell in cells.values where cell.isDropTarget {
                cell.isDropTarget = false
            }
        }
        CATransaction.commit()
    }
}
