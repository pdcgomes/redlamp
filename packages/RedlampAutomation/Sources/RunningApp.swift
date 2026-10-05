#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import Carbon.HIToolbox
    import RedlampCanvas
    import RedlampDesign
    import RedlampEngineAPI
    @_spi(Harness) import RedlampUI

    /// What a scenario holds: the running app, reached the way a person reaches it.
    ///
    /// Scenarios run on the driver's own thread. Input is posted to the main thread as events
    /// (keys, mouse), menu items or palette keys, never by calling what they would call; the
    /// model is read for checks, and written only to set a scenario up.
    public final class RunningApp: @unchecked Sendable {
        let model: EditorModel
        let recorder: Recorder
        public let photos: URL
        public let runDirectory: URL
        public let allowsFocus: Bool
        public let seed: UInt64
        /// Only the steps whose names contain one of these run (`scripts/e2e.py --step`).
        let steps: [String]
        /// Steps known to fail, by name, with why (`tests/e2e/known-issues.json`): reported, not failed.
        let knownIssues: [String: String]
        let knownStalls: [String: String]
        /// The app's theme and export presets, when it handed them over.
        public let host: AutomationHost?

        init(
            model: EditorModel, recorder: Recorder, photos: URL, runDirectory: URL, allowsFocus: Bool, seed: UInt64,
            steps: [String] = [], knownIssues: [String: String] = [:], knownStalls: [String: String] = [:],
            host: AutomationHost? = nil,
        ) {
            self.model = model
            self.recorder = recorder
            self.photos = photos
            self.runDirectory = runDirectory
            self.allowsFocus = allowsFocus
            self.seed = seed
            self.steps = steps
            self.knownIssues = knownIssues
            self.knownStalls = knownStalls
            self.host = host
        }

        // MARK: - The main thread

        /// Reads (or sets up) the model on the main thread, and waits for it.
        @discardableResult
        public func main<T>(_ work: @escaping @MainActor (EditorModel) throws -> T) throws -> T {
            let model = model
            return try MainThread.run { try work(model) }
        }

        /// Posts work to the main thread without waiting, for input that may open a dialog.
        public func post(_ work: @escaping @MainActor (EditorModel) -> Void) {
            let model = model
            MainThread.post { work(model) }
        }

        // MARK: - Waiting and checking

        public func pause(_ seconds: Double) {
            Thread.sleep(forTimeInterval: seconds)
        }

        /// Waits until `condition` holds, checking every 20 ms.
        public func wait(
            _ what: @autoclosure () -> String, timeout: Double = 10,
            until condition: @escaping @MainActor (EditorModel) -> Bool,
        ) throws {
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                if try main(condition) {
                    return
                }
                if Date() > deadline {
                    throw ScenarioFailure("Timed out after \(timeout) s waiting for \(what())")
                }
                pause(0.02)
            }
        }

        public func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
            if !condition {
                throw ScenarioFailure(message())
            }
        }

        /// The photo is open and rendered, nothing is loading, no dialog is up.
        public func settle(timeout: Double = 30) throws {
            try wait("the photo to open and render", timeout: timeout) { model in
                model.info != nil && !model.isLoading && model.hasFrame && NSApp.modalWindow == nil
            }
            pause(0.15)
        }

        public func frames() throws -> Int {
            try main { $0.debugFrameCount }
        }

        /// Waits for a frame newer than `count`: the change reached the engine and came back.
        public func expectRendered(after count: Int, _ what: @autoclosure () -> String, timeout: Double = 10) throws {
            try wait("a frame after \(what())", timeout: timeout) { $0.debugFrameCount > count }
        }

        public func value(_ parameter: ParameterID) throws -> Double {
            try main { $0.sliderValue(parameter) }
        }

        /// Where the activity log stands, so a check can ask what happened since. The log keeps
        /// its last 500 events, so the mark is the newest event's time and repeats, not a count.
        public struct Mark: Sendable {
            let time: Date
            let text: String
            let repeats: Int
        }

        public func mark() throws -> Mark {
            try main { model in
                let last = model.activity.events.last
                return Mark(time: last?.time ?? .distantPast, text: last?.text ?? "", repeats: last?.count ?? 0)
            }
        }

        /// Events the activity log recorded since `mark`, a repeat of the last one included.
        public func activity(since mark: Mark) throws -> [ActivityLog.Event] {
            try main { model in
                model.activity.events.filter { event in
                    event.time > mark
                        .time || (event.time == mark.time && event.text == mark.text && event.count > mark.repeats)
                }
            }
        }

        /// Waits until `perform` ran `action`: the activity log records every action it runs.
        public func expectPerformed(_ action: ShortcutAction, since mark: Mark, timeout: Double = 5) throws {
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                if try activity(since: mark).contains(where: { $0.kind == .action && $0.text == action.title }) {
                    return
                }
                if Date() > deadline {
                    throw ScenarioFailure("\(action.title) didn't reach the editor within \(timeout) s")
                }
                pause(0.02)
            }
        }

        /// Fails if the activity log shows an error since `mark`.
        public func expectNoErrors(since mark: Mark) throws {
            let errors = try activity(since: mark).filter { $0.kind == .error }
            try expect(errors.isEmpty, "Errors shown: \(errors.map(\.text).joined(separator: "; "))")
        }

        // MARK: - Coverage

        /// Records that `claim` was exercised through `path`.
        public func covered(_ claim: Claim, via path: InputPath) {
            recorder.cover(claim, via: path)
        }

        public func covered(_ claims: [Claim], via path: InputPath) {
            claims.forEach { covered($0, via: path) }
        }

        /// Takes the app's focus for steps that need a key window, when the run allows it.
        public func focus() throws -> Bool {
            guard allowsFocus else { return false }
            try main { _ in
                NSApp.activate()
                EditorWindowController.frontWindow?.makeKeyAndOrderFront(nil)
            }
            try wait("the editor window to become key", timeout: 5) { _ in
                EditorWindowController.frontWindow?.isKeyWindow == true
            }
            return true
        }
    }

    // MARK: - Keys

    public extension RunningApp {
        /// Types `combo` as a key press, through the app's event dispatch: the Develop key monitor
        /// and the menus' key equivalents see it as they see the keyboard's.
        func press(_ combo: KeyCombo) throws {
            let event = try main { _ in try Keyboard.event(combo) }
            post { _ in NSApp.sendEvent(event) }
            pause(0.05)
        }

        /// Presses `action`'s first key and waits until the editor ran it.
        ///
        /// A ⌘ key is a menu's key equivalent. SwiftUI brings its menu items' enabled state up
        /// to date as their menu opens, so the item's menu is updated first, as it would be
        /// once it had been opened; the key then goes through AppKit's own matching.
        func press(_ action: ShortcutAction, shift: Bool = false, expectPerformed: Bool = true) throws {
            guard var combo = action.combos.first else {
                throw ScenarioFailure("\(action.title) has no key")
            }
            if shift {
                combo.shift = true
            }
            if !combo.command, case let .character(character) = combo.key,
               try !main({ _ in Keyboard.hasKey(for: character) }) {
                throw ScenarioSkip("this Mac's keyboard layout has no key that types \(character) by itself")
            }
            let menu = combo.command ? try main { _ -> NSMenu? in
                guard let (menu, _) = Menus.find(Menus.title(of: action)) else { return nil }
                Menus.open(menu)
                return menu
            } : nil
            // The key the menu shows: SwiftUI adapts key equivalents to the keyboard layout
            // (⌘= is ⌘* on a Portuguese one).
            if combo.command, let shown = try main({ _ -> Character? in
                guard let (menu, index) = Menus.find(Menus.title(of: action)) else { return nil }
                return menu.items[index].keyEquivalent.first
            }), case let .character(character) = combo.key, shown != character {
                combo.key = .character(shown)
            }
            let mark = try mark()
            try press(combo)
            if let menu = MenuBox(menu) {
                post { _ in Menus.close(menu.menu) }
            }
            if expectPerformed {
                try self.expectPerformed(action, since: mark)
            }
            covered(.action(action), via: .key)
        }

        /// Types text into the editor window's first responder (a value field being edited, the
        /// palette's field), as keys reach a window that has focus.
        func type(_ text: String) throws {
            for character in text {
                try pressInWindow(KeyCombo(.character(character)))
            }
        }

        /// Sends a key straight to the editor window, past the Develop key monitor: what a key
        /// does in a text field.
        func pressInWindow(_ combo: KeyCombo) throws {
            let event = try main { _ in try Keyboard.event(combo) }
            post { _ in Views.editorWindow?.sendEvent(event) }
            pause(0.03)
        }
    }

    /// A menu carried to the driver's thread and back; only touched on main.
    final class MenuBox: @unchecked Sendable {
        let menu: NSMenu
        init?(_ menu: NSMenu?) {
            guard let menu else { return nil }
            self.menu = menu
        }
    }

    @MainActor
    enum Keyboard {
        /// Key codes by the character they type in the current keyboard layout.
        private static let codes: [Character: UInt16] = {
            var codes: [Character: UInt16] = [:]
            for code in UInt16(0) ..< 128 {
                guard let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                    context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code,
                ), let characters = event.characters(byApplyingModifiers: []), characters.count == 1,
                let character = characters.first, codes[character] == nil
                else { continue }
                codes[character] = code
            }
            return codes
        }()

        static func hasKey(for character: Character) -> Bool {
            codes[character] != nil || codes[Character(character.lowercased())] != nil
        }

        static func event(_ combo: KeyCombo) throws -> NSEvent {
            var flags: NSEvent.ModifierFlags = []
            if combo.shift {
                flags.insert(.shift)
            }
            if combo.option {
                flags.insert(.option)
            }
            if combo.command {
                flags.insert(.command)
            }
            let code: UInt16
            var characters: String
            switch combo.key {
            case .tab: (code, characters) = (UInt16(kVK_Tab), "\t")
            case .escape: (code, characters) = (UInt16(kVK_Escape), "\u{1B}")
            case .delete: (code, characters) = (UInt16(kVK_Delete), "\u{7F}")
            case .space: (code, characters) = (UInt16(kVK_Space), " ")
            case .left: (code, characters) = (UInt16(kVK_LeftArrow), String(UnicodeScalar(NSLeftArrowFunctionKey)!))
            case .right: (code, characters) = (UInt16(kVK_RightArrow), String(UnicodeScalar(NSRightArrowFunctionKey)!))
            case .up: (code, characters) = (UInt16(kVK_UpArrow), String(UnicodeScalar(NSUpArrowFunctionKey)!))
            case .down: (code, characters) = (UInt16(kVK_DownArrow), String(UnicodeScalar(NSDownArrowFunctionKey)!))
            case let .function(number):
                let functionCodes = [5: kVK_F5, 6: kVK_F6, 7: kVK_F7, 8: kVK_F8]
                guard let function = functionCodes[number] else { throw ScenarioFailure("No key code for F\(number)") }
                code = UInt16(function)
                characters = String(UnicodeScalar(NSF1FunctionKey + number - 1)!)
            case let .character(character):
                guard let found = codes[character] ?? codes[Character(character.lowercased())] else {
                    throw ScenarioFailure("The keyboard layout has no key for \(character)")
                }
                code = found
                characters = String(character)
            }
            if combo.key.isFunctionKey {
                flags.insert(.function)
            }
            // As AppKit's own events have them: Shift changes `characters`, not the unshifted key.
            let unshifted = characters
            if combo.shift, case .character = combo.key {
                characters = characters.uppercased()
            }
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: EditorWindowController.frontWindow?.windowNumber ?? 0, context: nil,
                characters: characters, charactersIgnoringModifiers: unshifted, isARepeat: false, keyCode: code,
            ) else {
                throw ScenarioFailure("Couldn't make a key event for \(combo.display)")
            }
            return event
        }
    }

    extension KeyCombo.Key {
        var isFunctionKey: Bool {
            switch self {
            case .left, .right, .up, .down, .function: true
            default: false
            }
        }
    }
#endif
