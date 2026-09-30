import RedlampCanvas

/// Before / After: `\` shows it in `compareLayout`; `Y` and `⇧Y` cycle the layout.
public extension EditorModel {
    /// The original replaces the edit on the whole canvas.
    var isShowingOriginal: Bool {
        showBefore && compareLayout == .toggle
    }

    /// The original shares the canvas with the edit (side by side or split).
    var isComparing: Bool {
        showBefore && compareLayout != .toggle
    }

    func showComparison(in layout: CompareLayout) {
        compareLayout = layout
        showBefore = true
    }

    /// `Y` / `⇧Y`: shows Before / After, or once it's showing, moves to the next layout.
    func cycleCompareLayout(by offset: Int) {
        if showBefore {
            compareLayout = compareLayout.cycled(by: offset)
        } else {
            showBefore = true
        }
    }

    internal var canvasComparison: CanvasController.Comparison {
        guard isComparing else { return .none }
        return compareLayout == .sideBySide ? .sideBySide : .split(position: splitPosition)
    }

    internal func updateComparison() {
        canvas.comparison = canvasComparison
        requestRender()
    }
}
