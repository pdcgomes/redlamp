import AppKit

extension NSWindow {
    /// The height for a sheet that would be `height` tall on this window: no taller than fits
    /// below the toolbar with a margin, nor shorter than 400 points. macOS 26 centres a sheet
    /// on its window but never over the toolbar, so a taller one hangs past the window's
    /// bottom edge, its buttons with it.
    func sheetHeight(fitting height: CGFloat) -> CGFloat {
        min(height, max(contentLayoutRect.height - 24, 400))
    }
}
