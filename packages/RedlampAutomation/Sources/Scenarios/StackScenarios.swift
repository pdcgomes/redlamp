#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import RedlampDocument
    import RedlampEngineAPI
    import RedlampRecipes
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
            // Its frames marked in the filmstrip, as VoiceOver reads them, the strip kept up past the 5 s it shows for,
            // and every stack open so each frame has its cell: the frames are a burst too.
            let frames = try app.main { model in
                model.applyDebugCommand("filmstrip", "shown")
                model.gridStacks.openAll()
                return model.stackSuggestions.first?.frames.map(\.lastPathComponent) ?? []
            }
            do {
                defer { try? app.main { $0.applyDebugCommand("filmstrip", "hidden") } }
                let marked = frames.map { "\($0): suggested for a focus stack" }
                do {
                    try app.wait("the filmstrip to mark the bracket's frames", timeout: 10) { _ in
                        filmstripMarks(frames) == marked
                    }
                } catch {
                    throw try ScenarioFailure("\(error): \(app.main { _ in filmstripMarks(frames) })")
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

        /// What the filmstrip's cell for each of `names` says after its name, as VoiceOver reads it, or that it has no
        /// cell on screen.
        @MainActor static func filmstripMarks(_ names: [String]) -> [String] {
            guard let root = Views.editorWindow?.contentView?.superview else { return [] }
            /// The module not shown, and the filmstrip slid away, are left in place, transparent.
            func onScreen(_ view: NSView) -> Bool {
                sequence(first: view, next: \.superview).allSatisfy { !$0.isHidden && $0.alphaValue > 0 }
            }
            let cells = Views.all(NSView.self, in: root).filter { $0.accessibilityIdentifier().hasPrefix("filmstrip.") }
            return names.map { name in
                guard let cell = cells
                    .first(where: { $0.accessibilityIdentifier() == "filmstrip.\(name)" && onScreen($0) })
                else { return "\(name): no cell on screen" }
                return "\(name): \(cell.accessibilityValue() as? String ?? "unmarked")"
            }
        }
    }

    enum RawScenarios {
        static let all: [Scenario] = [damaged, balancedInCamera, dRange, smallRawWhite]

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

        /// #480: a raw the camera white-balanced (Sony's YCbCr ARWs, Nikon's small raws) is balanced once from
        /// process 18; an edit at 17 renders it balanced twice, pink, as 0.3.3 did, until it's moved to the current
        /// version. Judged as the camera bench judges a cast: the edit's still against the camera's own JPEG.
        static let balancedInCamera = Scenario(
            "raw.balanced-in-camera",
            "A Sony YCbCr ARW and a Nikon small raw open in their camera's colour, and Auto White Balance keeps it; an "
                + "edit moved to process 17 renders them balanced twice, as 0.3.3 did, until it's moved to the current "
                + "version",
            claims: [.feature("raw.colours"), .feature("develop.white-balance")],
        ) { app in
            let folder = app.photos.appending(path: "Balanced in Camera")
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { SupportedFormats.isRaw(folder.appending(path: $0)) }.sorted()
            guard !names.isEmpty else {
                throw ScenarioSkip("The run has no raws the camera balanced: `mise run fixtures` fetches them")
            }
            try app.main { $0.open([folder]) }
            try app.wait("the folder of raws the camera balanced, with its photos", timeout: 30) { model in
                model.folder?.standardizedFileURL == folder.standardizedFileURL
                    && Set(model.items.map(\.url.lastPathComponent)).isSuperset(of: names)
            }
            let current = EditRecipe.currentProcessVersion
            for name in names {
                let clicked = try app.exists(.filmstrip(name))
                try app.open(name)
                try app.settle(timeout: 60)
                try app.wait("\(name) at process 18 or later, as shot") { model in
                    model.recipe.processVersion >= 18 && model.whiteBalanceMode == .asShot
                }
                let preview = try cameraPreview(of: folder.appending(path: name), app: app)
                let shot = try compare(app, against: preview)
                app.covered(.feature("raw.colours"), via: clicked ? .mouse : .model)

                try app.choose(.autoWhiteBalance)
                try app.wait("Auto White Balance on \(name)", timeout: 30) { $0.whiteBalanceMode == .auto }
                let (auto, asShot) = try app.main { model in
                    (
                        WhiteBalanceValue(temperature: model.value(.temperature), tint: model.value(.tint)),
                        model.info?.asShotWhiteBalance,
                    )
                }
                let automatic = try compare(app, against: preview)
                app.covered(.feature("develop.white-balance"), via: .menu)
                try app.press(.undo)
                try app.wait("⌘Z: \(name) as shot again") { $0.whiteBalanceMode == .asShot }

                try app.expectRenders("\(name)'s edit moved to process 17") {
                    try app.main { $0.setProcessVersion(17) }
                }
                let older = try compare(app, against: preview)
                try app.expectRenders("\(name)'s edit moved to Version \(current)") {
                    try app.main { $0.setProcessVersion(current) }
                }
                let back = try compare(app, against: preview)
                let (opened, automated, earlier, again) =
                    (describe(shot), describe(automatic), describe(older), describe(back))
                app.recorder.write("note", [
                    name: "as shot \(opened); Auto \(automated), \(Int(auto.temperature)) K and tint "
                        + "\(Int(auto.tint)) against \(Int(asShot?.temperature ?? 0)) K and tint "
                        + "\(Int(asShot?.tint ?? 0)) as shot; at 17 \(earlier); at \(current) again \(again)",
                ])
                let once = [shot, back].allSatisfy { verdict($0) != .fail && verdict($0) != .warn }
                    && verdict(automatic) != .fail
                    && [shot, automatic, back].allSatisfy { ($0.colourDifference ?? .infinity) < Self.cameraColour }
                try app.expect(
                    once,
                    "\(name) isn't in its camera's colour: as shot \(opened), after Auto \(automated), at \(current) "
                        + "again \(again)",
                )
                try app.expect(
                    (older.colourDifference ?? 0) > (shot.colourDifference ?? .infinity) + 4
                        && (verdict(older) == .fail || shot.cast == nil),
                    "At process 17 \(name) isn't balanced twice, as 0.3.3 rendered it: \(earlier), against \(opened) "
                        + "at \(current)",
                )
                try app.choose(.resetAll)
            }
            try app.main { $0.open([app.photos]) }
            try app.wait("the photos folder again", timeout: 30) {
                $0.folder?.standardizedFileURL == app.photos.standardizedFileURL
            }
            try app.openWorking()
        }

        /// A Fujifilm raw shot at DR200 is a stop darker than at DR100, which its camera's JPEG brightens back: from
        /// process 19 every look adds the stops the file records, and the Exposure slider stays at 0; an edit at 18
        /// renders it a stop darker, as 0.3.3 did, until it's moved to the current version. Judged as the camera bench
        /// judges exposure: the midtones of the edit's still against the camera's own JPEG, within half the recorded
        /// stops of it at 19 and nearer than at 18. The rest is the look's and the camera's exposure anchor, not the
        /// D-Range: the X-E5's sample opens 0.43 stops brighter than its JPEG, the GFX100 II's 0.12.
        static let dRange = Scenario(
            "raw.d-range",
            "A Fujifilm raw shot at DR200 opens as bright as its camera's JPEG with Exposure at 0; an edit moved to "
                + "process 18 renders it a stop darker, as 0.3.3 did, until it's moved to the current version",
            claims: [.feature("develop.calibration")],
        ) { app in
            let folder = app.photos.appending(path: "D-Range")
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { SupportedFormats.isRaw(folder.appending(path: $0)) }.sorted()
            guard !names.isEmpty else {
                throw ScenarioSkip("The run has no raws shot at DR200: `mise run fixtures` fetches them")
            }
            try app.main { $0.open([folder]) }
            try app.wait("the folder of raws shot at DR200, with its photos", timeout: 30) { model in
                model.folder?.standardizedFileURL == folder.standardizedFileURL
                    && Set(model.items.map(\.url.lastPathComponent)).isSuperset(of: names)
            }
            let current = EditRecipe.currentProcessVersion
            for name in names {
                try app.open(name)
                try app.settle(timeout: 120)
                try app.wait("\(name) at process 19 or later") { $0.recipe.processVersion >= 19 }
                let (shift, slider) = try app.main { ($0.info?.exposureShift ?? 0, $0.value(.exposure)) }
                let preview = try cameraPreview(of: folder.appending(path: name), app: app)
                let opened = try compare(app, against: preview)
                try app.expectRenders("\(name)'s edit moved to process 18") {
                    try app.main { $0.setProcessVersion(18) }
                }
                let older = try compare(app, against: preview)
                app.covered(.feature("develop.calibration"), via: .model)
                try app.expectRenders("\(name)'s edit moved to Version \(current)") {
                    try app.main { $0.setProcessVersion(current) }
                }
                let back = try compare(app, against: preview)
                let (now, then, again) = (opened.exposure ?? .nan, older.exposure ?? .nan, back.exposure ?? .nan)
                app.recorder.write("note", [
                    name: String(
                        format: "%.0f stops recorded; against the camera's JPEG %+.2f stops, at 18 %+.2f, at "
                            + "\(current) again %+.2f",
                        shift, now, then, again,
                    ),
                ])
                try app.expect(shift >= 1, "\(name) records no D-Range shift (\(shift)): it isn't a DR200 sample")
                try app.expect(
                    slider == 0,
                    "\(name) opens with Exposure at \(slider), where the shift isn't the slider's",
                )
                try app.expect(
                    abs(now) < shift / 2 && abs(now) < abs(then) && now - then >= shift / 2,
                    String(
                        format: "\(name) isn't brought within half its D-Range of the camera's JPEG at \(current): "
                            + "%+.2f stops from it, and %+.2f at 18",
                        now, then,
                    ),
                )
                try app.expect(
                    abs(again - now) < 0.05,
                    String(format: "\(name) moved back to \(current) renders %+.2f stops, not %+.2f", again, now),
                )
                try app.choose(.resetAll)
            }
            try app.main { $0.open([app.photos]) }
            try app.wait("the photos folder again", timeout: 30) {
                $0.folder?.standardizedFileURL == app.photos.standardizedFileURL
            }
            try app.openWorking()
        }

        /// CAM-33: LibRaw gives every Canon sRAW and mRAW a white level of 16383, where each body's data clips
        /// elsewhere, the EOS 7D's at 11,785. From process 20 the small raws of the bodies measured are normalised at
        /// their own level, and open as bright as their body's full raws; an edit at 19 renders them at 16383, as
        /// 0.3.4 did, until it's moved to the current version. Judged as the camera bench judges exposure: the
        /// midtones of the edit's still against the camera's own JPEG.
        static let smallRawWhite = Scenario(
            "raw.small-raw-white",
            "A Canon sRAW opens as bright as its camera's JPEG, at its body's white level; an edit moved to process 19 "
                + "renders it about half a stop darker, as 0.3.4 did, until it's moved to the current version",
            claims: [.feature("raw.highlights"), .feature("develop.calibration")],
        ) { app in
            let folder = app.photos.appending(path: "Small Raw")
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { SupportedFormats.isRaw(folder.appending(path: $0)) }.sorted()
            guard !names.isEmpty else {
                throw ScenarioSkip("The run has no Canon small raw: `mise run fixtures` fetches it")
            }
            try app.main { $0.open([folder]) }
            try app.wait("the folder of Canon small raws, with its photos", timeout: 30) { model in
                model.folder?.standardizedFileURL == folder.standardizedFileURL
                    && Set(model.items.map(\.url.lastPathComponent)).isSuperset(of: names)
            }
            let current = EditRecipe.currentProcessVersion
            for name in names {
                let clicked = try app.exists(.filmstrip(name))
                try app.open(name)
                try app.settle(timeout: 120)
                try app.wait("\(name) at process 20 or later, as a small raw") { model in
                    model.recipe.processVersion >= 20 && model.info?.sensorDescription == "Small raw"
                }
                let preview = try cameraPreview(of: folder.appending(path: name), app: app)
                let opened = try compare(app, against: preview)
                app.covered(.feature("raw.highlights"), via: clicked ? .mouse : .model)
                try app.expectRenders("\(name)'s edit moved to process 19") {
                    try app.main { $0.setProcessVersion(19) }
                }
                let older = try compare(app, against: preview)
                app.covered(.feature("develop.calibration"), via: .model)
                try app.expectRenders("\(name)'s edit moved to Version \(current)") {
                    try app.main { $0.setProcessVersion(current) }
                }
                let back = try compare(app, against: preview)
                let (now, then, again) = (opened.exposure ?? .nan, older.exposure ?? .nan, back.exposure ?? .nan)
                app.recorder.write("note", [
                    name: String(
                        format: "against the camera's JPEG %+.2f stops, at 19 %+.2f, at \(current) again %+.2f",
                        now, then, again,
                    ),
                ])
                try app.expect(
                    abs(now) < Self.smallRawExposure,
                    String(
                        format: "\(name) isn't within %.2f stops of the camera's JPEG at \(current): %+.2f",
                        Self.smallRawExposure, now,
                    ),
                )
                try app.expect(
                    abs(now - then - Self.smallRawStep) < 0.1,
                    String(
                        format: "\(name) at 19 isn't %.2f stops darker than at \(current), as 0.3.4 rendered it: "
                            + "%+.2f stops from the camera's JPEG, against %+.2f",
                        Self.smallRawStep, then, now,
                    ),
                )
                try app.expect(
                    abs(again - now) < 0.05,
                    String(format: "\(name) moved back to \(current) renders %+.2f stops, not %+.2f", again, now),
                )
                try app.choose(.resetAll)
            }
            try app.main { $0.open([app.photos]) }
            try app.wait("the photos folder again", timeout: 30) {
                $0.folder?.standardizedFileURL == app.photos.standardizedFileURL
            }
            try app.openWorking()
        }

        /// A colour difference from the camera's JPEG under this is the camera's colour: balanced once, the samples
        /// measure about 2, and balanced twice 7 (the D810's small raw) and 13 (the a7 IV's M).
        static let cameraColour = 5.0

        /// How far from its camera's JPEG the 7D's sRAW may open at process 20, in stops: it measures +0.23, and −0.23
        /// at 19, as the camera bench measured it there.
        static let smallRawExposure = 0.35
        /// How much darker an edit at process 19 renders the 7D's sRAW, in stops: log2(16383 / 11785) is 0.47.
        static let smallRawStep = 0.47

        /// The camera's own JPEG in `url`, at the size the camera bench compares; read off the main thread, as the
        /// decode service asks.
        private static func cameraPreview(of url: URL, app: RunningApp) throws -> CGImage {
            let inspector = try app.main { $0.engine as? any RawFileInspecting }
            guard let preview = inspector?.cameraPreview(of: url, maxLongEdge: CameraBench.pairSize) else {
                throw ScenarioFailure("\(url.lastPathComponent) has no camera JPEG to compare")
            }
            return preview
        }

        /// The open photo's edit as it renders now against the camera's JPEG, as the camera bench compares them.
        private static func compare(_ app: RunningApp, against preview: CGImage) throws -> CameraJPEGComparison {
            let still = StillBox()
            try app.run("a still of the edit, as the camera bench renders one", timeout: 120) { model in
                still.image = try? await model.engine.renderStill(StillRequest(
                    recipe: model.recipe, maxLongEdge: CameraBench.pairSize, colorSpace: .sRGB, bitsPerComponent: 16,
                    purpose: .export,
                ))
            }
            guard let ours = still.image, let comparison = CameraJPEGComparison(ours: ours, theirs: preview) else {
                throw ScenarioFailure("The edit's still couldn't be compared with the camera's JPEG")
            }
            return comparison
        }

        /// The camera bench's cast check: skipped where the camera's JPEG has too few neutral areas.
        private static func verdict(_ comparison: CameraJPEGComparison) -> BenchVerdict {
            CameraBenchChecks.preview(comparison, hasPreview: true).first { $0.id == "preview.cast" }?.verdict
                ?? .skipped
        }

        private static func describe(_ comparison: CameraJPEGComparison) -> String {
            let cast = comparison.cast.map { String(format: "cast %.1f", $0) } ?? "no neutral areas"
            let colour = comparison.colourDifference.map { String(format: "colour difference %.1f", $0) } ?? ""
            return "\(cast), \(colour)"
        }

        /// A still carried back from the main thread, read once the work that made it has finished.
        final class StillBox: @unchecked Sendable {
            var image: CGImage?
        }
    }

    enum FeedbackScenarios {
        static let all: [Scenario] = [reportABug, yourReports, cameraBench, activityLogOff]

        static let reportABug = Scenario(
            "feedback.report-a-bug",
            "Report a Bug opens from the menu, suggests the area in use, and sends nothing private to the relay, in its "
                + "title or anywhere else",
            claims: [],
        ) { app in
            try app.openWorking()
            let photo = try app.workingPhoto()
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
                report.title = "Regression suite: a report on \(photo), from \(NSHomeDirectory())/Desktop/Exports"
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
            let latest = try FileManager.default.contentsOfDirectory(atPath: relay.path).sorted().last
                .map { relay.appending(path: $0) }
            let sent = try latest.map { try String(contentsOf: $0, encoding: .utf8) } ?? ""
            let home = NSHomeDirectory()
            for leak in [app.photos.path, app.runDirectory.path, home, "/Users/"] {
                try app.expect(!sent.contains(leak), "The report holds a path: \(leak)")
            }
            for name in try app.photoNames() where name.count > 6 {
                try app.expect(!sent.contains(name), "The report names the photo \(name)")
            }
            let title = try latest.map { try IncidentScenarios.Sent($0).title } ?? ""
            try app.expect(
                title.contains("Regression suite: a report on Photo ") && !title.contains(photo)
                    && title.hasSuffix(", from …/Exports"),
                "The report is titled \(title)",
            )
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
