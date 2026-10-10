#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import RedlampDocument
    import RedlampEngineAPI
    @_spi(Harness) import RedlampUI

    enum StackScenarios {
        static let all: [Scenario] = [detectAndMerge]

        static let detectAndMerge = Scenario(
            "stack.detect-merge-workspace",
            "A focus bracket is found and its frames marked in the filmstrip, merged from the menu, and worked in the "
                + "Stack workspace",
            claims: [
                .feature("focus-stacking.detection"),
                .feature("focus-stacking.merging"),
                .feature("focus-stacking.workspace"),
                .feature("focus-stacking.depth-map"),
                .feature("focus-stacking.alignment"),
                .action(.mergeFocusStack),
                .action(.editFocusStack),
            ],
        ) { app in
            let bracket = app.photos.appending(path: "Bracket")
            guard FileManager.default.fileExists(atPath: bracket.path) else {
                throw ScenarioSkip("The run has no focus bracket (scripts/make-focus-bracket.swift)")
            }
            // A stack document already covering the frames (an earlier attempt's) stops them being offered.
            for file in (try? FileManager.default.contentsOfDirectory(atPath: bracket.path)) ?? []
                where file.hasSuffix(".redlampstack") {
                try? FileManager.default.removeItem(at: bracket.appending(path: file))
            }
            try app.main { $0.open([bracket]) }
            try app
                .wait("the bracket's folder", timeout: 30) {
                    $0.folder?.standardizedFileURL == bracket.standardizedFileURL
                }
            try app.settle()
            try app.wait("the stack to be found", timeout: 120) { !$0.stackSuggestions.isEmpty }
            // Its frames marked in the filmstrip, as VoiceOver reads them, the strip kept up past the 5 s it shows for.
            let frames = try app.main { model in
                model.applyDebugCommand("filmstrip", "shown")
                return model.stackSuggestions.first?.frames.map(\.lastPathComponent) ?? []
            }
            do {
                defer { try? app.main { $0.applyDebugCommand("filmstrip", "hidden") } }
                try app.wait("the filmstrip to mark the bracket's frames", timeout: 10) { _ in
                    guard let window = Views.editorWindow else { return false }
                    return frames.allSatisfy { name in
                        Views.accessible("filmstrip.\(name)", in: window)?.accessibilityValue() as? String
                            == "suggested for a focus stack"
                    }
                }
            }
            app.covered(.feature("focus-stacking.detection"), via: .model)
            // Merge writes the stack document and opens the Stack workspace on it.
            try app.choose(.mergeFocusStack, expectPerformed: false)
            try app.wait("the Stack workspace", timeout: 60) { $0.stackWorkspace != nil }
            app.covered(
                [.feature("focus-stacking.merging"), .feature("focus-stacking.alignment"), .action(.mergeFocusStack)],
                via: .menu,
            )
            try app.wait("the merge's preview", timeout: 240) { model in
                model.stackWorkspace.map { $0.preview != nil && !$0.isMerging } ?? false
            }
            for strategy in FocusStackStrategy.allCases {
                try app.run("the \(strategy) method", timeout: 300) { model in
                    model.stackWorkspace?.strategy = strategy
                    await model.stackWorkspace?.merge()
                }
            }
            try app.main { $0.stackWorkspace?.showsDepth = true }
            app.covered(.feature("focus-stacking.depth-map"), via: .model)
            try app.main { $0.stackWorkspace?.showsDepth = false }
            try app.main { $0.stackWorkspace?.isRetouching = true }
            try app.run("a retouch stroke", timeout: 120) { model in
                await model.stackWorkspace?.addStroke((0 ... 10).map { CGPoint(x: 0.3 + 0.02 * Double($0), y: 0.4) })
            }
            let strokes = try app.main { $0.stackWorkspace?.strokes.count ?? 0 }
            try app.expect(strokes > 0, "The retouch stroke wasn't kept")
            try app.main { $0.finishStackWorkspace() }
            try app.wait("the editor back", timeout: 60) { $0.stackWorkspace == nil }
            // Edit Focus Stack opens it again from the stack document.
            let stack = try app.main { $0.items.first { SupportedFormats.isStack($0.url) }?.url }
            guard let stack else { throw ScenarioFailure("No stack document beside the frames") }
            try app.main { $0.select(stack) }
            try app.settle(timeout: 120)
            try app.choose(.editFocusStack, expectPerformed: false)
            try app.wait("the Stack workspace again", timeout: 60) { $0.stackWorkspace != nil }
            app.covered(.action(.editFocusStack), via: .menu)
            try app.main { $0.finishStackWorkspace() }
            try app.wait("the editor back", timeout: 60) { $0.stackWorkspace == nil }
            try app.main { $0.open([app.photos]) }
            try app
                .wait("the photos folder again", timeout: 30) {
                    $0.folder?.standardizedFileURL == app.photos.standardizedFileURL
                }
            try app.openWorking()
            app.covered(.feature("focus-stacking.workspace"), via: .model)
        }
    }

    enum RawScenarios {
        static let all: [Scenario] = [damaged]

        static let damaged = Scenario(
            "raw.damaged", "A damaged raw shows why it won't open, and the editor carries on",
            claims: [.feature("raw.wont-open")],
        ) { app in
            let folder = app.photos.appending(path: "Damaged")
            let photo = folder.appending(path: "Damaged.NEF")
            guard FileManager.default.fileExists(atPath: photo.path) else {
                throw ScenarioSkip("The run has no damaged raw")
            }
            try app.main { $0.open([photo]) }
            try app.wait("the damaged photo's message", timeout: 60) { model in
                model.selection?.lastPathComponent == "Damaged.NEF" && !model.isLoading && model.errorMessage != nil
            }
            try app.main { $0.open([app.photos]) }
            try app
                .wait("the photos folder again", timeout: 30) {
                    $0.folder?.standardizedFileURL == app.photos.standardizedFileURL
                }
            try app.openWorking()
            let error = try app.main { $0.errorMessage }
            try app.expect(error == nil, "A good photo after the damaged one shows \(error ?? "")")
            app.covered(.feature("raw.wont-open"), via: .model)
        }
    }

    enum FeedbackScenarios {
        static let all: [Scenario] = [reportABug, yourReports, cameraBench]

        static let reportABug = Scenario(
            "feedback.report-a-bug",
            "Report a Bug opens from the menu, suggests the area in use, and sends nothing private to the relay",
            claims: [],
        ) { app in
            try app.openWorking()
            try app.choose(.sendFeedback)
            try app.waitForSheet("Report a Bug")
            try app.pressInSheet(KeyCombo(.escape))
            try app.waitForNoSheet("Report a Bug")
            try app.main { $0.activeTool = .masking }
            let relay = app.runDirectory.appending(path: "relay")
            let before = (try? FileManager.default.contentsOfDirectory(atPath: relay.path).count) ?? 0
            let suggested = Flag()
            try app.run("a report sent to the stub relay", timeout: 60) { model in
                let sheet = await FeedbackActions.makeSheet(model: model)
                if sheet.report.featureID?.hasPrefix("masking") == true {
                    suggested.set()
                }
                var report = sheet.report
                report.title = "Regression suite: a report"
                report.body = "Sent by the regression suite to its own relay."
                report.featureID = report.featureID ?? "masking.other"
                sheet.report = report
                await sheet.send()
            }
            try app.main { $0.activeTool = .edit }
            try app.expect(suggested.isSet, "The sheet didn't suggest a Masking area while Masking was in use")
            try app.wait("the relay to get the report", timeout: 20) { _ in
                ((try? FileManager.default.contentsOfDirectory(atPath: relay.path).count) ?? 0) > before
            }
            let sent = try FileManager.default.contentsOfDirectory(atPath: relay.path).sorted().last
                .map { try String(contentsOf: relay.appending(path: $0), encoding: .utf8) } ?? ""
            let home = NSHomeDirectory()
            for leak in [app.photos.path, app.runDirectory.path, home, "/Users/"] {
                try app.expect(!sent.contains(leak), "The report holds a path: \(leak)")
            }
            for name in try app.photoNames() where name.count > 6 {
                try app.expect(!sent.contains(name), "The report names the photo \(name)")
            }
        }

        static let yourReports = Scenario(
            "feedback.your-reports", "Your Reports opens from the Help menu",
            claims: [],
        ) { app in
            try app.openWorking()
            try app.choose("Your Reports…")
            try app.waitForSheet("Your Reports")
            try app.pressInSheet(KeyCombo(.character("\r")))
            app.pause(0.5)
            if try app.sheetIsUp() {
                try app.pressInSheet(KeyCombo(.escape))
            }
            try app.waitForNoSheet("Your Reports")
        }

        static let cameraBench = Scenario(
            "feedback.camera-bench", "Test Your Camera opens on the folder from the Help menu",
            claims: [],
        ) { app in
            try app.openWorking()
            let before = try app.otherWindows()
            try app.choose(.testCamera)
            try app.wait("the camera bench window", timeout: 20) { _ in
                NSApp.windows.filter { $0.isVisible && !($0.windowController is EditorWindowController) && !$0.isSheet }
                    .count > before.count
            }
            try app.main { _ in
                NSApp.windows.first { $0.isVisible && $0.title.localizedCaseInsensitiveContains("camera") }?.close()
            }
        }
    }
#endif
