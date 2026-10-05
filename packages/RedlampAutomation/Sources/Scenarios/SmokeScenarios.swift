#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import ImageIO
    import RedlampDesign
    import RedlampEngineAPI
    @_spi(Harness) import RedlampUI

    extension RunningApp {
        /// Runs `body` for each item, recording each as a step, and fails at the end with every
        /// item that failed, so one broken action doesn't hide the rest.
        func checkEach<T>(_ items: [T], _ name: (T) -> String, _ body: (T) throws -> Void) throws {
            var failures: [String] = []
            var skipped = 0
            for item in items where steps.isEmpty || steps.contains(where: name(item).contains) {
                let started = Date()
                let known = knownIssues[name(item)]
                do {
                    try body(item)
                    if let known {
                        recorder.write(
                            "step",
                            ["name": name(item), "status": "fixed", "message": "known issue now passes: \(known)"],
                        )
                    } else {
                        recorder.write(
                            "step",
                            ["name": name(item), "status": "passed", "seconds": Date().timeIntervalSince(started)],
                        )
                    }
                } catch let skip as ScenarioSkip {
                    skipped += 1
                    recorder.write("step", ["name": name(item), "status": "skipped", "message": skip.reason])
                } catch {
                    if let known {
                        recorder.write(
                            "step",
                            ["name": name(item), "status": "known-issue", "message": "\(error) (known: \(known))"],
                        )
                    } else {
                        failures.append("\(name(item)): \(error)")
                        recorder.write("step", ["name": name(item), "status": "failed", "message": "\(error)"])
                    }
                    recover()
                    try? settle()
                }
            }
            if !failures.isEmpty {
                throw ScenarioFailure("\(failures.count) of \(items.count) failed: " + failures
                    .joined(separator: " | "))
            }
        }

        /// The photos in the run's folder, in the filmstrip's order.
        func photoNames() throws -> [String] {
            try main { $0.items.map(\.url.lastPathComponent) }
        }

        /// The photo actions and sliders are checked on: a raw, so white balance applies.
        func workingPhoto() throws -> String {
            try wait("the folder's photos", timeout: 30) { !$0.items.isEmpty }
            let names = try photoNames()
            guard let name = names.first(where: { $0.hasSuffix(".ARW") }) ?? names
                .first(where: { !$0.hasPrefix("Bitmap") })
                ?? names.first
            else { throw ScenarioFailure("The folder has no photos") }
            return name
        }

        /// Opens `name` by clicking its filmstrip cell, and waits until it has rendered.
        func open(_ name: String, byKeys: Bool = false) throws {
            if try main({ $0.selection?.lastPathComponent }) == name {
                return
            }
            if try exists(.filmstrip(name)) {
                try click(.filmstrip(name))
                covered(.feature("library.filmstrip"), via: .mouse)
            } else if !byKeys {
                // The filmstrip slides in only under the pointer: choosing the photo as a click would.
                guard let url = try main({ model in model.items.first { $0.url.lastPathComponent == name }?.url })
                else {
                    throw ScenarioFailure("\(name) isn't in the filmstrip")
                }
                try main { $0.select(url) }
                covered(.feature("library.filmstrip"), via: .model)
            } else {
                // ← and → step through the filmstrip.
                let (target, current) = try main { model -> (Int?, Int?) in
                    let names = model.items.map(\.url.lastPathComponent)
                    return (
                        names.firstIndex(of: name),
                        model.selection.flatMap { names.firstIndex(of: $0.lastPathComponent) },
                    )
                }
                guard let target else { throw ScenarioFailure("\(name) isn't in the filmstrip") }
                var index = current ?? 0
                while index != target {
                    try press(index < target ? .nextPhoto : .previousPhoto, expectPerformed: false)
                    index += index < target ? 1 : -1
                }
            }
            try wait("\(name) to be selected") { $0.selection?.lastPathComponent == name }
            try settle()
        }
    }

    enum SmokeScenarios {
        /// Leaving an edit is last in its launch, so the relaunch finds the photo it was left on.
        static let all: [Scenario] = [
            photos,
            actionsByKey,
            actionsByMenu,
            panelSliders,
            export,
            identifiers,
            keyEquivalents,
        ]
        static let last: [Scenario] = [leaveAnEdit, relaunch]

        /// Not in any tier: each ⌘ action's menu item, its key equivalent, and whether AppKit's
        /// matching takes the driver's event for it.
        static let keyEquivalents = Scenario(
            "diagnostics.key-equivalents", "Lists the menu bar's key equivalents", tiers: [], claims: [],
        ) { app in
            let lines = try app.main { _ -> [String] in
                ShortcutAction.allCases.filter { $0.combos.first?.command == true }.map { action in
                    guard let combo = action.combos.first,
                          let (menu, index) = Menus.find(Menus.title(of: action)) else {
                        return "\(action.rawValue): no item"
                    }
                    Menus.open(menu)
                    defer { Menus.close(menu) }
                    let item = menu.items[index]
                    let event = try? Keyboard.event(combo)
                    let chars = event
                        .map { "\($0.characters ?? "")|\($0.charactersIgnoringModifiers ?? "")|\($0.keyCode)" } ?? "-"
                    return "\(action.rawValue): item '\(item.keyEquivalent)' mask \(item.keyEquivalentModifierMask.rawValue) enabled \(item.isEnabled); event \(chars) flags \(event?.modifierFlags.rawValue ?? 0)"
                }
            }
            let everything = try app.main { _ -> [String] in
                @MainActor func walk(_ menu: NSMenu, _ path: String) -> [String] {
                    Menus.open(menu)
                    defer { Menus.close(menu) }
                    return menu.items.flatMap { item -> [String] in
                        let here = "\(path) › \(item.title)"
                        if let submenu = item.submenu {
                            return walk(submenu, here)
                        }
                        guard !item.keyEquivalent.isEmpty else { return [] }
                        return [
                            "\(item.keyEquivalentModifierMask.rawValue) '\(item.keyEquivalent)' \(here) enabled=\(item.isEnabled)",
                        ]
                    }
                }
                return NSApp.mainMenu.map { walk($0, "") } ?? []
            }
            var trials: [String] = []
            for (characters, ignoring) in [("a", "a"), ("å", "a"), ("A", "a"), ("a", "A")] {
                let result = try app.main { model -> String in
                    model.deselectOtherPhotos()
                    guard let (menu, _) = Menus.find(Menus.title(of: .selectAllPhotos)) else { return "no item" }
                    Menus.open(menu)
                    defer { Menus.close(menu) }
                    guard let event = NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0,
                        windowNumber: Views.editorWindow?.windowNumber ?? 0, context: nil, characters: characters,
                        charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: 0,
                    ) else { return "no event" }
                    let taken = NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
                    return "taken=\(taken) selected=\(model.selectedPhotos.count)"
                }
                app.pause(0.3)
                let after = try app.main { "\($0.selectedPhotos.count)" }
                trials.append("⌥⌘A chars '\(characters)' ignoring '\(ignoring)': \(result), then \(after)")
            }
            for wait in [0.2, 1.0] {
                try app.main { model in
                    model.deselectOtherPhotos()
                    if let (menu, _) = Menus.find(Menus.title(of: .selectAllPhotos)) {
                        Menus.open(menu)
                    }
                }
                app.pause(wait)
                let taken = try app.main { _ -> Bool in
                    guard let event = NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0,
                        windowNumber: Views.editorWindow?.windowNumber ?? 0, context: nil, characters: "å",
                        charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0,
                    ) else { return false }
                    return NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
                }
                app.pause(0.3)
                try trials
                    .append(
                        "⌥⌘A \(wait) s after the update: taken=\(taken), then \(app.main { "\($0.selectedPhotos.count)" })",
                    )
                try app
                    .main { _ in
                        if let (menu, _) = Menus.find(Menus.title(of: .selectAllPhotos)) {
                            Menus.close(menu)
                        }
                    }
            }
            let viaItem = try app.main { model -> String in
                model.deselectOtherPhotos()
                guard let (menu, index) = Menus.find(Menus.title(of: .selectAllPhotos)) else { return "no item" }
                Menus.open(menu)
                defer { Menus.close(menu) }
                menu.performActionForItem(at: index)
                return "selected=\(model.selectedPhotos.count)"
            }
            app.pause(0.3)
            try trials
                .append(
                    "⌥⌘A by performActionForItem: \(viaItem), then \(app.main { "\($0.selectedPhotos.count)" })",
                )
            if try app.focus() {
                try app.main { $0.deselectOtherPhotos() }
                try app.press(KeyCombo(.character("a"), option: true, command: true))
                app.pause(0.5)
                try trials
                    .append("⌥⌘A with focus, through NSApp.sendEvent: \(app.main { "\($0.selectedPhotos.count)" })")
                try app.main { $0.deselectOtherPhotos() }
                try app.press(KeyCombo(.character("c"), shift: true, command: true))
                app.pause(0.8)
                try trials.append("⇧⌘C with focus: chooser=\(app.main { "\($0.settingsChooser != nil)" })")
            }
            try (lines + ["", "Trials:"] + trials + ["", "All:"] + everything).joined(separator: "\n").write(
                to: app.runDirectory.appending(path: "key-equivalents.txt"), atomically: true, encoding: .utf8,
            )
        }

        /// Not in any tier: lists every identifier on screen, for writing scenarios
        /// (`scripts/e2e.py --scenario diagnostics.identifiers`).
        static let identifiers = Scenario(
            "diagnostics.identifiers", "Lists the identifiers on screen", tiers: [], claims: [],
        ) { app in
            let found = try app.main { _ -> [String] in
                guard let window = Views.editorWindow, let root = window.contentView?.superview else { return [] }
                return Views.all(NSView.self, in: root).compactMap { view in
                    let identifier = view.accessibilityIdentifier()
                    guard !identifier.isEmpty || "\(type(of: view))".contains("Filmstrip") || view is NSCollectionView
                    else { return nil }
                    let frame = view.convert(view.bounds, to: nil)
                    return "\(identifier) \(type(of: view)) \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height)) hidden=\(view.isHiddenOrHasHiddenAncestor)"
                }
            }
            try found.joined(separator: "\n").write(
                to: app.runDirectory.appending(path: "identifiers.txt"), atomically: true, encoding: .utf8,
            )
        }

        static let photos = Scenario(
            "smoke.photos-open", "Every photo in the folder opens from the filmstrip and renders",
            tiers: [.smoke, .full],
            claims: [.feature("library.filmstrip"), .feature("raw.phone"), .feature("raw.bitmap")],
        ) { app in
            let names = try app.photoNames()
            try app.expect(names.count >= 6, "The filmstrip lists \(names.count) photos")
            try app.checkEach(names, { "open \($0)" }) { name in
                let mark = try app.mark()
                try app.open(name, byKeys: true)
                try app.expectNoErrors(since: mark)
                let error = try app.main { $0.errorMessage }
                try app.expect(error == nil, "\(name) shows \(error ?? "")")
                let lower = name.lowercased()
                if lower.hasSuffix(".dng") {
                    app.covered(.feature("raw.phone"), via: .mouse)
                } else if [".jpg", ".png", ".tif", ".heic"].contains(where: lower.hasSuffix) {
                    app.covered(.feature("raw.bitmap"), via: .mouse)
                }
            }
            try app.open(names[0])
        }

        static let actionsByKey = Scenario(
            "smoke.actions-by-key", "Every action with a key runs from its key, and does what it says",
            tiers: [.smoke, .full], claims: ShortcutAction.allCases.map(Claim.action),
        ) { app in
            let first = try app.workingPhoto()
            try app.open(first)
            let checks = ActionCheck.all.filter { !$0.action.combos.isEmpty }
            try app.checkEach(checks, { "\($0.action.rawValue) by key" }) { check in
                try check.run(app, via: .key)
                try app.open(first)
            }
        }

        static let actionsByMenu = Scenario(
            "smoke.actions-by-menu", "Every action in the menu bar runs from its menu item",
            tiers: [.smoke, .full], claims: ShortcutAction.allCases.map(Claim.action),
        ) { app in
            let first = try app.workingPhoto()
            try app.open(first)
            let checks = try ActionCheck.all.filter { check in
                try app.main { _ in Menus.find(Menus.title(of: check.action)) != nil }
            }
            try app.expect(checks.count > 40, "Only \(checks.count) actions have a menu item")
            try app.checkEach(checks, { "\($0.action.rawValue) by menu" }) { check in
                if check.action == .virtualCopy {
                    let item = try app.menuItem(Menus.title(of: .virtualCopy))
                    try app.expect(item.found && !item.enabled, "Virtual Copy's planned item should be disabled")
                    app.covered(.action(.virtualCopy), via: .menu)
                    return
                }
                try check.run(app, via: .menu)
                try app.open(first)
            }
        }

        static let panelSliders = Scenario(
            "smoke.panel-sliders", "Every slider in the Develop panels moves by dragging and resets by double-clicking",
            tiers: [.smoke, .full],
            claims: PanelID.allCases.map(Claim.panel) + PanelID.allCases.flatMap(\.parameters).map(Claim.parameter),
        ) { app in
            try app.open(app.workingPhoto())
            try app.main { $0.expandedPanels = Set(PanelID.allCases) }
            app.pause(0.3)
            var missing: [ParameterID] = []
            for panel in PanelID.allCases {
                app.covered(.panel(panel), via: .mouse)
                try app.checkEach(panel.parameters, { "\($0.rawValue)" }) { parameter in
                    guard try app.exists(.slider(parameter)) else {
                        missing.append(parameter)
                        return
                    }
                    try dragAndReset(parameter, app: app)
                }
            }
            if !missing.isEmpty {
                app.recorder.write("note", ["sliders-not-on-screen": missing.map(\.rawValue)])
            }
        }

        /// Drags a slider's track, checks the value and the history moved and a frame came
        /// back, then double-clicks the label and checks it's back at its default.
        static func dragAndReset(_ parameter: ParameterID, app: RunningApp) throws {
            let spec = parameter.spec
            let before = try app.value(parameter)
            let step = try app.main { "\($0.historyIndex) \($0.history.last?.id.uuidString ?? "")" }
            let frames = try app.frames()
            let atTop = spec.position(for: before) > 0.8
            try app.drag(
                .slider(parameter),
                from: CGPoint(x: atTop ? 0.3 : 0.7, y: 0.5),
                by: CGVector(dx: atTop ? -20 : 20, dy: 0),
            )
            try app.wait("\(spec.label) to move from \(spec.formatted(before))") { $0.sliderValue(parameter) != before }
            try app
                .wait("a history step for \(spec.label)") {
                    step != "\($0.historyIndex) \($0.history.last?.id.uuidString ?? "")"
                }
            try app.expectRendered(after: frames, "dragging \(spec.label)")
            try app.click(.sliderLabel(parameter), count: 2)
            // Reset is the photo's own default: As Shot for white balance.
            try app.wait("\(spec.label) to reset") { model in
                parameter.isMaskScoped || parameter.isSpotScoped || parameter.isPointColorScoped
                    ? abs(model.sliderValue(parameter) - spec.defaultValue) < 1e-9 : !model.isEdited(parameter)
            }
            app.covered(.parameter(parameter), via: .mouse)
        }

        static let export = Scenario(
            "smoke.export", "The Export dialog exports the photo next to it",
            tiers: [.smoke, .full], claims: [.action(.export), .feature("export.dialog")],
        ) { app in
            let name = try app.workingPhoto()
            try app.open(name)
            let folder = app.photos
            let before = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            try app.choose(Menus.title(of: .export))
            try app.waitForSheet("the Export dialog")
            try app.expect(
                try app.pressInSheet(KeyCombo(.character("\r"))),
                "The Export dialog's Export button didn't take Return",
            )
            @Sendable func newFile() -> String? {
                let now = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                return now.subtracting(before).first { !$0.hasPrefix(".") && !$0.hasSuffix(".redlamp") }
            }
            try app.wait("the exported file", timeout: 60) { _ in newFile() != nil }
            guard let exported = newFile() else { return }
            let url = folder.appending(path: exported)
            try app.wait("\(exported) to be complete", timeout: 30) { _ in
                CGImageSourceCreateWithURL(url as CFURL, nil)
                    .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } != nil
            }
            app.covered([.action(.export), .feature("export.dialog")], via: .menu)
            try? FileManager.default.removeItem(at: url)
            try app.wait("\(exported) to leave the filmstrip", timeout: 20) { model in
                !model.items.contains { $0.url.lastPathComponent == exported }
            }
        }

        /// What the relaunch should find: written by the main launch, read by the next.
        struct Left: Codable {
            var photo: String
            var exposure: Double
        }

        static let leaveAnEdit = Scenario(
            "smoke.leave-an-edit", "A typed value is saved to the photo's sidecar",
            tiers: [.smoke, .full], claims: [.feature("saving.sidecars"), .feature("workspace.sliders")],
        ) { app in
            let raws = ["arw", "raf", "cr3", "nef", "dng"]
            let names = try app.photoNames().filter { raws.contains(($0 as NSString).pathExtension.lowercased()) }
            let name = names[min(2, names.count - 1)]
            try app.open(name)
            try app.main { $0.expandedPanels.insert(.basic) }
            app.pause(0.3)
            try app.click(.sliderValue(.exposure))
            try app.wait("the value field to take typing") { _ in Views.editorWindow?.firstResponder is NSTextView }
            try app.type("0.77")
            try app.pressInWindow(KeyCombo(.character("\r")))
            try app.wait("Exposure to be 0.77") { abs($0.value(.exposure) - 0.77) < 1e-6 }
            let sidecar = app.photos.appending(path: "\(name).redlamp")
            try app.wait("the sidecar to be written", timeout: 10) { _ in
                FileManager.default.fileExists(atPath: sidecar.appending(path: "edit.json").path)
            }
            let data = try JSONEncoder().encode(Left(photo: name, exposure: 0.77))
            try data.write(to: app.runDirectory.appending(path: "left.json"))
            app.covered([.feature("saving.sidecars"), .feature("workspace.sliders")], via: .key)
        }

        static let relaunch = Scenario(
            "smoke.relaunch-restores", "Reopened, Redlamp restores the folder, the photo and its edit",
            tiers: [.smoke, .full], group: .relaunch,
            claims: [.feature("library.folders"), .feature("history.sessions")],
        ) { app in
            let left = try JSONDecoder().decode(
                Left.self,
                from: Data(contentsOf: app.runDirectory.appending(path: "left.json")),
            )
            try app.wait("the folder to be restored", timeout: 30) { $0.folder != nil && !$0.items.isEmpty }
            try app.wait("\(left.photo) to reopen", timeout: 30) { $0.selection?.lastPathComponent == left.photo }
            try app.settle()
            let exposure = try app.value(.exposure)
            try app.expect(
                abs(exposure - left.exposure) < 1e-6,
                "Exposure reopened at \(exposure), not \(left.exposure)",
            )
            try app.wait("the earlier session in History") { !$0.earlierSessions.isEmpty }
            app.covered([.feature("library.folders"), .feature("history.sessions")], via: .model)
        }
    }
#endif
