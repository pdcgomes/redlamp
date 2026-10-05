#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import RedlampDesign
    import RedlampEngineAPI
    @_spi(Harness) import RedlampUI

    /// Something on screen to click or drag, found by the identifiers the views carry
    /// (`slider.basic.exposure`, `panel.basic.header`, `tool.masking`, `canvas`).
    public enum Target: Sendable, CustomStringConvertible {
        case identifier(String)
        case slider(ParameterID)
        case sliderLabel(ParameterID)
        case sliderValue(ParameterID)
        case panelHeader(PanelID)
        case sidebarHeader(SidebarSection)
        case tool(EditTool)
        case histogram(ParameterID)
        case canvas
        case filmstrip(String)

        var identifier: String {
            switch self {
            case let .identifier(identifier): identifier
            case let .slider(parameter): "slider.\(parameter.rawValue).track"
            case let .sliderLabel(parameter): "slider.\(parameter.rawValue).label"
            case let .sliderValue(parameter): "slider.\(parameter.rawValue).value"
            case let .panelHeader(panel): "panel.\(panel.rawValue).header"
            case let .sidebarHeader(section): "sidebar.\(section.rawValue).header"
            case let .tool(tool): "tool.\(tool.rawValue)"
            case let .histogram(parameter): "histogram.\(parameter.rawValue)"
            case .canvas: "canvas"
            case let .filmstrip(name): "filmstrip.\(name)"
            }
        }

        public var description: String {
            identifier
        }
    }

    @MainActor
    enum Views {
        static var editorWindow: NSWindow? {
            NSApp.windows.first { $0.isVisible && $0.windowController is EditorWindowController }
        }

        /// The view or accessibility element carrying `identifier`, and its frame in the window.
        static func find(_ identifier: String, in window: NSWindow) -> NSRect? {
            guard let root = window.contentView?.superview ?? window.contentView else { return nil }
            return search(root, identifier, window)
        }

        private static func search(_ view: NSView, _ identifier: String, _ window: NSWindow) -> NSRect? {
            if view.isHiddenOrHasHiddenAncestor {
                return nil
            }
            if view.accessibilityIdentifier() == identifier {
                return view.convert(view.bounds, to: nil)
            }
            if ["toolstrip", "histogram"].contains(view.accessibilityIdentifier()) {
                for case let element as NSAccessibilityElement in view.accessibilityChildren() ?? []
                    where element.accessibilityIdentifier() == identifier {
                    return window.convertFromScreen(element.accessibilityFrame())
                }
            }
            for child in view.subviews {
                if let found = search(child, identifier, window) {
                    return found
                }
            }
            return nil
        }

        /// Every view of type `T` in the window, in the order a person reads them.
        static func all<T: NSView>(_: T.Type, in view: NSView) -> [T] {
            var found: [T] = []
            if let match = view as? T {
                found.append(match)
            }
            for child in view.subviews {
                found += all(T.self, in: child)
            }
            return found
        }
    }

    // MARK: - Mouse

    public extension RunningApp {
        /// The target's frame in the editor window, scrolled into view first.
        func frame(of target: Target) throws -> NSRect {
            let identifier = target.identifier
            return try main { _ in
                guard let window = Views.editorWindow else { throw ScenarioFailure("No editor window") }
                if let root = window.contentView?.superview,
                   let view = Views.all(NSView.self, in: root)
                   .first(where: { $0.accessibilityIdentifier() == identifier }) {
                    view.scrollToVisible(view.bounds)
                    window.contentView?.layoutSubtreeIfNeeded()
                }
                guard let frame = Views.find(identifier, in: window) else {
                    throw ScenarioFailure("\(identifier) isn't on screen")
                }
                return frame
            }
        }

        /// Whether `target` is on screen now.
        func exists(_ target: Target) throws -> Bool {
            let identifier = target.identifier
            return try main { _ in
                guard let window = Views.editorWindow else { return false }
                return Views.find(identifier, in: window) != nil
            }
        }

        /// Clicks `target` at `point` (0...1 across and down its frame).
        func click(_ target: Target, at point: CGPoint = CGPoint(x: 0.5, y: 0.5), count: Int = 1) throws {
            let frame = try frame(of: target)
            let location = Self.location(point, in: frame)
            for clicks in 1 ... count {
                try mouse([(.leftMouseDown, location, clicks), (.leftMouseUp, location, clicks)])
            }
        }

        /// Drags from `start` (0...1 in the target's frame) by `offset` points, in `steps` moves.
        func drag(
            _ target: Target, from start: CGPoint = CGPoint(x: 0.5, y: 0.5), by offset: CGVector,
            steps: Int = 8, modifiers: NSEvent.ModifierFlags = [],
        ) throws {
            let frame = try frame(of: target)
            let from = Self.location(start, in: frame)
            var events: [(NSEvent.EventType, NSPoint, Int)] = [(.leftMouseDown, from, 1)]
            for step in 1 ... steps {
                let t = Double(step) / Double(steps)
                events.append((.leftMouseDragged, NSPoint(x: from.x + offset.dx * t, y: from.y + offset.dy * t), 1))
            }
            events.append((.leftMouseUp, NSPoint(x: from.x + offset.dx, y: from.y + offset.dy), 1))
            try mouse(events, modifiers: modifiers)
        }

        /// ⌘-scrolls over `target` by `lines`, as a mouse wheel does.
        func scroll(_ target: Target, lines: Int32, modifiers: CGEventFlags = .maskCommand) throws {
            let frame = try frame(of: target)
            let location = Self.location(CGPoint(x: 0.5, y: 0.5), in: frame)
            try main { _ in
                guard let window = Views.editorWindow,
                      let cgEvent = CGEvent(
                          scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0,
                          wheel3: 0,
                      )
                else { return }
                cgEvent.flags = modifiers
                cgEvent.location = window.convertPoint(toScreen: location).flippedOnScreen
                guard let event = NSEvent(cgEvent: cgEvent),
                      let view = window.contentView?.superview?.hitTest(location) else { return }
                view.scrollWheel(with: event)
            }
        }

        /// Window coordinates: y grows upwards; `point.y` 0 is the frame's top.
        private static func location(_ point: CGPoint, in frame: NSRect) -> NSPoint {
            NSPoint(x: frame.minX + frame.width * point.x, y: frame.maxY - frame.height * point.y)
        }

        /// Sends a press, drags and a release through the window, as the mouse does. In a window
        /// that isn't key, AppKit spends the first click on activating it unless the view accepts
        /// first mouse; there the events go to the view under the pointer, as the click after
        /// activation would.
        private func mouse(
            _ events: [(NSEvent.EventType, NSPoint, Int)],
            modifiers: NSEvent.ModifierFlags = [],
        ) throws {
            let pressed = PressedView()
            for (type, location, clicks) in events {
                post { _ in
                    guard let window = Views.editorWindow, let event = NSEvent.mouseEvent(
                        with: type, location: location, modifierFlags: modifiers,
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1,
                    ) else { return }
                    if type == .leftMouseDown {
                        let hit = window.contentView?.superview?.hitTest(location)
                        pressed.view = window.isKeyWindow || hit?.acceptsFirstMouse(for: event) == true ? nil : hit
                    }
                    guard let view = pressed.view else {
                        window.sendEvent(event)
                        return
                    }
                    switch type {
                    case .leftMouseDown: view.mouseDown(with: event)
                    case .leftMouseDragged: view.mouseDragged(with: event)
                    default: view.mouseUp(with: event)
                    }
                }
                pause(type == .leftMouseDragged ? 0.016 : 0.03)
            }
            pause(0.05)
        }
    }

    /// The view a press went to straight, for its drags and release; only touched on main.
    private final class PressedView: @unchecked Sendable {
        var view: NSView?
    }

    extension NSPoint {
        /// From AppKit's screen space (origin bottom left) to Quartz's (origin top left).
        var flippedOnScreen: CGPoint {
            CGPoint(x: x, y: (NSScreen.screens.first?.frame.height ?? 0) - y)
        }
    }

    // MARK: - Sheets

    public extension RunningApp {
        /// Whether a sheet or dialog is up in front of the editor.
        func sheetIsUp() throws -> Bool {
            try main { _ in NSApp.modalWindow != nil || Views.editorWindow?.attachedSheet != nil }
        }

        /// Presses a key in the sheet or dialog in front, as its buttons' keys: Escape for
        /// Cancel, Return for the default button. Returns whether a button took it.
        @discardableResult
        func pressInSheet(_ combo: KeyCombo) throws -> Bool {
            let taken = try main { _ -> Bool in
                guard let sheet = NSApp.modalWindow ?? Views.editorWindow?.attachedSheet else { return false }
                return try sheet.performKeyEquivalent(with: Keyboard.event(combo))
            }
            guard combo.key == .escape else { return taken }
            // Escape is a key event, not a key equivalent: its window turns it into cancelOperation.
            for attempt in 0 ..< 2 where try sheetIsUp() {
                pause(0.2)
                try main { _ in
                    guard let sheet = NSApp.modalWindow ?? Views.editorWindow?.attachedSheet else { return }
                    if attempt == 0 {
                        try sheet.sendEvent(Keyboard.event(combo))
                    } else {
                        let responder = sheet.firstResponder ?? sheet.contentView
                        _ = responder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: nil)
                    }
                }
            }
            pause(0.2)
            return try !sheetIsUp()
        }

        /// Waits for a sheet to come up, as a menu item or key may open one.
        func waitForSheet(_ what: @autoclosure () -> String, timeout: Double = 5) throws {
            let description = what()
            try wait("\(description) to open", timeout: timeout) { _ in
                NSApp.modalWindow != nil || Views.editorWindow?.attachedSheet != nil
            }
        }

        func waitForNoSheet(_ what: @autoclosure () -> String, timeout: Double = 5) throws {
            let description = what()
            try wait("\(description) to close", timeout: timeout) { _ in
                NSApp.modalWindow == nil && Views.editorWindow?.attachedSheet == nil
            }
        }
    }

    // MARK: - Menus

    public extension RunningApp {
        /// The menu item titled `title` (anywhere in the menu bar): whether it's there, and
        /// whether it's enabled once its menu has updated it, as opening the menu does.
        func menuItem(_ title: String) throws -> (found: Bool, enabled: Bool) {
            try main { _ in
                guard let (menu, index) = Menus.find(title) else { return (false, false) }
                Menus.open(menu)
                defer { Menus.close(menu) }
                return (true, menu.items[index].isEnabled)
            }
        }

        /// Chooses the menu item titled `title`, as a click in the menu bar does: its menu
        /// updates first, a disabled item fails, and a dialog it opens doesn't block the driver.
        func choose(_ title: String) throws {
            // SwiftUI updates an item a run-loop turn after the state it reads, so a change made
            // a moment ago may take that long to enable it.
            var ready = false
            for _ in 0 ..< 30 where !ready {
                ready = try main { _ -> Bool in
                    guard let (menu, index) = Menus.find(title) else {
                        throw ScenarioFailure("There's no \(title) menu item")
                    }
                    Menus.open(menu)
                    guard menu.items[index].isEnabled else {
                        Menus.close(menu)
                        return false
                    }
                    return true
                }
                if !ready {
                    pause(0.1)
                }
            }
            guard ready else { throw ScenarioFailure("\(title) is disabled in the menu") }
            post { _ in
                guard let (menu, index) = Menus.find(title) else { return }
                menu.performActionForItem(at: index)
                Menus.close(menu)
            }
            pause(0.05)
        }

        /// Checks that `action`'s menu item carries its key: the registry's character (as the
        /// keyboard layout has it, which SwiftUI adapts) and exactly its modifiers.
        func expectKeyBinding(_ action: ShortcutAction) throws {
            guard let combo = action.combos.first, case let .character(character) = combo.key else {
                throw ScenarioFailure("\(action.title) has no character key")
            }
            let (found, key, mask) = try main { _ -> (Bool, String, NSEvent.ModifierFlags) in
                guard let (menu, index) = Menus.find(Menus.title(of: action)) else { return (false, "", []) }
                let item = menu.items[index]
                return (true, item.keyEquivalent, item.keyEquivalentModifierMask)
            }
            try expect(found, "\(action.title) has no menu item")
            var expected: NSEvent.ModifierFlags = [.command]
            if combo.shift {
                expected.insert(.shift)
            }
            if combo.option {
                expected.insert(.option)
            }
            let modifiers = mask.intersection([.command, .shift, .option, .control])
            try expect(
                modifiers == expected,
                "\(action.title)'s item has modifiers \(modifiers.rawValue), not \(expected.rawValue)",
            )
            let adapted = try main { _ in Keyboard.hasKey(for: character) }
            try expect(
                key.lowercased() == String(character).lowercased() || !adapted,
                "\(action.title)'s item has the key '\(key)', not '\(character)'",
            )
            covered(.action(action), via: .binding)
        }

        /// Chooses `action`'s menu item and waits until the editor ran it, when it goes
        /// through the editor (the app runs a few itself: Open, Export, Film Looks).
        func choose(_ action: ShortcutAction, expectPerformed: Bool = true) throws {
            let mark = try mark()
            try choose(Menus.title(of: action))
            if expectPerformed {
                try self.expectPerformed(action, since: mark)
            }
            covered(.action(action), via: .menu)
        }
    }

    @MainActor
    enum Menus {
        nonisolated static func title(of action: ShortcutAction) -> String {
            action.plannedPhase.map { "\(action.title) (\($0))" } ?? action.title
        }

        /// The item that runs `title`: a leaf, never a menu of the same name (the Edit menu, the
        /// Before / After submenu).
        static func find(_ title: String, in menu: NSMenu? = NSApp.mainMenu) -> (NSMenu, Int)? {
            guard let menu else { return nil }
            for (index, item) in menu.items.enumerated() {
                // Single-key items show their key in the title ("Pick    P").
                if item.submenu == nil, item.title == title || item.title.hasPrefix("\(title)    ") {
                    return (menu, index)
                }
                if let submenu = item.submenu {
                    open(submenu)
                    defer { close(submenu) }
                    if let found = find(title, in: submenu) {
                        return found
                    }
                }
            }
            return nil
        }

        /// What AppKit does as a menu opens: SwiftUI fills in and enables its items then.
        static func open(_ menu: NSMenu) {
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.delegate?.menuWillOpen?(menu)
            menu.update()
        }

        static func close(_ menu: NSMenu) {
            menu.delegate?.menuDidClose?(menu)
        }

        /// Every item in the menu bar, as "Menu › Item", for the coverage report.
        static func allTitles(in menu: NSMenu? = NSApp.mainMenu, path: [String] = []) -> [String] {
            guard let menu else { return [] }
            var titles: [String] = []
            for item in menu.items where !item.isSeparatorItem && !item.title.isEmpty {
                let here = path + [item.title]
                if let submenu = item.submenu {
                    open(submenu)
                    titles += allTitles(in: submenu, path: here)
                    close(submenu)
                } else {
                    titles.append(here.joined(separator: " › "))
                }
            }
            return titles
        }
    }
#endif
