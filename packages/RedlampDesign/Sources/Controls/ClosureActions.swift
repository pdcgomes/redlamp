import AppKit
import ObjectiveC

/// Closure-based target/action for AppKit controls and menu items.
@MainActor
final class ClosureAction: NSObject {
    let handler: @MainActor (Any?) -> Void

    init(_ handler: @escaping @MainActor (Any?) -> Void) {
        self.handler = handler
    }

    @objc func invoke(_ sender: Any?) {
        handler(sender)
    }
}

private nonisolated(unsafe) var closureActionKey: UInt8 = 0

public extension NSControl {
    /// Calls `handler` when the control sends its action. The control keeps the closure.
    func onAction(_ handler: @escaping @MainActor (Self) -> Void) {
        let action = ClosureAction { sender in
            if let control = sender as? Self {
                handler(control)
            }
        }
        objc_setAssociatedObject(self, &closureActionKey, action, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        target = action
        self.action = #selector(ClosureAction.invoke(_:))
    }
}

public extension NSMenuItem {
    @MainActor
    convenience init(
        title: String,
        state: NSControl.StateValue = .off,
        action handler: @escaping @MainActor () -> Void,
    ) {
        self.init(title: title, action: #selector(ClosureAction.invoke(_:)), keyEquivalent: "")
        let action = ClosureAction { _ in handler() }
        objc_setAssociatedObject(self, &closureActionKey, action, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        target = action
        self.state = state
    }
}
