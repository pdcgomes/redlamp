import AppKit

extension NSWindow {
    /// The height for a sheet that would be `height` tall on this window: no taller than fits
    /// below the toolbar with a margin, nor shorter than 400 points. macOS 26 centres a sheet
    /// on its window but never over the toolbar, so a taller one hangs past the window's
    /// bottom edge, its buttons with it.
    func sheetHeight(fitting height: CGFloat) -> CGFloat {
        Self.sheetHeight(fitting: height, below: contentLayoutRect.height)
    }

    /// The same for a window whose content below the toolbar is `layoutHeight` tall.
    static func sheetHeight(fitting height: CGFloat, below layoutHeight: CGFloat) -> CGFloat {
        min(height, max(layoutHeight - 24, 400))
    }
}
