import AppKit
import RedlampDesign

/// The Library module's Library and Collections panels on their own, for the performance harness to count a
/// library in a window of its own (LIB-23).
@_spi(Harness) public enum LibrarySourcesViews {
    @MainActor public static func make(model: EditorModel) -> NSView {
        PanelColumnScrollView(views: [SourcePanels.library(model: model), SourcePanels.collections(model: model)])
    }
}
