#if DEBUG || REDLAMP_PROFILING
    import AppKit
    @_spi(Harness) import RedlampUI

    /// A run kept apart from the Mac it runs on (ARC-07): input made outside the app's process reaches none of its
    /// handlers, whichever of them was installed first (`ForeignInput`).
    enum ForeignInputScenarios {
        static let all: [Scenario] = [keysKeptOut]

        /// P (Flag as Pick), L (Cycle Lights Out), Option (the panels' Reset titles) and ⌘1 (the Basic panel, through
        /// the menu bar), pressed and let go as the Mac's keyboard sends them and dispatched as the app dispatches any
        /// event: none acts, and the run's events name each.
        static let keysKeptOut = Scenario(
            "driver.foreign-keys", "Keys typed on the Mac reach none of the app's shortcuts, the menu bar's included",
            tiers: [.smoke, .full], claims: [],
        ) { app in
            try app.open(app.workingPhoto())
            let state = { @MainActor (model: EditorModel) in
                "lights out \(model.lightsOut), panels \(model.expandedPanels.map(\.rawValue).sorted()), "
                    + "option \(model.optionKeyHeld)"
            }
            let before = try app.main(state)
            let recorded = try records(in: app)
            let mark = try app.mark()
            let sent = try app.main { _ -> Int in
                let typed = try keys()
                ForeignInput.madeHere {
                    for event in typed {
                        NSApp.sendEvent(event)
                    }
                }
                return typed.count
            }
            app.pause(0.3)
            let acted = try app.activity(since: mark).filter { $0.kind == .action }.map(\.text)
            try app.expect(acted.isEmpty, "Keys from outside the app ran \(acted)")
            let after = try app.main(state)
            try app.expect(after == before, "Keys from outside the app changed \(before) to \(after)")
            let named = try records(in: app) - recorded
            try app.expect(named == sent, "The run's events name \(named) of \(sent) foreign keys")
        }

        /// Each key down and up, and Option pressed and let go, as made outside the app's process.
        private static func keys() throws -> [NSEvent] {
            func key(_ code: CGKeyCode, _ character: String, down: Bool, command: Bool = false) throws -> NSEvent {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else {
                    throw ScenarioFailure("No key event for \(character)")
                }
                event.keyboardSetUnicodeString(stringLength: 1, unicodeString: Array(character.utf16))
                event.flags = command ? .maskCommand : []
                return try foreign(event)
            }
            func option(_ held: Bool) throws -> NSEvent {
                guard let event = CGEvent(source: nil) else { throw ScenarioFailure("No event for Option") }
                event.type = .flagsChanged
                event.flags = held ? .maskAlternate : []
                return try foreign(event)
            }
            return try [
                key(35, "p", down: true), key(35, "p", down: false), key(37, "l", down: true), key(
                    37,
                    "l",
                    down: false,
                ),
                option(true), option(false), key(18, "1", down: true, command: true),
                key(18, "1", down: false, command: true),
            ]
        }

        private static func foreign(_ event: CGEvent) throws -> NSEvent {
            event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
            guard let made = NSEvent(cgEvent: event) else { throw ScenarioFailure("No event from \(event)") }
            return made
        }

        /// How many of the keys this scenario made the run's events name so far.
        private static func records(in app: RunningApp) throws -> Int {
            let files = try FileManager.default.contentsOfDirectory(
                at: app.runDirectory,
                includingPropertiesForKeys: nil,
            )
            .filter { $0.lastPathComponent.hasPrefix("events-") }
            return try files.reduce(0) { count, file in
                try count + String(contentsOf: file, encoding: .utf8).split(separator: "\n")
                    .count(where: { $0.contains("\"foreign-input-made\"") })
            }
        }
    }
#endif
