#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import RedlampDesign
    @_spi(Harness) import RedlampEngineAPI
    import RedlampRecipes
    @_spi(Harness) import RedlampUI

    enum DevelopScenarios {
        static let all: [Scenario] = [
            whiteBalance,
            treatment,
            reproduction,
            toneAndPresence,
            negativeDehaze,
            toneCurve,
            colorMixer,
            colorGrading,
            detail,
            lensAndTransform,
            LensProfileScenarios.choice,
            effectsAndCalibration,
            border,
            firmwareModel,
            adobeProfiles,
            panelSwitches,
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
            // At 60 of 200 its thumb is 0.3 of the way along the track.
            try app.click(.identifier("baseLook.amount.track"), at: CGPoint(x: 0.3, y: 0.5), count: 2)
            try app.wait("a double-click on the thumb to return the Base Look Amount to 100") {
                $0.baseLook.amount == 100
            }
            try app.main { $0.setBaseLook(BuiltInBaseLook.color.reference) }
            app.covered(.feature("develop.treatment"), via: .key)
        }

        /// L* 50 is 18.4% grey, 0.03 stops above the 18% grey the stops count from. The popover offers
        /// 40 to start, so a patch that reads 50 shows the typed value reached it.
        static let reproduction = Scenario(
            "develop.reproduction",
            "Redlamp Reproduction from the palette, calibrated on a patch: its L* and stops, and the status line",
            claims: [.feature("develop.reproduction")],
        ) { app in
            try app.openWorking()
            // A retry finds what the first attempt left: the photo's edit and the camera's calibration.
            try app.main { $0.forgetCalibration() }
            try app.choose(.resetAll)
            try app.press(.commandPalette)
            try app.wait("the palette") { $0.commandPalette != nil }
            try app.main { $0.commandPalette?.setText(BuiltInBaseLook.reproduction.name) }
            try app.wait("Redlamp Reproduction chosen in the palette") {
                $0.commandPalette?.selectedItem?.kind == .baseLook(BuiltInBaseLook.reproduction.rawValue)
            }
            // The palette previews its selection, so the photo already shows the look.
            try app.paletteKey(.submit)
            var anchored = false
            for _ in 0 ..< 50 where !anchored {
                anchored = try app.main { $0.baseLook.isReproduction && $0.recipe.exposureAnchor?.source == .estimated }
                app.pause(0.1)
            }
            let state = try app.main { model in
                "\(model.baseLook.name), anchor \(String(describing: model.recipe.exposureAnchor)), "
                    + "steps \(model.history.map(\.title)), palette \(model.commandPalette == nil ? "closed" : "open")"
            }
            try app.expect(anchored, "Redlamp Reproduction with the camera's estimated anchor, not \(state)")
            if try app.main({ $0.commandPalette != nil }) {
                try app.paletteKey(.escape)
            }
            try app.wait("the palette to close") { $0.commandPalette == nil }
            // White balanced on the patch first, as the design asks: CIELAB's D50 white moves the
            // luminance of a colour that isn't neutral, by 0.1 L* for a b* of 8.
            try app.press(.whiteBalanceSelector)
            try app.wait("the eyedropper") { $0.eyedropperActive }
            try app.click(.canvas, at: CGPoint(x: 0.5, y: 0.5))
            try app.wait("white balanced on the patch") { !$0.eyedropperActive && $0.whiteBalanceMode == .custom }
            try app.main { $0.calibrationReference = 40 }
            try app.choose(.calibrateFromTarget)
            try app.wait("Calibrate from Target") { $0.calibrationTargetActive }
            try app.click(.canvas, at: CGPoint(x: 0.5, y: 0.5))
            try app.wait("the patch to be measured") { $0.calibrationTarget != nil }
            try app.wait("the popover asking for its reference L*") { _ in Views.popoverWindow != nil }
            app.pause(0.5)
            let focused = try app.main { _ in Views.popoverWindow?.firstResponder is NSText }
            try app.expect(focused, "The popover's reference L* field isn't ready to type in")
            try app.typeInPopover("50\r")
            try app.wait("the camera calibrated from the target") {
                $0.calibrationTarget == nil && $0.recipe.exposureAnchor?.source == .target
            }
            try app.waitForCanvas()
            try app.hover(.canvas, at: CGPoint(x: 0.5, y: 0.5))
            try app.wait("the readout in stops") { $0.pixelReadout?.stops != nil }
            let parts = try app.main { model in
                model.pixelReadout
                    .map { EditorModel.readoutParts($0, lab: true, approximate: model.readoutIsApproximate) }
            }
            try app.expect(
                parts?.first == "L* 50.0" && parts?.last == "+0.03 EV",
                "The patch reads \(parts ?? []) rather than L* 50.0 and +0.03 EV",
            )
            let status = try app.main { $0.calibrationStatus }
            try app.expect(status.hasPrefix("Calibrated for"), "The status line says \(status)")
            try app.drag(.slider(.contrast), from: CGPoint(x: 0.5, y: 0.5), by: CGVector(dx: 30, dy: 0))
            try app.wait("the status line to name Contrast") { $0.reproductionChanges?.contains("Contrast") == true }
            try app.main { model in
                model.hoverReadout(at: nil)
                model.forgetCalibration()
            }
            try app.choose(.resetAll)
            try app.wait("Redlamp Color again") { $0.baseLook == BuiltInBaseLook.color.reference }
            app.covered(.feature("develop.reproduction"), via: .mouse)
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

        /// TON-55: from process 18, Dehaze below zero adds haze where the haze map finds it, lifting the shadows
        /// gently;
        /// an edit at process 17 keeps the even veil toward grey that 17 rendered, which lifts them further. Each is
        /// measured against its own Dehaze 0.
        static let negativeDehaze = Scenario(
            "develop.negative-dehaze",
            "Dehaze dragged and typed below zero adds haze, as History steps; on the edit moved to process 17 the same "
                + "Dehaze renders 17's even veil, and Undo brings back 18's",
            claims: [.parameter(.dehaze), .feature("develop.presence")],
        ) { app in
            try app.openWorking()
            try app.choose(.resetAll)
            try app.main { $0.expandedPanels = [.basic] }
            try app.wait("the edit at process 18 or later, without Dehaze") { model in
                model.recipe.processVersion >= 18 && model.value(.dehaze) == 0
            }
            let clear = try app.settledHistogram()
            @MainActor func lastStep(_ model: EditorModel) -> UUID? {
                model.history.last?.id
            }

            let undragged = try app.main(lastStep)
            try app.drag(.slider(.dehaze), from: CGPoint(x: 0.5, y: 0.5), by: CGVector(dx: -30, dy: 0))
            try app.wait("Dehaze dragged below zero, as a History step") { model in
                model.value(.dehaze) < 0 && lastStep(model) != undragged && model.history.last?.title == "Dehaze"
            }
            app.covered([.parameter(.dehaze), .feature("develop.presence")], via: .mouse)
            let dragged = try app.main(lastStep)
            try typeValue(-60, into: .dehaze, app: app)
            try app.wait("Dehaze typed, as a History step") { model in
                lastStep(model) != dragged && model.history.last?.title == "Dehaze"
            }
            app.covered(.parameter(.dehaze), via: .key)
            let hazed = try app.settledHistogram()

            try app.expectRenders("the edit moved to process 17") { try app.main { $0.setProcessVersion(17) } }
            let even = try app.settledHistogram()
            try app.click(.sliderLabel(.dehaze), count: 2)
            try app.wait("a double-click on its label to reset Dehaze") { $0.value(.dehaze) == 0 }
            let evenClear = try app.settledHistogram()
            let (veil, evenVeil) = (Tones(hazed), Tones(even))
            let (lift, evenLift) = (veil.darkest - Tones(clear).darkest, evenVeil.darkest - Tones(evenClear).darkest)
            app.recorder.write("note", [
                "Dehaze -60 against 0": "process 18: \(Tones(clear)) to \(veil); process 17: \(Tones(evenClear)) to "
                    + "\(evenVeil)",
            ])
            try app.expect(hazed != clear && veil.mean > Tones(clear).mean, "Dehaze -60 at 18 added no haze: \(veil)")
            try app.expect(even != hazed, "At process 17, Dehaze -60 renders as at 18")
            try app.expect(
                evenLift > lift + 0.04,
                "Under Dehaze -60 the darkest 2 % rose \(evenLift) at 17 and \(lift) at 18, where 17's even veil lifts "
                    + "them further",
            )

            try app.press(.undo)
            try app.wait("⌘Z: Dehaze -60 again at 17") { model in
                abs(model.value(.dehaze) + 60) < 1e-6 && model.recipe.processVersion == 17
            }
            try app.expect(try app.settledHistogram() == even, "Undo to Dehaze -60 at 17 renders otherwise than before")
            try app.press(.undo)
            try app.wait("⌘Z: back at process 18") { model in
                abs(model.value(.dehaze) + 60) < 1e-6 && model.recipe.processVersion >= 18
            }
            try app.expect(try app.settledHistogram() == hazed, "Back at 18, Dehaze -60 renders otherwise than before")
            try app.choose(.resetAll)
        }

        /// A render's tones from its histogram: its mean luminance and where its darkest 2 % end, 0 ... 1.
        struct Tones: CustomStringConvertible {
            let mean: Double
            let darkest: Double

            init(_ histogram: Histogram) {
                let counts = histogram.luminance.map(Double.init)
                let total = max(counts.reduce(0, +), 1)
                let top = Double(Histogram.binCount - 1)
                mean = counts.enumerated().reduce(0) { $0 + Double($1.offset) * $1.element } / total / top
                var running = 0.0
                let bin = counts.firstIndex { count in
                    running += count
                    return running >= total * 0.02
                } ?? 0
                darkest = Double(bin) / top
            }

            var description: String {
                String(format: "mean %.3f, darkest 2 %% %.3f", mean, darkest)
            }
        }

        static let toneCurve = Scenario(
            "develop.tone-curve",
            "Tone Curve: the region sliders, the split points, a point curve, red's own curve dragged on the graph "
                + "and undone, and Reset Tone Curve from its header",
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
            app.covered(.feature("develop.tone-curve"), via: .model)
            // Red's own curve (TON-40): Point and Red from the panel's menus, a point dragged up the
            // middle of the graph, the photo's reds lifted, and Undo.
            try app.choose("Point", inMenuOf: .identifier("curve.mode"))
            try app.choose("Red", inMenuOf: .identifier("curve.channel"))
            let reds = try app.main { $0.histogram.red }
            try app.expectRenders("a point dragged up red's curve") {
                try app.drag(.identifier("curve.graph"), from: CGPoint(x: 0.5, y: 0.5), by: CGVector(dx: 0, dy: 40))
            }
            let red = try app.main { $0.pointCurve(.red) }
            try app.expect(red.count == 3 && red[1].y > 0.55, "Red's curve is \(red), not raised in its middle")
            try app.expect(
                try app.main { $0.pointCurve } == EditRecipe.linearPointCurve, "Dragging red's curve moved the RGB one",
            )
            try app.wait("the photo's reds to lift") { $0.histogram.red != reds }
            try app.press(.undo)
            try app.wait("Undo to straighten red's curve") { $0.pointCurve(.red) == EditRecipe.linearPointCurve }
            try app.choose("RGB", inMenuOf: .identifier("curve.channel"))
            try app.choose("Parametric", inMenuOf: .identifier("curve.mode"))
            app.covered(.feature("develop.tone-curve"), via: .mouse)
            try app.choose(.resetAll)
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
                abs($0.sliderValue(parameter) - value) < 1e-6
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

        /// UX-30: a panel's switch turns its settings off and on, each a History step, without
        /// expanding the panel; Undo takes it back, and a change in the panel turns it on.
        static let panelSwitches = Scenario(
            "develop.panel-switches",
            "Panel switches: Effects' eye turns its vignette off and on in the photo, as History steps with Undo",
            claims: [.feature("workspace.panels"), .feature("develop.effects")],
            needsFocus: true,
        ) { app in
            try app.openWorking()
            try app.choose(.resetAll)
            try app.main { $0.expandedPanels = [] }
            try app.set(.vignetteAmount, -80)
            app.pause(0.3)
            let vignetted = try app.main { $0.histogram }
            try app.expectRenders("Effects off") {
                try app.click(.identifier("panel.effects.switch"))
            }
            try app.wait("Effects off, as one History step, without opening the panel") { model in
                !model.isOn(.effects) && model.history.last?.name == "Effects Off" && model.expandedPanels.isEmpty
                    && model.value(.vignetteAmount) == -80
            }
            try app.wait("the photo without its vignette") { $0.histogram != vignetted }
            let plain = try app.main { $0.histogram }
            try app.expectRenders("Undo turning Effects back on") {
                try app.press(.undo)
            }
            try app.wait("Effects on again") { $0.isOn(.effects) }
            try app.wait("the vignette back") { $0.histogram != plain }
            try app.click(.identifier("panel.effects.switch"))
            try app.wait("Effects off again") { !$0.isOn(.effects) }
            try app.click(.identifier("panel.effects.switch"))
            try app.wait("Effects On, as a History step") { $0.isOn(.effects) && $0.history.last?.name == "Effects On" }
            // The header's menu turns panels off and on too, and changing a setting of a panel that's off
            // turns it back on.
            try app.focus()
            try app.rightClick(.panelHeader(.detail), choosing: "Turn Detail Off")
            try app.wait("Detail off from the header's menu") { !$0.isOn(.detail) }
            try app.set(.sharpenAmount, 60)
            try app.wait("Detail on again with the change") { $0.isOn(.detail) }
            try app.choose(.resetAll)
            try app.wait("every panel on after Reset All") { $0.panelsOff.isEmpty }
            app.covered([.feature("workspace.panels"), .feature("develop.effects")], via: .mouse)
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
                .parameter(.frameSize),
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
            // The frame's size shows only on an edit with a frame over the photo, so smoke.panel-sliders doesn't find
            // it.
            try app.expect(
                try app.value(.frameSize) != ParameterID.frameSize.spec.defaultValue, "The frame's size didn't move",
            )
            app.covered(.parameter(.frameSize), via: .model)
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

        /// TON-53, TON-54: a border grows the canvas around the photo; its sliders; its colour from the panel's
        /// swatches; film's Crop to Format; the panel's switch takes it away.
        static let border = Scenario(
            "develop.border",
            "Border: a white 4:5 border grows the canvas, its sliders move and reset, a swatch turns it black, film "
                + "crops to its format, the switch hides it",
            claims: [.feature("develop.border"), .panel(.border)] + PanelID.border.parameters.map(Claim.parameter),
            needsFocus: true,
        ) { app in
            /// The style's sliders, each moved and reset through the model: smoke.panel-sliders drags the panels' own,
            /// but these show only for a style that has them, in the panel's SwiftUI options, which the driver can't
            /// find by identifier.
            func exercise(_ parameters: [ParameterID]) throws {
                for parameter in parameters {
                    let spec = parameter.spec
                    let value = spec.clamp(spec.defaultValue + (spec.range.upperBound - spec.defaultValue) / 2)
                    try app.set(parameter, value == spec.defaultValue ? spec.range.lowerBound : value)
                    try app.main { $0.reset(parameter) }
                    app.covered(.parameter(parameter), via: .model)
                }
            }
            try app.openWorking()
            try app.choose(.resetAll)
            // The last panel: alone, with the others collapsed above it, so its controls are on screen.
            try app.main { $0.expandedPanels = [.border] }
            let photo = try app.main { $0.canvas.imageSize }
            let clippedWithout = try app.main { $0.histogram.highlightsClipped }
            try app.expectRenders("a white 4:5 border") {
                try app.main { model in
                    model.setBorderStyle(.plain)
                    model.setBorderShape(.fourByFive)
                    model.setBorderOrientation(.portrait)
                }
            }
            try app.wait("the canvas grows to 4:5 around the photo") { model in
                let size = model.canvas.imageSize
                return size.width >= photo.width && abs(size.aspectRatio - 0.8) < 0.01
            }
            try app.wait("the histogram counts the photo, not the white border") {
                $0.histogram.highlightsClipped == clippedWithout
            }
            // The style, shape and orientation menus are SwiftUI's, which macOS 27 draws itself (UX-44).
            app.covered([.borderStyle, .borderShape, .borderOrientation].map(Claim.parameter), via: .model)
            try app.main { $0.setBorderShape(.custom) }
            try exercise([
                .borderRatioWidth, .borderRatioHeight, .borderSize, .borderOffsetY, .borderOffsetX,
                .borderKeylineWidth, .borderKeylineGap,
            ])
            try app.main { $0.setBorderShape(.fourByFive) }
            // The swatches and Crop to Format are SwiftUI buttons, which the mouse can't find by identifier.
            try app.main { $0.setBorderColor(.black, keyline: false) }
            try app.wait("a black border, as one History step") { model in
                model.value(.borderRed) < 30 && model.history.last?.name == "Border Color"
            }
            app.covered([.borderRed, .borderGreen, .borderBlue].map(Claim.parameter), via: .model)
            try app.main { $0.setBorderColor(.white, keyline: true) }
            try app.wait("a white keyline") { $0.value(.borderKeylineRed) > 200 }
            app.covered([.borderKeylineRed, .borderKeylineGreen, .borderKeylineBlue].map(Claim.parameter), via: .model)
            try app.expectRenders("35 mm film") { try app.main { $0.setBorderStyle(.film35) } }
            try exercise([.borderFrameNumber])
            // Edge Print is a SwiftUI switch, which macOS 27 draws itself.
            try app.main { $0.setSliderValue(.borderEdgePrint, 0) }
            try app.wait("the edge print off") { $0.value(.borderEdgePrint) < 0.5 }
            app.covered(.parameter(.borderEdgePrint), via: .model)
            try app.main { $0.cropToBorderFormat() }
            try app.wait("the crop at 2:3") { model in
                let crop = model.recipe.crop
                let aspect = model.pixelAspect(of: crop)
                return abs(aspect - 1.5) < 0.01 || abs(aspect - 2.0 / 3) < 0.01
            }
            try app.click(.identifier("panel.border.switch"))
            try app.wait("Border off: the canvas is the photo again") { model in
                !model.isOn(.border) && !model.hasBorder
            }
            try app.choose(.resetAll)
            app.covered([.feature("develop.border"), .panel(.border)], via: .mouse)
        }

        static let firmwareModel = Scenario(
            "develop.firmware-model",
            "The firmware film model turned on in Settings, a simulation and its settings from the Camera Recipe group",
            claims: [.feature("develop.firmware-model")],
            needsFocus: true,
        ) { app in
            let folder = FileManager.default.temporaryDirectory.appending(path: "firmware-\(UUID().uuidString)")
            try FirmwareFilmModel.Files.identity().write(to: folder)
            // Left on, the switch would resolve later scenarios' recipe cards through the model.
            defer {
                try? app.main { _ in
                    UserDefaults.standard.set(false, forKey: FirmwareFilmModel.enabledKey)
                    UserDefaults.standard.removeObject(forKey: FirmwareFilmModel.folderKey)
                }
                try? FileManager.default.removeItem(at: folder)
            }
            try app.main { _ in UserDefaults.standard.set(folder.path, forKey: FirmwareFilmModel.folderKey) }
            try app.openSettings(tab: "Experimental")
            try app.clickInSettings("settings.firmware-model", fallback: 0)
            try app.wait("the model read from its folder") { $0.usesFirmwareModel }
            try app.closeSettings()
            try app.openWorking()
            try app.main { $0.expandedPanels.insert(.effects) }
            try app.focus()
            try app.expectRenders("the Standard simulation") {
                try app.chooseFirmware("Standard", in: "simulation") { $0.firmwareSettings?.simulation == .standard }
            }
            try app.expectRenders("Highlight +1") {
                try app.chooseFirmware("+1.0", in: "highlight") { $0.firmwareSettings?.highlight == 1 }
            }
            try app.chooseFirmware("ACROS", in: "simulation") {
                $0.firmwareSettings?.simulation == .acros && $0.firmwareSettings?.highlight == 1
            }
            try app.expectRenders("Warm/Cool +2") {
                try app.chooseFirmware("+2", in: "warm-cool") { $0.firmwareSettings?.warmCool == 2 }
            }
            try app.chooseFirmware("None", in: "simulation") { $0.baseLook == BuiltInBaseLook.color.reference }
            try app.choose(.resetAll)
            try app.openSettings(tab: "Experimental")
            try app.clickInSettings("settings.firmware-model", fallback: 0)
            try app.wait("the model put away") { !$0.usesFirmwareModel }
            try app.closeSettings()
            app.covered(.feature("develop.firmware-model"), via: .mouse)
        }

        static let adobeProfiles = Scenario(
            "develop.adobe-profiles",
            "Adobe profiles chosen from a folder, in the Base Look menu at an Amount, and Redlamp's look standing in "
                + "once they're gone",
            claims: [.feature("develop.adobe-profiles")],
        ) { app in
            // Synthetic profiles, made for the working photo's camera: Adobe's files are never committed.
            let folder = app.runDirectory.appending(path: "Camera Profiles")
            defer { try? FileManager.default.removeItem(at: folder) }
            try app.openWorking()
            let camera = try app
                .main { model in model.info.flatMap { $0.isRaw && $0.model != nil ? $0.cameraName : nil } }
            guard let adobeName = camera
            else { throw ScenarioSkip("the working photo isn't a raw that names its camera") }
            let matrix: [Double] = [0.6722, -0.0635, -0.0963, -0.4287, 1.246, 0.2028, -0.0908, 0.2162, 0.5668]
            let forward: [Double] = [0.7978, 0.1352, 0.0313, 0.288, 0.7119, 0.0001, 0, 0, 0.8251]
            let files: [(String, Data)] = [
                ("\(adobeName) Adobe Standard.dcp", SyntheticCameraProfiles.dcp(
                    name: "Adobe Standard", camera: adobeName, colorMatrices: [matrix], illuminants: [21],
                    forwardMatrices: [forward], lookTable: .uniform(shift: SIMD3(4, 1.1, 1)),
                )),
                ("Adobe Color.xmp", SyntheticCameraProfiles.xmpLook(
                    name: "Adobe Color", lookTable: .uniform(shift: SIMD3(-6, 1.25, 1)),
                    toneCurve: [SIMD2(0, 0), SIMD2(64, 52), SIMD2(192, 205), SIMD2(255, 255)],
                )),
                ("Vintage 01.xmp", SyntheticCameraProfiles.xmpLook(
                    name: "Vintage 01", baseProfile: nil, group: "Vintage", supportsAmount: true,
                    rgbTable: .grid(divisions: 9) { SIMD3($0.x * 0.9 + 0.08, $0.y * 0.85 + 0.06, $0.z * 0.7 + 0.12) },
                )),
            ]
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (file, data) in files {
                try data.write(to: folder.appending(path: file))
            }
            try app.main { model in _ = Task { await model.chooseCameraProfiles([folder]) } }
            try app
                .wait("\(adobeName)'s profiles in the Base Look menu", timeout: 20) { $0.cameraProfileLooks.count == 3 }
            let looks = try app.main { $0.cameraProfileLooks }
            guard let color = looks.first(where: { $0.reference.name == "Adobe Color" }),
                  let vintage = looks.first(where: { $0.reference.name == "Vintage 01" })
            else { throw ScenarioFailure("The menu lists \(looks.map(\.reference.name))") }
            try app.expectRenders("Adobe Color") { try app.main { $0.setBaseLook(color.reference) } }
            try app.expect(
                try app.main { !$0.isBaseLookMissing && $0.baseLook.staysOnThisMac && $0.baseLook.contentHash == nil },
                "Adobe Color should render here, and never leave this Mac",
            )
            try app.expectRenders("Adobe Color at 150") { try app.main { $0.setBaseLookAmount(150) } }
            try app.expectRenders("Vintage 01") { try app.main { $0.setBaseLook(vintage.reference) } }
            try app.main { $0.setBaseLook(color.reference) }
            // Taken off the Mac: Redlamp Color stands in, and the photo says so.
            try FileManager.default.removeItem(at: folder)
            try app.expectRenders("Redlamp Color standing in") {
                try app.main { model in _ = Task { await model.refreshCameraProfiles() } }
                try app.wait("the stand-in's notice") { $0.cameraProfileStandIn == .color }
            }
            try app.choose(.resetAll)
            app.covered(.feature("develop.adobe-profiles"), via: .model)
        }

        static let histogram = Scenario(
            "develop.histogram",
            "Dragging the histogram moves its region's slider; under it, the photo's values under the pointer",
            claims: [.feature("develop.histogram")],
            needsFocus: true,
        ) { app in
            try app.openWorking()
            for parameter in [ParameterID.shadows, .exposure, .highlights] {
                let before = try app.value(parameter)
                try app.drag(.histogram(parameter), from: CGPoint(x: 0.5, y: 0.5), by: CGVector(dx: 25, dy: 0))
                try app.wait("the histogram to move \(parameter.spec.label)") { $0.value(parameter) != before }
            }
            try app.choose(.resetAll)
            try app.waitForCanvas()
            try app.focus()
            try app.hover(.canvas, at: CGPoint(x: 0.5, y: 0.5))
            try app.wait("the readout of the photo under the pointer") { $0.pixelReadout != nil }
            let lab = try app.main { $0.showsLabReadout }
            _ = try app.rightClick(.identifier("histogram"), choosing: ShortcutAction.labReadout.title)
            try app.wait("the readout to switch") { $0.showsLabReadout != lab }
            // The readout went as the pointer left the photo for the histogram's menu: as the menu closes, the canvas
            // hears where the Mac's own pointer is, which the driver doesn't move. Back over the photo, it shows again.
            try app.hover(.canvas, at: CGPoint(x: 0.45, y: 0.5))
            try app.wait("the readout under the pointer, back over the photo") { $0.pixelReadout != nil }
            let readout = try app.main { $0.pixelReadout }
            try app.expect(
                readout.map { (0 ... 100).contains($0.lab.x) && $0.rgb.min() >= 0 && $0.rgb.max() <= 100 } == true,
                "The readout is out of range: \(String(describing: readout))",
            )
            try app.main { model in
                model.showsLabReadout = lab
                model.hoverReadout(at: nil)
            }
            app.covered(.feature("develop.histogram"), via: .mouse)
        }
    }

    enum ViewingScenarios {
        static let all: [Scenario] = [zoomAndNavigator, zoomPastFit, beforeAfter, overlays, display]

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

        /// UX-57: zooming out past Fit, to see the photo as from a distance or on a small screen.
        static let zoomPastFit = Scenario(
            "viewing.zoom-past-fit",
            "The wheel and a pinch hold at Fit for a few steps, zooming out to a quarter of it and coming back in",
            claims: [.feature("viewing.zoom")],
        ) { app in
            try app.openWorking()
            try app.wait("Fit") { $0.canvas.zoom == .fit }
            /// Whether the zoom has come to `fraction` of Fit.
            func settles(at fraction: Double) -> @MainActor (EditorModel) -> Bool {
                { abs($0.canvas.pixelScale / $0.canvas.fitScale - fraction) < 1e-3 }
            }
            // Six notches out hold at Fit, and the seventh goes on a notch below it.
            try app.turnWheel(.canvas, notches: -7)
            try app.wait("seven notches out to end a notch below Fit", until: settles(at: pow(2, -0.25)))
            try app.turnWheel(.canvas, notches: -10)
            try app.wait("the wheel to stop at a quarter of Fit", until: settles(at: 0.25))
            let centred = try app.main { model -> Bool in
                let stage = model.canvas.stage(in: model.canvas.viewSize)
                let photo = model.canvas.imageRect(in: model.canvas.viewSize)
                return abs(photo.midX - stage.midX) < 0.5 && abs(photo.midY - stage.midY) < 0.5
            }
            try app.expect(centred, "A quarter of Fit isn't centred on the stage")
            // The engine fits the photo in the size asked for, to the pixel.
            try app.wait("a frame the size the photo shows") { model in
                guard let frame = model.frames.current?.size else { return false }
                let asked = model.canvas.renderSize
                return abs(frame.width - asked.width) <= 1 && abs(frame.height - asked.height) <= 1
            }
            // Coming back in holds at Fit too: eight notches reach it, six hold, and the fifteenth ends a notch above.
            try app.turnWheel(.canvas, notches: 14)
            try app.wait("fourteen notches in to hold at Fit", until: settles(at: 1))
            try app.turnWheel(.canvas, notches: 1)
            try app.wait("the fifteenth notch in to end a notch above Fit", until: settles(at: pow(2, 0.25)))
            try app.press(.toggleZoom)
            try app.wait("Fit") { $0.canvas.zoom == .fit }
            // From Fit, zooming in isn't held.
            try app.turnWheel(.canvas, notches: 1)
            try app.wait("a notch in from Fit to zoom in at once", until: settles(at: pow(2, 0.25)))
            try app.press(.toggleZoom)
            try app.wait("Fit") { $0.canvas.zoom == .fit }
            // A pinch holds for as far as a notch zooms: eight steps of 5% end 1.37 notches below Fit.
            try app.pinch(.canvas, by: Array(repeating: -0.05, count: 8))
            let pinched = pow(2, -(8 * 4 * log2(1 / 0.95) - 1) / 4)
            try app.wait("a pinch past the hold to zoom out below Fit", until: settles(at: pinched))
            // Pinching back in holds at Fit for a notch as well: of seven steps of 10%, 3.85 notches, 1.48 pass it.
            try app.pinch(.canvas, by: Array(repeating: 0.1, count: 7))
            let pinchedIn = pow(2, (7 * 4 * log2(1.1) - (8 * 4 * log2(1 / 0.95) - 1) - 1) / 4)
            try app.wait("pinching in to hold at Fit and pass it", until: settles(at: pinchedIn))
            // ⌘- steps past Fit to a half and a quarter of it, and ⌘= comes back; Z still goes to 1:1 and Fit.
            try app.press(.toggleZoom)
            try app.wait("Fit") { $0.canvas.zoom == .fit }
            try app.press(.zoomOut)
            try app.wait("⌘- to go to half of Fit", until: settles(at: 0.5))
            try app.press(.zoomOut)
            try app.wait("⌘- to go to a quarter of Fit", until: settles(at: 0.25))
            try app.press(.zoomIn)
            try app.wait("⌘= to come back to half of Fit", until: settles(at: 0.5))
            try app.press(.toggleZoom)
            try app.wait("1:1") { $0.canvas.zoom == .oneToOne }
            try app.press(.toggleZoom)
            try app.wait("Fit") { $0.canvas.zoom == .fit }
            app.covered(.feature("viewing.zoom"), via: .mouse)
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
            try app.pressFullScreenPreview()
            try app.wait("the full-screen preview") { $0.isPresenting }
            try app.pressFullScreenPreview()
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
        static let all: [Scenario] = [panels, hidePanels, palette, shortcutsSheet, toolbar, themes, settings, welcome]

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

        /// #358: Tab hides the side panels for a bigger view of the photo, as in Lightroom. The working
        /// photo is a landscape one, which at Fit is as wide as the room between the panels.
        static let hidePanels = Scenario(
            "workspace.hide-panels",
            "Tab hides the side panels, and the photo grows into their room, rendered again at its new size",
            claims: [.feature("workspace.panels")],
        ) { app in
            try app.openWorking()
            try app.waitForCanvas()
            /// On screen at the size the stage needs, to the pixel the engine rounds to.
            @MainActor func rendered(_ model: EditorModel) -> Bool {
                guard let frame = model.frames.current?.size else { return false }
                let target = model.canvas.renderTarget.size
                return abs(frame.width - target.width) <= 1 && abs(frame.height - target.height) <= 1
            }
            try app.wait("the photo rendered at Fit", until: rendered)
            let (shown, fit) = try app.main { model in
                (model.canvas.stageInsets, model.canvas.imageRect(in: model.canvas.viewSize))
            }

            try app.press(.toggleSidePanels)
            try app.wait("Tab to give the photo the panels' room, rendered again at its new size") { model in
                let canvas = model.canvas
                let photo = canvas.imageRect(in: canvas.viewSize)
                let stage = canvas.stage(in: canvas.viewSize)
                return !model.leftPanelVisible && !model.rightPanelVisible
                    && canvas.stageInsets.leading < shown.leading && canvas.stageInsets.trailing < shown.trailing
                    && photo.width > fit.width + 1
                    && (abs(photo.width - stage.width) < 0.5 || abs(photo.height - stage.height) < 0.5)
                    && rendered(model)
            }
            try app.press(.toggleSidePanels)
            try app.wait("Tab again to bring the panels back, and the photo's size with them") { model in
                model.leftPanelVisible && model.rightPanelVisible && model.canvas.stageInsets == shown
                    && model.canvas.imageRect(in: model.canvas.viewSize) == fit && rendered(model)
            }
            app.covered(.feature("workspace.panels"), via: .key)
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
            let items = try app.main { _ in Views.editorWindow?.toolbar?.items.map(\.itemIdentifier.rawValue) ?? [] }
            try app.expect(items.count >= 4, "The toolbar has \(items.count) items")
            try app.expect(!items.contains("openFolder"), "The toolbar has an Open Folder button: \(items)")
            let library = try app.frame(of: .identifier("module.library"))
            let develop = try app.frame(of: .identifier("module.develop"))
            let width = try app.main { _ in Views.editorWindow?.frame.width ?? 0 }
            let middle = (library.minX + develop.maxX) / 2
            try app.expect(
                abs(middle - width / 2) <= 2,
                "The module picker's middle at \(middle) of a \(width)-point window",
            )
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

    extension RunningApp {
        /// The firmware model's pickers in the Camera Recipe group, in the order of its rows
        /// (`FirmwareModelControls`): Simulation alone until one is chosen, then its settings, and
        /// the toning of a black-and-white one.
        private static let firmwareRows = [
            "simulation", "highlight", "shadow", "color", "dynamic-range", "warm-cool", "magenta-green",
        ]

        /// Chooses `title` in the firmware model's picker `develop.firmware-model.<control>` in the
        /// Camera Recipe group as the mouse does, and waits until `done`: a click on the picker opens
        /// its menu, where the keyboard chooses the item, as in `choose(_:inMenuOf:)`.
        func chooseFirmware(
            _ title: String, in control: String, until done: @escaping @MainActor (EditorModel) -> Bool,
        ) throws {
            let identifier = "develop.firmware-model.\(control)"
            do {
                try wait("the \(identifier) picker") { (try? Self.firmwarePicker(control, in: $0)) != nil }
            } catch {
                _ = try main { try Self.firmwarePicker(control, in: $0) }
                throw error
            }
            let opened = OpenedMenu()
            try main { _ in opened.watch { menu in opened.chose = Menus.chooseByKeys(title, in: menu) } }
            defer { try? main { _ in opened.stop() } }
            // The menu tracks inside the press.
            post { model in
                guard let picker = try? Self.firmwarePicker(control, in: model) else { return }
                Views.tap(at: picker.point, inWindow: picker.window, clicks: 1, modifiers: [])
            }
            do {
                try wait("the \(identifier) menu to open") { _ in opened.menu != nil }
            } catch {
                let point = try main { try Self.firmwarePicker(control, in: $0).point }
                throw ScenarioFailure("A click on \(identifier) at \(Views.describe(point)) opened no menu")
            }
            try wait("the \(identifier) menu to close") { _ in opened.closed }
            let (items, chose) = try main { _ in (opened.items.map(\.title), opened.chose) }
            try expect(chose, "\(identifier)'s menu has no \(title): \(items)")
            try wait("\(title) in \(identifier)", until: done)
        }

        /// Where the firmware model's picker `control` is, in the middle of its row of the Camera
        /// Recipe group, scrolled into view: its window and the point there. macOS 27's SwiftUI draws
        /// the pickers itself, with no AppKit control under them and, in the app's own process, no
        /// accessibility to find them by, so the place is worked out from the group's rows, each a
        /// `ControlRow`: its label, `Metrics.labelWidth` wide, then the picker after `Metrics.rowSpacing`.
        /// Where a view carries the picker's identifier, the place must be on it.
        @MainActor private static func firmwarePicker(_ control: String, in model: EditorModel) throws
            -> (window: Int, point: NSPoint) {
            guard let window = Views.editorWindow, let group = firmwareGroup(in: window) else {
                throw ScenarioFailure("The Effects panel shows no Camera Recipe group")
            }
            let rows = model.firmwareSettings.map { $0.simulation.isMonochrome ? 7 : 5 } ?? 1
            guard let row = firmwareRows.firstIndex(of: control), row < rows else {
                throw ScenarioFailure("The Camera Recipe group shows \(firmwareRows.prefix(rows)), not \(control)")
            }
            func band() -> NSRect {
                let frame = group.convert(group.bounds, to: nil)
                let height = frame.height / CGFloat(rows)
                return NSRect(
                    x: frame.minX, y: frame.maxY - height * CGFloat(row + 1), width: frame.width, height: height,
                )
            }
            // Until the panel's column lays the group out again for the rows the model added.
            guard (20 ... 40).contains(band().height) else {
                throw ScenarioFailure(
                    "The Camera Recipe group's \(rows) rows are \(Int(band().height.rounded())) points high each",
                )
            }
            group.scrollToVisible(group.convert(band(), from: nil))
            window.contentView?.layoutSubtreeIfNeeded()
            let point = NSPoint(x: band().minX + Metrics.labelWidth + Metrics.rowSpacing + 16, y: band().midY)
            let identifier = "develop.firmware-model.\(control)"
            if let picker = Views.all(NSView.self, in: group)
                .first(where: { $0.accessibilityIdentifier() == identifier }) {
                let frame = picker.convert(picker.bounds, to: nil)
                guard frame.contains(point) else {
                    throw ScenarioFailure(
                        "\(identifier) is at \(Views.describe(frame)), not at its row's \(Views.describe(point))",
                    )
                }
            }
            return (window.windowNumber, point)
        }

        /// The Camera Recipe group's firmware controls: the row of the Effects panel before the
        /// group's first slider.
        @MainActor private static func firmwareGroup(in window: NSWindow) -> NSView? {
            guard let panel = Views.shown("panel.effects", in: window),
                  let first = PanelID.cameraRecipeParameters.first
            else { return nil }
            let slider = Target.slider(first).identifier
            var view = Views.all(NSView.self, in: panel).first { $0.accessibilityIdentifier() == slider }
            while let row = view {
                if let column = row.superview as? ColumnView, let index = column.arrangedViews.firstIndex(of: row) {
                    return index > 0 ? column.arrangedViews[index - 1] : nil
                }
                view = row.superview
            }
            return nil
        }
    }
#endif
