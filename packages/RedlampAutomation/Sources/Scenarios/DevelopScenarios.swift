#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import RedlampDesign
    import RedlampEngineAPI
    @_spi(Harness) import RedlampUI

    enum DevelopScenarios {
        static let all: [Scenario] = [
            whiteBalance,
            treatment,
            toneAndPresence,
            toneCurve,
            colorMixer,
            colorGrading,
            detail,
            lensAndTransform,
            effectsAndCalibration,
            histogram,
        ]

        static let whiteBalance = Scenario(
            "develop.white-balance", "White balance: each preset, Auto from the menu, and the eyedropper",
            claims: [.feature("develop.white-balance")],
        ) { app in
            try app.openWorking()
            for mode in WhiteBalanceMode.allCases where mode != .custom {
                try app.expectRenders("white balance \(mode)") {
                    try app.main { $0.setWhiteBalanceMode(mode) }
                }
                let now = try app.main { $0.whiteBalanceMode }
                try app.expect(now == mode, "White balance is \(now), not \(mode)")
            }
            try app.main { $0.setWhiteBalanceMode(.asShot) }
            try app.choose(.autoWhiteBalance)
            try app.wait("Auto white balance") { $0.whiteBalanceMode == .auto }
            try app.press(.whiteBalanceSelector)
            try app.wait("the eyedropper") { $0.eyedropperActive }
            let temperature = try app.value(.temperature)
            try app.main { $0.sampleWhiteBalance(at: CGPoint(x: 0.3, y: 0.3)) }
            try app.wait("a sampled white balance") { $0.value(.temperature) != temperature || !$0.eyedropperActive }
            try app.main { model in
                model.eyedropperActive = false
                model.setWhiteBalanceMode(.asShot)
            }
            app.covered(.feature("develop.white-balance"), via: .menu)
        }

        static let treatment = Scenario(
            "develop.treatment", "Black & white by its key, and every built-in Base Look",
            claims: [.feature("develop.treatment")],
        ) { app in
            try app.openWorking()
            try app.press(.toggleBlackAndWhite)
            try app.wait("black & white") { $0.treatment == .blackAndWhite }
            try app.press(.toggleBlackAndWhite)
            try app.wait("colour") { $0.treatment == .color }
            for look in BuiltInBaseLook.allCases where try app.main({ $0.baseLook }) != look.reference {
                try app.expectRenders("the \(look) Base Look") {
                    try app.main { $0.setBaseLook(look.reference) }
                }
                let now = try app.main { $0.baseLook }
                try app.expect(now == look.reference, "The Base Look is \(now), not \(look)")
            }
            // The Base Look Amount's value takes typing.
            try app.main { $0.expandedPanels = [.basic] }
            app.pause(0.3)
            try app.click(.identifier("baseLook.amount.value"))
            try app.wait("the Base Look Amount's value to take typing") { _ in
                Views.editorWindow?.firstResponder is NSTextView
            }
            try app.type("60")
            try app.pressInWindow(KeyCombo(.character("\r")))
            try app.wait("the Base Look Amount to be 60") { $0.baseLook.amount == 60 }
            try app.main { $0.setBaseLook(BuiltInBaseLook.color.reference) }
            app.covered(.feature("develop.treatment"), via: .key)
        }

        static let toneAndPresence = Scenario(
            "develop.tone-and-presence", "Basic's sliders by every gesture, and Auto Settings",
            claims: [
                .feature("develop.tone"),
                .feature("develop.presence"),
                .feature("develop.auto"),
                .feature("workspace.sliders"),
            ],
        ) { app in
            try app.openWorking()
            try app.main { $0.expandedPanels = [.basic] }
            app.pause(0.3)
            // Shift-drag is fine control: the same drag moves a tenth as far.
            try app.drag(.slider(.contrast), from: CGPoint(x: 0.5, y: 0.5), by: CGVector(dx: 30, dy: 0))
            let coarse = try app.value(.contrast)
            try app.main { $0.reset(.contrast) }
            try app.drag(
                .slider(.contrast),
                from: CGPoint(x: 0.5, y: 0.5),
                by: CGVector(dx: 30, dy: 0),
                modifiers: .shift,
            )
            let fine = try app.value(.contrast)
            try app.expect(
                abs(fine) < abs(coarse) / 2 && fine != 0,
                "Shift-drag moved Contrast \(fine), plain \(coarse)",
            )
            try app.main { $0.reset(.contrast) }
            // ⌘-scroll steps the slider under the pointer.
            try app.scroll(.slider(.highlights), lines: 3)
            try app.wait("⌘-scroll to move Highlights") { $0.value(.highlights) != 0 }
            try app.main { $0.reset(.highlights) }
            // The value field takes arithmetic.
            try app.set(.shadows, 10)
            try app.click(.sliderValue(.shadows))
            try app.wait("the value field to take typing") { _ in Views.editorWindow?.firstResponder is NSTextView }
            try app.type("x+15")
            try app.pressInWindow(KeyCombo(.character("\r")))
            try app.wait("Shadows to be 25") { abs($0.value(.shadows) - 25) < 1e-6 }
            // Dragging the number scrubs it, as one history step. (⌘-scroll's own step ends 400 ms
            // after scrolling stops, so only the steps naming Shadows are counted.)
            let steps = try app.main { $0.history.count }
            try app.drag(.sliderValue(.shadows), from: CGPoint(x: 0.5, y: 0.5), by: CGVector(dx: 50, dy: 0))
            try app.wait("dragging the number to scrub Shadows") { $0.value(.shadows) > 25 }
            try app.wait("the scrub's history step") { $0.history.count > steps }
            app.pause(0.5)
            let scrubSteps = try app.main { $0.history.dropFirst(steps).count(where: { $0.title == "Shadows" }) }
            try app.expect(scrubSteps == 1, "The scrub made \(scrubSteps) Shadows steps, not one")
            // , and . choose a slider, - and = nudge it.
            try app.main { $0.focusedParameter = .whites }
            try app.press(.increaseSetting)
            try app.wait("= to nudge Whites") { $0.value(.whites) > 0 }
            try app.press(.increaseSetting, shift: true)
            let nudged = try app.value(.whites)
            try app.expect(nudged >= 11, "⇧= nudged Whites to \(nudged), not by ten steps")
            try app.choose(.resetAll)
            try app.choose(.autoTone)
            try app
                .wait("Auto Settings to change the tone") {
                    $0.isEdited(.exposure) || $0.isEdited(.contrast) || $0.isEdited(.whites)
                }
            try app.choose(.resetAll)
            app.covered([
                .feature("develop.tone"),
                .feature("develop.presence"),
                .feature("develop.auto"),
                .feature("workspace.sliders"),
            ], via: .mouse)
        }

        static let toneCurve = Scenario(
            "develop.tone-curve",
            "Tone Curve: the region sliders, the split points, a point curve, and Reset Tone Curve from its header",
            claims: [
                .feature("develop.tone-curve"),
                .parameter(.curveSplitShadows),
                .parameter(.curveSplitMidtones),
                .parameter(.curveSplitHighlights),
            ],
        ) { app in
            try app.openWorking()
            try app.main { $0.expandedPanels = [.toneCurve] }
            app.pause(0.3)
            // Each split's value under its handle takes typing.
            for parameter in [ParameterID.curveSplitShadows, .curveSplitMidtones, .curveSplitHighlights] {
                let spec = parameter.spec
                try typeValue(spec.clamp(spec.defaultValue + 10), into: parameter, app: app)
                app.covered(.parameter(parameter), via: .key)
            }
            try app.expectRenders("a point curve") {
                try app.main { model in
                    model.setPointCurve([
                        CurvePoint(x: 0, y: 0),
                        CurvePoint(x: 0.25, y: 0.2),
                        CurvePoint(x: 0.75, y: 0.82),
                        CurvePoint(x: 1, y: 1),
                    ])
                }
            }
            // The header's Reset Tone Curve resets the point curve with the sliders.
            try app.rightClick(.panelHeader(.toneCurve), choosing: "Reset Tone Curve")
            try app.wait("Reset Tone Curve to reset the point curve") {
                $0.pointCurve == EditRecipe.linearPointCurve && !$0.isEdited(.toneCurve)
            }
            try app.choose(.resetAll)
            app.covered(.feature("develop.tone-curve"), via: .model)
        }

        static let colorMixer = Scenario(
            "develop.color-mixer", "Color Mixer: every band's hue, saturation and luminance",
            claims: [.feature("develop.color-mixer")] + ColorBand.allCases.flatMap { band in
                [Claim.parameter(band.saturationParameter), .parameter(band.luminanceParameter)]
            },
        ) { app in
            try app.openWorking()
            for band in ColorBand.allCases {
                for parameter in [band.hueParameter, band.saturationParameter, band.luminanceParameter] {
                    try app.set(parameter, 40)
                    app.covered(.parameter(parameter), via: .model)
                }
            }
            try app.choose(.resetAll)
            app.covered(.feature("develop.color-mixer"), via: .model)
        }

        static let colorGrading = Scenario(
            "develop.color-grading", "Color Grading: every wheel's hue, saturation and luminance",
            claims: [.feature("develop.color-grading")] + GradingRange.allCases.flatMap { range in
                [
                    Claim.parameter(range.hueParameter),
                    .parameter(range.saturationParameter),
                    .parameter(range.luminanceParameter),
                ]
            },
        ) { app in
            try app.openWorking()
            try app.main { $0.expandedPanels = [.colorGrading] }
            app.pause(0.3)
            for range in GradingRange.allCases {
                let parameters = [range.hueParameter, range.saturationParameter, range.luminanceParameter]
                // The 3-way view's wheels show their hue, saturation and luminance as values; Global
                // has no wheel there.
                if range == .global {
                    try app.set(range.hueParameter, 200)
                    try app.set(range.saturationParameter, 30)
                    try app.set(range.luminanceParameter, 10)
                    app.covered(parameters.map { Claim.parameter($0) }, via: .model)
                } else {
                    try typeValue(200, into: range.hueParameter, app: app)
                    try typeValue(30, into: range.saturationParameter, app: app)
                    try typeValue(10, into: range.luminanceParameter, app: app)
                    app.covered(parameters.map { Claim.parameter($0) }, via: .key)
                }
            }
            try app.choose(.resetAll)
            app.covered(.feature("develop.color-grading"), via: .key)
        }

        /// Clicks a parameter's value field, types `value` and presses Return.
        static func typeValue(_ value: Double, into parameter: ParameterID, app: RunningApp) throws {
            try app.click(.sliderValue(parameter))
            try app.wait("\(parameter.spec.label)'s value to take typing") { _ in
                Views.editorWindow?.firstResponder is NSTextView
            }
            try app.type(parameter.spec.formatted(value))
            try app.pressInWindow(KeyCombo(.character("\r")))
            try app.wait("\(parameter.spec.label) to be \(parameter.spec.formatted(value))") {
                abs($0.value(parameter) - value) < 1e-6
            }
        }

        static let detail = Scenario(
            "develop.detail", "Sharpening and noise reduction render at 1:1",
            claims: [.feature("develop.sharpening"), .feature("develop.noise-reduction")],
        ) { app in
            try app.openWorking()
            try app.press(.toggleZoom)
            try app.wait("1:1") { $0.canvas.zoom != .fit }
            try app.set(.noiseLuminance, 50)
            try app.set(.sharpenAmount, 80)
            try app.press(.toggleZoom)
            try app.choose(.resetAll)
            app.covered([.feature("develop.sharpening"), .feature("develop.noise-reduction")], via: .model)
        }

        static let lensAndTransform = Scenario(
            "develop.lens-and-transform", "Lens corrections and every Upright mode",
            claims: [
                .feature("develop.lens-corrections"),
                .feature("develop.transform"),
                .parameter(.lensProfile),
                .parameter(.lensRemoveChromaticAberration),
            ],
        ) { app in
            try app.openWorking()
            for parameter in [ParameterID.lensProfile, .lensRemoveChromaticAberration] {
                let now = try app.value(parameter)
                try app.set(parameter, now > 0.5 ? 0 : 1)
                try app.set(parameter, now)
                app.covered(.parameter(parameter), via: .model)
            }
            for mode in UprightMode.allCases {
                try app.run("Upright \(mode)") { model in
                    model.applyUpright(mode)
                    try? await Task.sleep(for: .milliseconds(600))
                }
            }
            try app.main { $0.clearUpright() }
            try app.choose(.resetAll)
            app.covered([.feature("develop.lens-corrections"), .feature("develop.transform")], via: .model)
        }

        static let effectsAndCalibration = Scenario(
            "develop.effects-and-calibration",
            "Effects, the camera-recipe controls, the frame, and every process version",
            claims: [
                .feature("develop.effects"),
                .feature("develop.camera-recipe"),
                .feature("develop.calibration"),
                .parameter(.frameStyle),
            ],
        ) { app in
            try app.openWorking()
            try app.set(.frameStyle, ParameterID.frameStyle.spec.range.upperBound)
            app.covered(.parameter(.frameStyle), via: .model)
            for parameter in PanelID.effects.parameters where parameter != .frameStyle {
                let spec = parameter.spec
                try app.main { $0.setSliderValue(
                    parameter,
                    spec.clamp(spec.defaultValue + (spec.range.upperBound - spec.defaultValue) / 2),
                ) }
            }
            try app.expectRenders("the effects") { try app.main { $0.setSliderValue(.vignetteAmount, -40) } }
            let current = EditRecipe.currentProcessVersion
            for version in 1 ... current {
                try app.main { $0.setProcessVersion(version) }
                let now = try app.main { $0.recipe.processVersion }
                try app.expect(now == version, "Process version is \(now), not \(version)")
            }
            try app.main { $0.setProcessVersion(current) }
            try app.choose(.resetAll)
            app.covered(
                [.feature("develop.effects"), .feature("develop.camera-recipe"), .feature("develop.calibration")],
                via: .model,
            )
        }

        static let histogram = Scenario(
            "develop.histogram", "Dragging the histogram moves its region's slider; its corner shows clipping",
            claims: [.feature("develop.histogram")],
        ) { app in
            try app.openWorking()
            for parameter in [ParameterID.shadows, .exposure, .highlights] {
                let before = try app.value(parameter)
                try app.drag(.histogram(parameter), from: CGPoint(x: 0.5, y: 0.5), by: CGVector(dx: 25, dy: 0))
                try app.wait("the histogram to move \(parameter.spec.label)") { $0.value(parameter) != before }
            }
            try app.choose(.resetAll)
            app.covered(.feature("develop.histogram"), via: .mouse)
        }
    }

    enum ViewingScenarios {
        static let all: [Scenario] = [zoomAndNavigator, beforeAfter, overlays, display]

        static let zoomAndNavigator = Scenario(
            "viewing.zoom-and-navigator", "Zoom by keys and menu, and the Navigator moves the view at 1:1",
            claims: [.feature("viewing.zoom"), .feature("viewing.navigator"), .section(.navigator)],
        ) { app in
            try app.openWorking()
            try app.press(.toggleZoom)
            try app.wait("1:1") { $0.canvas.zoom == .oneToOne }
            try app.choose(.zoomIn)
            try app.wait("zoomed in") { $0.canvas.zoom != .oneToOne }
            try app.main { $0.canvas.zoom = .oneToOne }
            let offset = try app.main { "\($0.canvas.center)" }
            try app.click(.identifier("sidebar.navigator"), at: CGPoint(x: 0.2, y: 0.6))
            try app.wait("the Navigator to move the view") { offset != "\($0.canvas.center)" }
            try app.press(.toggleZoom)
            try app.wait("Fit") { $0.canvas.zoom == .fit }
            app.covered([.feature("viewing.zoom"), .feature("viewing.navigator"), .section(.navigator)], via: .mouse)
        }

        static let beforeAfter = Scenario(
            "viewing.before-after", "Before / After in every layout",
            claims: [.feature("viewing.before-after")],
        ) { app in
            try app.openWorking()
            try app.set(.exposure, 0.8)
            try app.press(.beforeAfter)
            try app.wait("Before") { $0.showBefore }
            for layout in CompareLayout.allCases {
                try app.main { $0.showComparison(in: layout) }
                try app.wait("the \(layout) layout") { $0.compareLayout == layout && $0.showBefore }
                app.pause(0.2)
            }
            try app.press(.nextCompareLayout)
            try app.main { model in
                model.showBefore = false
                model.compareLayout = .toggle
            }
            try app.choose(.resetAll)
            app.covered(.feature("viewing.before-after"), via: .key)
        }

        static let overlays = Scenario(
            "viewing.overlays", "Clipping, sensor clipping, the assessment view, the info overlay and Lights Out",
            claims: [
                .feature("viewing.clipping"),
                .feature("viewing.color-assessment"),
                .feature("viewing.info-overlay"),
                .feature("viewing.lights-out"),
            ],
        ) { app in
            try app.openWorking()
            try app.press(.clipping)
            try app.press(.rawClipping)
            try app.press(.colorAssessment)
            try app.wait("the three views") { $0.showClipping && $0.showRawClipping && $0.colorAssessment }
            try app.press(.clipping)
            try app.press(.rawClipping)
            try app.press(.colorAssessment)
            for step in 1 ... 3 {
                try app.press(.infoOverlay)
                try app.press(.lightsOut)
                try app.wait("step \(step) of the overlays") { $0.infoOverlay == step % 3 && $0.lightsOut == step % 3 }
            }
            try app.press(.fullScreenPreview)
            try app.wait("the full-screen preview") { $0.isPresenting }
            try app.press(.fullScreenPreview)
            try app.wait("the editor back") { !$0.isPresenting }
            app.covered(
                [
                    .feature("viewing.clipping"),
                    .feature("viewing.color-assessment"),
                    .feature("viewing.info-overlay"),
                    .feature("viewing.lights-out"),
                ],
                via: .key,
            )
        }

        static let display = Scenario(
            "viewing.display", "The canvas draws in extended Display P3",
            claims: [.feature("viewing.display")],
        ) { app in
            try app.openWorking()
            let space = try app.main { _ -> String in
                guard let window = Views.editorWindow, let root = window.contentView?.superview,
                      let canvas = Views.all(NSView.self, in: root)
                      .first(where: { $0.accessibilityIdentifier() == "canvas" }),
                      let layer = canvas.layer as? CAMetalLayer
                else { return "" }
                return (layer.colorspace?.name as String?) ?? ""
            }
            try app.expect(space.contains("P3"), "The canvas draws in \(space)")
            app.covered(.feature("viewing.display"), via: .model)
        }
    }

    enum WorkspaceScenarios {
        static let all: [Scenario] = [panels, palette, shortcutsSheet, toolbar, themes, settings, welcome]

        static let panels = Scenario(
            "workspace.panels", "Panel headers open, solo and reset; the left panels open and close",
            claims: [.feature("workspace.panels")] + SidebarSection.allCases.map(Claim.section),
        ) { app in
            try app.openWorking()
            try app.main { $0.expandedPanels = [] }
            try app.click(.panelHeader(.detail))
            try app.wait("Detail to open") { $0.expandedPanels.contains(.detail) }
            try app.click(.panelHeader(.detail))
            try app.wait("Detail to close") { !$0.expandedPanels.contains(.detail) }
            try app.set(.exposure, 0.5)
            try app.main { $0.expandedPanels = [.basic] }
            try app.click(.panelHeader(.basic), count: 2)
            try app.wait("Basic to reset") { !$0.isEdited(.exposure) }
            for section in SidebarSection.allCases {
                try app.main { $0.expandedSidebarSections = Set(SidebarSection.allCases) }
                app.pause(0.4)
                try app.click(.sidebarHeader(section), at: CGPoint(x: 0.3, y: 0.5))
                try app.wait("\(section.title) to close") { !$0.expandedSidebarSections.contains(section) }
                app.pause(0.4)
                try app.click(.sidebarHeader(section), at: CGPoint(x: 0.3, y: 0.5))
                try app.wait("\(section.title) to open") { $0.expandedSidebarSections.contains(section) }
                app.covered(.section(section), via: .mouse)
            }
            try app.main { $0.expandedPanels = [.basic, .toneCurve, .colorMixer] }
            app.covered(.feature("workspace.panels"), via: .mouse)
        }

        static let palette = Scenario(
            "workspace.palette", "The command palette: typed values, the slider bar, Find Adjustment",
            claims: [.feature("workspace.palette"), .feature("workspace.find")],
        ) { app in
            try app.openWorking()
            try app.press(.commandPalette)
            try app.wait("the palette") { $0.commandPalette != nil }
            try app.main { $0.commandPalette?.setText("exposure 0.7") }
            app.pause(0.3)
            try app.paletteKey(.submit)
            try app.wait("Exposure 0.7 from the palette") { abs($0.value(.exposure) - 0.7) < 1e-6 }
            if try app.main({ $0.commandPalette != nil }) {
                try app.paletteKey(.escape)
            }
            try app.wait("the palette to close") { $0.commandPalette == nil }
            try app.press(.findAdjustment)
            try app.wait("Find Adjustment") { $0.commandPalette != nil }
            try app.main { $0.commandPalette?.setText("contrast") }
            app.pause(0.3)
            try app.paletteKey(.submit)
            let before = try app.value(.contrast)
            try app.paletteKey(.right([]))
            try app.wait("→ to nudge Contrast in the slider bar") { $0.value(.contrast) != before }
            while try app.main({ $0.commandPalette != nil }) {
                try app.paletteKey(.escape)
            }
            try app.wait("the palette to close") { $0.commandPalette == nil }
            try app.choose(.resetAll)
            app.covered([.feature("workspace.palette"), .feature("workspace.find")], via: .palette)
        }

        static let shortcutsSheet = Scenario(
            "workspace.shortcuts", "⌘/ shows every key in the registry",
            claims: [.feature("workspace.shortcuts")],
        ) { app in
            try app.openWorking()
            try app.press(.showShortcuts)
            try app.wait("the shortcuts sheet") { $0.showShortcuts }
            let listed = ShortcutAction.byCategory.flatMap(\.1).count
            let keyed = ShortcutAction.allCases.filter { !$0.combos.isEmpty }.count
            try app.expect(listed == keyed, "The sheet lists \(listed) of \(keyed) actions with keys")
            try app.main { $0.showShortcuts = false }
            app.covered(.feature("workspace.shortcuts"), via: .key)
        }

        static let toolbar = Scenario(
            "workspace.toolbar", "The toolbar's items are there, and T hides and shows it",
            claims: [.feature("workspace.toolbar")],
        ) { app in
            try app.openWorking()
            let items = try app.main { _ in Views.editorWindow?.toolbar?.items.count ?? 0 }
            try app.expect(items >= 4, "The toolbar has \(items) items")
            try app.press(.toggleToolbar)
            try app.wait("the toolbar to hide") { _ in Views.editorWindow?.toolbar?.isVisible == false }
            try app.press(.toggleToolbar)
            try app.wait("the toolbar to show") { _ in Views.editorWindow?.toolbar?.isVisible == true }
            app.covered(.feature("workspace.toolbar"), via: .key)
        }

        static let themes = Scenario(
            "workspace.themes", "Every theme family, dark and light, applies",
            claims: [.feature("workspace.themes")],
        ) { app in
            try app.openWorking()
            guard let host = app.host else { throw ScenarioSkip("the app didn't hand the driver its theme") }
            let original = try app.main { _ in host.theme.selection }
            for family in ThemeCatalog.families {
                for appearance in ThemeAppearance.allCases {
                    try app.main { _ in
                        var selection = host.theme.selection
                        selection.familyID = family.id
                        selection.appearance = appearance
                        host.theme.selection = selection
                    }
                    app.pause(0.05)
                }
            }
            try app.main { _ in host.theme.selection = original }
            app.covered(.feature("workspace.themes"), via: .model)
        }

        static let settings = Scenario(
            "workspace.settings", "Settings opens from the menu, with the models listed",
            claims: [.feature("workspace.settings")],
        ) { app in
            try app.openWorking()
            let title = try app.main { _ -> String in
                NSApp.mainMenu?.items.first?.submenu?.items.first { $0.title.hasPrefix("Settings") }?.title ?? ""
            }
            try app.expect(!title.isEmpty, "No Settings item in the app menu")
            try app.choose(title)
            try app.wait("the Settings window") { _ in
                NSApp.windows.contains { window in
                    window.isVisible && !(window.windowController is EditorWindowController) && !window.isSheet
                        && window.level == .normal
                }
            }
            try app.main { _ in
                NSApp.windows.first { $0.isVisible && !($0.windowController is EditorWindowController) && !$0.isSheet }?
                    .close()
            }
            app.covered(.feature("workspace.settings"), via: .menu)
        }

        static let welcome = Scenario(
            "workspace.welcome", "Help › Welcome to Redlamp opens the welcome window",
            claims: [],
        ) { app in
            try app.openWorking()
            try app.choose("Welcome to Redlamp")
            try app
                .wait("the welcome window") { _ in
                    NSApp.windows.contains { $0.isVisible && $0.windowController is WelcomeWindowController }
                }
            try app.main { _ in NSApp.windows.first { $0.windowController is WelcomeWindowController }?.close() }
        }
    }

    enum HistoryScenarios {
        static let all: [Scenario] = [undoRedo, snapshots, reset]

        static let undoRedo = Scenario(
            "history.undo-redo", "Each drag is one history step with its values, undone and redone",
            claims: [.feature("history.undo"), .feature("history.history")],
        ) { app in
            try app.openRaw(1)
            try app.main { $0.expandedPanels = [.basic] }
            let start = try app.main { $0.history.count }
            let exposure = try app.value(.exposure), contrast = try app.value(.contrast)
            try app.drag(.slider(.exposure), from: CGPoint(x: 0.5, y: 0.5), by: CGVector(dx: 25, dy: 0))
            try app.drag(.slider(.contrast), from: CGPoint(x: 0.5, y: 0.5), by: CGVector(dx: 25, dy: 0))
            try app.wait("two history steps") { $0.history.count >= start + 2 }
            let last = try app.main { $0.history.last.map { "\($0.title) \($0.before ?? "") \($0.after ?? "")" } ?? "" }
            try app.expect(last.contains("Contrast") && last.contains("→") == false, "The last step reads \(last)")
            try app.press(.undo)
            try app.wait("Contrast undone") { $0.value(.contrast) == contrast }
            try app.choose(.redo)
            try app.wait("Contrast redone") { $0.value(.contrast) != contrast }
            try app.main { model in model.goToHistory(max(start - 1, 0)) }
            try app
                .wait("the step before the drags") { $0.value(.exposure) == exposure && $0.value(.contrast) == contrast
                }
            try app.choose(.resetAll)
            app.covered([.feature("history.undo"), .feature("history.history")], via: .mouse)
        }

        static let snapshots = Scenario(
            "history.snapshots", "A snapshot keeps an edit, and applying it brings it back",
            claims: [.feature("history.snapshots")],
        ) { app in
            try app.openRaw(1)
            try app.set(.vibrance, 33)
            try app.press(.newSnapshot)
            try app.wait("the snapshot") { !$0.snapshots.isEmpty }
            try app.choose(.resetAll)
            try app.wait("the reset") { !$0.isEdited(.vibrance) }
            try app.main { model in model.snapshots.last.map(model.applySnapshot) }
            try app.wait("the snapshot's edit") { abs($0.value(.vibrance) - 33) < 1e-6 }
            try app.main { model in model.snapshots.forEach(model.deleteSnapshot) }
            try app.choose(.resetAll)
            app.covered(.feature("history.snapshots"), via: .key)
        }

        static let reset = Scenario(
            "history.reset", "Reset All and Paste from Previous",
            claims: [.feature("history.reset")],
        ) { app in
            try app.openRaw(1)
            try app.set(.saturation, 20)
            // Straight to another photo: Paste from Previous takes the photo just left.
            let next = try app.main { model -> URL? in
                let raws = model.items
                    .filter { ["ARW", "RAF", "CR3", "NEF", "DNG"].contains($0.url.pathExtension.uppercased()) }
                return raws.first { $0.url != model.selection }?.url
            }
            guard let next else { throw ScenarioFailure("No other raw") }
            try app.main { $0.select(next) }
            try app.settle()
            try app.choose(.pastePrevious)
            try app.wait("the previous photo's edit pasted") { abs($0.value(.saturation) - 20) < 1e-6 }
            try app.choose(.resetAll)
            try app.wait("Reset All") { !$0.isEdited(.saturation) }
            try app.openRaw(1)
            try app.choose(.resetAll)
            app.covered(.feature("history.reset"), via: .menu)
        }
    }
#endif
