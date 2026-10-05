#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import RedlampEngineAPI
    @_spi(Harness) import RedlampUI

    /// A small, seeded generator, so a walk can be replayed from its seed.
    struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) {
            state = seed &+ 0x9E37_79B9_7F4A_7C15
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// One step of a walk, as written to `soak-steps.jsonl` before it's taken, so a crash
    /// leaves the steps that led to it.
    struct WalkStep: Codable, Sendable {
        var kind: String
        var action: String?
        var parameter: String?
        var value: Double?
        var count: Int?
    }

    enum SoakScenarios {
        static let all: [Scenario] = [walk]

        /// Actions a walk presses: everything that changes the edit or the view without
        /// opening a dialog, a window or the Open panel.
        static let keys: [ShortcutAction] = [
            .beforeAfter, .nextCompareLayout, .toggleZoom, .clipping, .rawClipping, .colorAssessment, .infoOverlay,
            .lightsOut, .toggleBlackAndWhite, .panelBasic, .panelToneCurve, .panelColorMixer, .panelDetail,
            .panelEffects,
            .nextPhoto, .previousPhoto, .undo, .rating3, .rating0, .flagPick, .unflag, .labelRed, .maskingTool,
            .editTool,
            .cropTool, .healTool, .maskOverlay, .cancel, .newSnapshot,
        ]

        static let walk = Scenario(
            "soak.random-walk", "A seeded random walk over actions, sliders, masks and undo, checked after every step",
            tiers: [.soak], claims: [
                .feature("performance.crash"),
                .feature("performance.freeze"),
                .feature("performance.memory"),
            ],
        ) { app in
            let replay = app.runDirectory.appending(path: "soak-replay.jsonl")
            let replaying = FileManager.default.fileExists(atPath: replay.path)
            let seconds = Double(ProcessInfo.processInfo.environment["REDLAMP_E2E_SOAK_SECONDS"] ?? "") ?? 300
            var random = SeededGenerator(seed: app.seed)
            let log = app.runDirectory.appending(path: "soak-steps.jsonl")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log)
            defer { try? handle.close() }
            let parameters = PanelID.allCases.flatMap(\.parameters).filter(\.spec.availability.isLive)
            var planned: [WalkStep] = []
            if replaying {
                planned = try String(contentsOf: replay, encoding: .utf8).split(separator: "\n")
                    .compactMap { try? JSONDecoder().decode(WalkStep.self, from: Data($0.utf8)) }
            }
            try app.openWorking()
            let startFootprint = Memory.footprint()
            let started = Date()
            var steps = 0
            // Caches fill for the photos a walk visits; after the first third, growth is the edit's.
            var settled: (steps: Int, footprint: Double)?
            while replaying ? steps < planned.count : Date().timeIntervalSince(started) < seconds {
                let step: WalkStep
                if replaying {
                    step = planned[steps]
                } else {
                    switch Int.random(in: 0 ..< 10, using: &random) {
                    case 0 ..< 4:
                        let parameter = parameters.randomElement(using: &random)!
                        let spec = parameter.spec
                        step = WalkStep(
                            kind: "slider",
                            parameter: parameter.rawValue,
                            value: Double.random(in: spec.range, using: &random),
                        )
                    case 4 ..< 7: step = WalkStep(kind: "key", action: keys.randomElement(using: &random)!.rawValue)
                    case 7: step = WalkStep(kind: "mask", action: Bool.random(using: &random) ? "linear" : "radial")
                    case 8: step = WalkStep(kind: "undo", count: Int.random(in: 1 ... 8, using: &random))
                    default: step = WalkStep(kind: "redo", count: Int.random(in: 1 ... 8, using: &random))
                    }
                }
                if var data = try? JSONEncoder().encode(step) {
                    data.append(0x0A)
                    handle.write(data)
                    try? handle.synchronize()
                }
                let mark = try app.mark()
                try take(step, app: app)
                try check(after: step, since: mark, app: app)
                steps += 1
                let third = replaying ? steps * 3 >= planned.count : Date().timeIntervalSince(started) * 3 >= seconds
                if settled == nil, third {
                    settled = (steps, Memory.footprint())
                }
            }
            // An edit survives leaving the photo and coming back: what's saved is what's open.
            try app.main { model in
                model.lightsOut = 0
                model.infoOverlay = 0
                model.showBefore = false
                model.leftPanelVisible = true
                model.rightPanelVisible = true
                model.filmstripVisible = true
                if model.isPresenting {
                    _ = model.perform(.fullScreenPreview)
                }
                if model.drawingKind != nil {
                    _ = model.perform(.cancel)
                }
                model.activeTool = .edit
                model.canvas.zoom = .fit
            }
            try app.settle(timeout: 60)
            let name = try app.main { $0.selection?.lastPathComponent ?? "" }
            try app.set(.vibrance, 11)
            let recipe = try app.main { $0.recipe }
            try app.main { $0.saveNow() }
            try app.openRaw(name.hasSuffix(".ARW") ? 1 : 0)
            try app.open(name)
            let reopened = try app.main { $0.recipe }
            try app.expect(reopened == recipe, "\(name) reopened with a different edit than it was left with")
            let end = Memory.footprint()
            let growth = end - startFootprint
            let after = settled.map { (end - $0.footprint) / Double(max(steps - $0.steps, 1)) } ?? 0
            app.recorder.write("note", ["soakSteps": steps, "footprintGrowthMB": growth, "growthPerStepMB": after])
            // After the caches fill, a session grows by about 1.8 MB a step today (ARC-08's finding of
            // 5 October 2026, for the owner); 3 MB or more is a regression.
            try app.expect(
                after < 3,
                String(
                    format: "After the first third, memory grew %.2f MB a step (%.0f MB over %d steps)",
                    after,
                    growth,
                    steps,
                ),
            )
            try app.choose(.resetAll)
            app.covered(
                [.feature("performance.crash"), .feature("performance.freeze"), .feature("performance.memory")],
                via: .key,
            )
        }

        static func take(_ step: WalkStep, app: RunningApp) throws {
            switch step.kind {
            case "slider":
                guard let parameter = step.parameter.flatMap(ParameterID.init(rawValue:)),
                      let value = step.value else { return }
                try app.main { model in
                    model.beginEdit(parameter)
                    model.setSliderValue(parameter, value)
                    model.endEdit(name: nil)
                }
            case "key":
                guard let action = step.action.flatMap(ShortcutAction.init(rawValue:)) else { return }
                if try app.main({ $0.canPerform(action) }) {
                    try app.press(action, expectPerformed: false)
                }
            case "mask":
                // A photo holds a limited number of masks; a long walk clears them as a person would.
                // Armed through the model: the keys toggle a mode a walk may have left on, and the
                // smoke tier checks them.
                let kind: MaskKind = step.action == "linear" ? .linear : .radial
                try app.main { model in
                    if model.masks.count >= 12 {
                        model.deleteAllMasks()
                    }
                    model.cancelDrawing()
                    model.startDrawing(kind)
                    model.beginDrawing(kind == .linear
                        ? .linear(LinearMask(start: ImagePoint(x: 0.5, y: 0.2), end: ImagePoint(x: 0.5, y: 0.6)))
                        : .radial(RadialMask(
                            center: ImagePoint(x: 0.5, y: 0.5),
                            radiusX: 0.2,
                            radiusY: 0.15,
                            feather: 50,
                        )))
                    model.finishDrawing()
                    model.activeTool = .edit
                }
            case "undo", "redo":
                for _ in 0 ..< (step.count ?? 1) {
                    try app.main { model in step.kind == "undo" ? model.undo() : model.redo() }
                }
            default:
                break
            }
            app.pause(0.05)
        }

        static func check(after step: WalkStep, since mark: RunningApp.Mark, app: RunningApp) throws {
            try app
                .wait(
                    "the editor to settle after \(step.kind) \(step.action ?? step.parameter ?? "")",
                    timeout: 30,
                ) { model in
                    !model.isLoading && NSApp.modalWindow == nil
                }
            let (index, count, error) = try app.main { ($0.historyIndex, $0.history.count, $0.errorMessage) }
            try app.expect(index >= 0 && index < max(count, 1), "History at \(index) of \(count)")
            try app.expect(error == nil, "The editor shows \(error ?? "")")
            try app.expectNoErrors(since: mark)
        }
    }
#endif
