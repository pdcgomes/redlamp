import AppKit
import RedlampLibrary

/// What the regression suite reads and sets in the Lightroom Classic window: what a person sets through its open
/// panels, which can't be driven, and what it shows.
@_spi(Harness) public extension LightroomWindowController {
    /// Choose…'s catalog.
    func choose(catalog url: URL) {
        model.choose(url)
    }

    /// Locate…'s folder for the root folder the catalog calls `path`.
    func locate(_ path: String, at url: URL) {
        model.locate(path, at: url)
    }

    /// The catalog is read and its report shown.
    var isReported: Bool {
        model.phase == .reported && model.report != nil
    }

    var report: LightroomReport? {
        model.report
    }

    /// The import ran to its end, or stopped.
    var isImported: Bool {
        model.phase == .imported
    }

    var isUndone: Bool {
        model.phase == .undone && !model.isBusy
    }

    var outcome: LightroomImport.Outcome? {
        model.outcome
    }

    /// What went wrong last, in words.
    var problem: String? {
        model.problem
    }

    /// The text under the report.
    var statusText: String {
        model.status
    }

    /// The text of the button carrying `identifier`, and whether it's shown and enabled.
    func button(_ identifier: String) -> (title: String, shown: Bool, enabled: Bool)? {
        guard let content = window?.contentView, let button = Self.view(identifier, in: content) as? NSButton else {
            return nil
        }
        return (button.title, !button.isHiddenOrHasHiddenAncestor, button.isEnabled)
    }

    private static func view(_ identifier: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == identifier {
            return view
        }
        for subview in view.subviews {
            if let found = Self.view(identifier, in: subview) {
                return found
            }
        }
        return nil
    }
}
