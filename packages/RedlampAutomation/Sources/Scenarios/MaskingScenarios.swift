#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import RedlampEngineAPI
    @_spi(Harness) import RedlampUI

    enum MaskingScenarios {
        static let all: [Scenario] = [
            gradients,
            brush,
            ranges,
            ai,
            objectsAndLandscape,
            combining,
            listAndOverlay,
            presets,
            brushSizes,
        ]

        static let localParameters = ParameterID.localParameters

        static let gradients = Scenario(
            "masking.gradients", "Linear and radial gradients, and every local slider dragged on the selected mask",
            claims: [
                .mask(.linear),
                .mask(.radial),
                .feature("masking.linear"),
                .feature("masking.radial"),
                .feature("masking.local-adjustments"),
                .tool(.masking),
                .parameter(.maskAmount),
                .parameter(.maskFeather),
            ]
                + localParameters.map(Claim.parameter),
            needsFocus: true,
        ) { app in
            try app.openWorking()
            try app.click(.tool(.masking))
            try app.wait("the Masking tool") { $0.activeTool == .masking }
            app.covered(.tool(.masking), via: .mouse)
            try app.drawGradient(.linear)
            try app.drawGradient(.radial)
            for parameter in localParameters + [.maskAmount, .maskFeather] where try app.exists(.slider(parameter)) {
                try SmokeScenarios.dragAndReset(parameter, app: app)
            }
            let missing = try (localParameters + [.maskAmount, .maskFeather]).filter { try !app.exists(.slider($0)) }
            for parameter in missing {
                try app.set(parameter, parameter.spec.clamp(parameter.spec.defaultValue + 10))
                app.covered(.parameter(parameter), via: .model)
            }
            // The selected mask's Curves, an RGB and a channel curve (MSK-20).
            let curved = try app.main { model in
                model.setMaskCurve(.rgb, [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.4), CurvePoint(x: 1, y: 1)])
                model.setMaskCurve(.blue, [CurvePoint(x: 0, y: 0.1), CurvePoint(x: 1, y: 0.9)])
                return model.selectedMask?.curves != nil
            }
            try app.expect(curved, "The selected mask has no Curves")
            try app.main { $0.deleteAllMasks() }
            app.covered(
                [.feature("masking.linear"), .feature("masking.radial"), .feature("masking.local-adjustments")],
                via: .mouse,
            )
        }

        static let brush = Scenario(
            "masking.brush", "The brush paints a stroke, and its settings move",
            claims: [
                .mask(.brush),
                .feature("masking.brush"),
                .parameter(.maskBrushSize),
                .parameter(.maskBrushFeather),
                .parameter(.maskBrushFlow),
                .parameter(.maskBrushDensity),
            ],
            needsFocus: true,
        ) { app in
            try app.openWorking()
            try app.press(.brushMask)
            try app.wait("the brush") { $0.isBrushing }
            if try app.focus() {
                try app.drag(.canvas, from: CGPoint(x: 0.3, y: 0.4), by: CGVector(dx: 120, dy: 20), steps: 16)
                app.covered(.mask(.brush), via: .mouse)
            } else {
                try app.main { model in
                    model.beginStroke(at: ImagePoint(x: 0.3, y: 0.4))
                    for step in 1 ... 10 {
                        model.continueStroke(to: ImagePoint(x: 0.3 + 0.03 * Double(step), y: 0.42))
                    }
                    model.endStroke()
                }
                app.covered(.mask(.brush), via: .model)
            }
            try app.wait("a brushed mask") { !$0.masks.isEmpty }
            for parameter in [ParameterID.maskBrushSize, .maskBrushFeather, .maskBrushFlow, .maskBrushDensity] {
                if try app.exists(.slider(parameter)) {
                    try app.drag(.slider(parameter), from: CGPoint(x: 0.4, y: 0.5), by: CGVector(dx: 15, dy: 0))
                    app.covered(.parameter(parameter), via: .mouse)
                } else {
                    try app.main { $0.setSliderValue(parameter, parameter.spec.clamp(parameter.spec.defaultValue + 5)) }
                    app.covered(.parameter(parameter), via: .model)
                }
            }
            try app.press(KeyCombo(.escape))
            try app.main { $0.deleteAllMasks() }
            app.covered(.feature("masking.brush"), via: .key)
        }

        static let ranges = Scenario(
            "masking.ranges", "Color, luminance and depth ranges sampled from the photo",
            claims: [
                .mask(.colorRange),
                .mask(.luminanceRange),
                .mask(.depthRange),
                .feature("masking.color-range"),
                .feature("masking.luminance-range"),
                .feature("masking.depth-range"),
                .parameter(.maskColorRefine),
            ],
        ) { app in
            try app.openWorking()
            try app.press(.colorRangeMask)
            try app.wait("the colour range sampler") { $0.drawingKind == .colorRange }
            try app.main { $0.sampleColorRange(at: ImagePoint(x: 0.5, y: 0.4), adding: false) }
            try app
                .wait("a colour range mask") {
                    $0.masks.contains { $0.components.contains { $0.shape.kind == .colorRange } }
                }
            try app.set(.maskColorRefine, 60)
            app.covered([.mask(.colorRange), .feature("masking.color-range"), .parameter(.maskColorRefine)], via: .key)
            try app.press(KeyCombo(.escape))
            try app.press(.luminanceRangeMask)
            try app.wait("the luminance range sampler") { $0.drawingKind == .luminanceRange }
            try app.run("sampling a luminance range") { await $0.sampleLuminanceRange(at: ImagePoint(x: 0.5, y: 0.5)) }
            try app
                .wait("a luminance range mask") {
                    $0.masks.contains { $0.components.contains { $0.shape.kind == .luminanceRange } }
                }
            app.covered([.mask(.luminanceRange), .feature("masking.luminance-range")], via: .key)
            try app.press(KeyCombo(.escape))
            if try app.main({ $0.canCreateMask(.depthRange) }) {
                try app.press(.depthRangeMask)
                try app
                    .wait("the depth range") {
                        $0.drawingKind == .depthRange || $0.masks
                            .contains { $0.components.contains { $0.shape.kind == .depthRange } }
                    }
                try app.main { $0.setDepthRange(LuminanceRangeMask(
                    lower: 20,
                    upper: 60,
                    lowerFeather: 10,
                    upperFeather: 10,
                )) }
                app.covered([.mask(.depthRange), .feature("masking.depth-range")], via: .key)
            }
            try app.press(KeyCombo(.escape))
            try app.main { $0.deleteAllMasks() }
            if try !app.main({ $0.canCreateMask(.depthRange) }) {
                throw ScenarioSkip("Depth Range needs Depth Anything, which isn't downloaded")
            }
        }

        static let ai = Scenario(
            "masking.ai", "Subject, Sky, Background and People from Apple Vision; Update AI Masks; Refine Edges",
            claims: [
                .mask(.subject),
                .mask(.sky),
                .mask(.background),
                .mask(.people),
                .feature("masking.subject"),
                .feature("masking.sky"),
                .feature("masking.background"),
                .feature("masking.people"),
                .feature("masking.update-ai"),
                .feature("masking.refine"),
                .feature("masking.models"),
            ],
        ) { app in
            try app.openWorking()
            let available = try app.main { $0.availableAIMaskKinds }
            for kind in [MaskKind.subject, .sky, .background, .people] {
                guard available.contains(kind) else {
                    app.recorder.write("note", ["unavailable": kind.rawValue])
                    continue
                }
                let before = try app.main { $0.masks.count }
                try app.run("the \(kind) mask", timeout: 180) { await $0.createAIMask(kind) }
                let message = try app.main { $0.maskMessage }
                let made = try app.main { $0.masks.count > before }
                // A photo without people, sky or subject gets a message instead of a mask.
                try app.expect(made || message != nil, "Neither a \(kind) mask nor a message")
                app.covered([.mask(kind), .feature("masking.\(kind.rawValue)")], via: .model)
            }
            if let mask = try app.main({ model -> UUID? in
                model.masks.first { $0.components.contains { $0.shape.kind?.isAI == true } }?.id
            }) {
                try app.run("Update AI Masks", timeout: 240) { await $0.updateAIMasks(in: [mask]) }
                let component = try app.main { $0.masks.first { $0.id == mask }?.components.first?.id }
                if let component {
                    try app.run("Refine Edges", timeout: 240) { await $0.refineEdges(component, in: mask) }
                }
                app.covered([.feature("masking.update-ai"), .feature("masking.refine")], via: .model)
            }
            try app.expect(available.contains(.subject), "Apple Vision's Subject mask isn't available")
            app.covered(.feature("masking.models"), via: .model)
            try app.main { $0.deleteAllMasks() }
        }

        static let objectsAndLandscape = Scenario(
            "masking.objects-and-landscape",
            "Objects (Segment Anything) by a click, a box and a stroke, and Landscape (SAM 3)",
            claims: [.mask(.objects), .mask(.landscape), .feature("masking.objects"), .feature("masking.landscape")],
        ) { app in
            try app.openWorking()
            let available = try app.main { $0.availableAIMaskKinds }
            var ran = false
            if available.contains(.objects) {
                try app.main { $0.armObjectSelection() }
                try app
                    .run("selecting an object", timeout: 240) { await $0.selectObject(at: ImagePoint(x: 0.5, y: 0.55)) }
                try app
                    .wait("an Objects mask", timeout: 30) {
                        $0.masks.contains { $0.components.contains { $0.shape.kind == .objects } } || $0
                            .maskMessage != nil
                    }
                try app.press(KeyCombo(.escape))
                // A box dragged around a thing, then a stroke brushed over another (MSK-19).
                try app.main { $0.armObjectSelection() }
                try app.run("selecting an object by a box", timeout: 240) {
                    await $0.selectObject(in: ImageRect(x: 0.35, y: 0.4, width: 0.3, height: 0.3))
                }
                try app.press(KeyCombo(.escape))
                try app.main { $0.armObjectSelection() }
                try app.run("selecting an object by a stroke", timeout: 240) {
                    await $0.selectObject(along: (0 ... 10).map { ImagePoint(x: 0.3 + 0.02 * Double($0), y: 0.7) })
                }
                try app.press(KeyCombo(.escape))
                let boxed = try app.main { model in
                    model.recipe.masks.flatMap(\.components).contains { component in
                        if case let .ai(mask) = component.shape {
                            mask.box != nil
                        } else {
                            false
                        }
                    }
                }
                let message = try app.main { $0.maskMessage }
                try app.expect(boxed || message != nil, "No Objects mask kept its box")
                app.covered([.mask(.objects), .feature("masking.objects")], via: .model)
                ran = true
            }
            if available.contains(.landscape) {
                try app
                    .run("a Landscape mask", timeout: 300) { await $0.createAIMask(.landscape, landscape: .vegetation) }
                app.covered([.mask(.landscape), .feature("masking.landscape")], via: .model)
                ran = true
            }
            try app.main { $0.deleteAllMasks() }
            if !ran {
                throw ScenarioSkip("Segment Anything 2.1 and SAM 3 aren't downloaded")
            }
        }

        static let combining = Scenario(
            "masking.combining", "Add, subtract and intersect components, invert, and reuse a mask in another",
            claims: [.feature("masking.combining"), .mask(.existingMask), .parameter(.maskDetail)],
        ) { app in
            try app.openWorking()
            try app.main { $0.activeTool = .masking }
            try app.drawGradient(.radial)
            let first = try app.main { $0.selectedMaskID }
            guard let first else { throw ScenarioFailure("No mask selected after drawing") }
            for operation in [MaskOperation.subtract, .intersect] {
                try app.drawGradient(.linear, operation: operation, addingTo: first)
            }
            let operations = try app
                .main { model in model.masks.first { $0.id == first }?.components.map(\.operation) ?? [] }
            try app.expect(
                operations.contains(.subtract) && operations.contains(.intersect),
                "Components: \(operations)",
            )
            if let component = try app.main({ model in model.masks.first { $0.id == first }?.components.first?.id }) {
                try app.expectRenders("an inverted component") { try app.main { $0.setComponentInverted(
                    component,
                    in: first,
                    true,
                ) } }
            }
            try app.set(.maskDetail, 40)
            try app.drawGradient(.linear)
            let second = try app.main { $0.selectedMaskID }
            if let second {
                try app.main { $0.addMaskReference(first, to: second, operation: .subtract) }
                try app.wait("the existing mask as a component") { model in
                    model.masks.first { $0.id == second }?.components
                        .contains { $0.shape.kind == .existingMask } == true
                }
            }
            try app.main { $0.deleteAllMasks() }
            app.covered([.feature("masking.combining"), .mask(.existingMask), .parameter(.maskDetail)], via: .model)
        }

        static let listAndOverlay = Scenario(
            "masking.list-and-overlay",
            "The mask list's operations, reordering masks and components, the overlay in every style and opacity, and the pins",
            claims: [.feature("masking.overlay")],
        ) { app in
            try app.openWorking()
            try app.main { $0.activeTool = .masking }
            try app.drawGradient(.radial)
            guard let mask = try app.main({ $0.selectedMaskID }) else { throw ScenarioFailure("No mask") }
            try app.main { model in
                model.renameMask(mask, to: "Regression")
                model.duplicateMask(mask)
                model.duplicateMask(mask, inverted: true)
                model.toggleMaskVisibility(mask)
                model.toggleMaskVisibility(mask)
                model.resetMaskAdjustments(mask)
            }
            let names = try app.main { $0.masks.map(\.name) }
            try app.expect(names.count == 3 && names.contains("Regression"), "Masks: \(names)")
            // Dragging a mask onto another gives it that place; a component the same within its mask.
            let order = try app.main { $0.recipe.masks.map(\.id) }
            try app.main { $0.moveMask(order[0], onto: order[2]) }
            let moved = try app.main { $0.recipe.masks.map(\.id) }
            try app.expect(moved == [order[1], order[2], order[0]], "Reordered masks: \(moved)")
            try app.main { model in
                model.startDrawing(.linear, operation: .subtract, addingTo: mask)
                model.beginDrawing(.linear(LinearMask(
                    start: ImagePoint(x: 0.5, y: 0.2), end: ImagePoint(x: 0.5, y: 0.4),
                )))
                model.finishDrawing()
            }
            let components = try app.main { $0.recipe.mask(mask)?.components.map(\.id) ?? [] }
            try app.expect(components.count == 2, "Components: \(components)")
            try app.main { $0.moveComponent(components[1], in: mask, onto: components[0]) }
            let reordered = try app.main { $0.recipe.mask(mask)?.components.map(\.id) ?? [] }
            try app.expect(reordered == components.reversed(), "Reordered components: \(reordered)")
            for style in MaskOverlayStyle.allCases {
                try app.main { $0.maskOverlayStyle = style }
                app.pause(0.05)
            }
            for opacity in [0.2, 1, MaskOverlayStyle.defaultOpacity] {
                try app.main { $0.maskOverlayStyle = .colorOverlay
                    $0.maskOverlayOpacity = opacity
                }
                app.pause(0.05)
            }
            try app.press(.maskOverlayColor)
            try app.press(.maskOverlay)
            try app.press(.maskOverlay)
            try app.press(.maskPins)
            try app.press(.maskPins)
            try app.press(.deleteMask)
            try app.wait("a mask deleted") { $0.masks.count == 2 }
            try app.main { $0.deleteAllMasks() }
            app.covered(.feature("masking.overlay"), via: .key)
        }

        /// `[` and `]` size the active brush, Shift its feather, and never the rating; ⌘-scroll
        /// sizes it too (UX-15). The wheel reaching the canvas through a tool's overlay is
        /// `CoveredEventTests`', since the driver can't deliver a wheel through the app.
        static let brushSizes = Scenario(
            "masking.brush-sizes", "[ and ] size the Masking and Healing brushes, and never the rating",
            claims: [.feature("masking.brush"), .feature("healing.remove")],
            needsFocus: true,
        ) { app in
            try app.openWorking()
            let rating = try app.main { $0.photoMetadata.rating }
            try app.press(.brushMask)
            try app.wait("the brush") { $0.isBrushing }
            let size = try app.main { $0.brushes[$0.activeBrush][.maskBrushSize] }
            var pressed = try nudge(.increaseRating, app: app)
            try app.wait("] to grow the mask brush") { $0.brushes[$0.activeBrush][.maskBrushSize] > size }
            let feather = try app.main { $0.brushes[$0.activeBrush][.maskBrushFeather] }
            pressed = try nudge(.decreaseRating, shift: true, app: app) && pressed
            try app.wait("⇧[ to soften less") { $0.brushes[$0.activeBrush][.maskBrushFeather] < feather }
            let grown = try app.main { model in
                let before = model.brushes[model.activeBrush][.maskBrushSize]
                _ = model.scrollSizedBrush(by: 2, feather: false)
                return model.brushes[model.activeBrush][.maskBrushSize] > before
            }
            try app.expect(grown, "⌘-scroll grows the brush")
            try app.main { $0.cancelDrawing() }

            try app.click(.tool(.heal))
            try app.wait("the healing tool") { $0.activeTool == .heal }
            let spot = try app.main { $0.spotSettings[.spotSize] }
            pressed = try nudge(.decreaseRating, app: app) && pressed
            try app.wait("[ to shrink the healing brush") { $0.spotSettings[.spotSize] < spot }
            let after = try app.main { $0.photoMetadata.rating }
            try app.expect(after == rating, "The rating changed from \(rating) to \(after)")
            try app.main { $0.activeTool = .edit }
            app.covered([.feature("masking.brush"), .feature("healing.remove")], via: pressed ? .key : .model)
        }

        /// Presses `action`'s key, or where the layout has no key that types it by itself (as on
        /// Portuguese keyboards), performs it as the key would. Whether the key was pressed.
        private static func nudge(_ action: ShortcutAction, shift: Bool = false, app: RunningApp) throws -> Bool {
            do {
                try app.press(action, shift: shift)
                return true
            } catch is ScenarioSkip {
                try app.main { _ = $0.perform(action, shifted: shift) }
                return false
            }
        }

        static let presets = Scenario(
            "masking.presets", "Every built-in mask preset, and saving one",
            claims: [.feature("masking.presets")],
        ) { app in
            try app.openWorking()
            for preset in MaskPreset.builtIn where try app.main({ $0.canApply(preset) }) {
                try app.run("the \(preset.name) preset", timeout: 240) { await $0.applyMaskPreset(preset) }
            }
            if let mask = try app.main({ $0.masks.first?.id }) {
                try app.main { $0.saveMaskPreset(from: mask, name: "Regression preset") }
                let saved = try app.main { $0.maskPresets.contains { $0.name == "Regression preset" } }
                try app.expect(saved, "The saved preset isn't listed")
                if let id = try app.main({ $0.maskPresets.first { $0.name == "Regression preset" }?.id }) {
                    try app.main { $0.deleteMaskPreset(id) }
                }
            }
            try app.main { $0.deleteAllMasks() }
            app.covered(.feature("masking.presets"), via: .model)
        }
    }

    enum CropScenarios {
        static let all: [Scenario] = [cropTool]

        static let cropTool = Scenario(
            "crop.tool", "Crop: every aspect, the lock, the angle, straighten, rotate, flip and the overlays",
            claims: [
                .tool(.crop),
                .tool(.edit),
                .feature("crop.crop"),
                .feature("crop.straighten"),
                .feature("crop.rotate"),
                .feature("crop.overlays"),
                .parameter(.cropAngle),
            ],
        ) { app in
            try app.openWorking()
            try app.click(.tool(.crop))
            try app.wait("the Crop tool") { $0.activeTool == .crop }
            app.covered(.tool(.crop), via: .mouse)
            for aspect in CropAspect.allCases {
                try app.main { $0.setCropAspect(aspect) }
                try app.wait("the \(aspect.title) aspect") { $0.cropAspect == aspect }
            }
            try app.press(.cropAspectLock)
            try app.press(.cropAspectLock)
            try app.set(.cropAngle, 4)
            app.covered(.parameter(.cropAngle), via: .model)
            try app.main { $0.straighten(from: CGPoint(x: 0.1, y: 0.5), to: CGPoint(x: 0.9, y: 0.52)) }
            try app.choose(.rotateLeft)
            try app.choose(.rotateRight)
            try app.expectRenders("a flip") { try app.main { $0.flip(horizontally: true) } }
            try app.main { $0.flip(horizontally: true) }
            let overlay = try app.main { "\($0.cropOverlay)" }
            try app.press(.maskOverlay)
            try app.wait("O to change the crop overlay") { overlay != "\($0.cropOverlay)" }
            try app.main { $0.resetCrop() }
            try app.click(.tool(.edit))
            try app.wait("the Edit tool") { $0.activeTool == .edit }
            app.covered(.tool(.edit), via: .mouse)
            app.covered(
                [
                    .feature("crop.crop"),
                    .feature("crop.straighten"),
                    .feature("crop.rotate"),
                    .feature("crop.overlays"),
                ],
                via: .model,
            )
        }
    }

    enum HealingScenarios {
        static let all: [Scenario] = [spots, dustAndFind, generative]

        static let spots = Scenario(
            "healing.spots", "Heal, Clone and Remove spots, their settings, a brushed stroke, and Red Eye's phase",
            claims: [
                .tool(.heal),
                .tool(.redEye),
                .feature("healing.heal"),
                .feature("healing.clone"),
                .feature("healing.remove"),
                .feature("healing.red-eye"),
                .parameter(.spotSize),
                .parameter(.spotFeather),
                .parameter(.spotOpacity),
            ],
        ) { app in
            try app.openWorking()
            try app.click(.tool(.heal))
            try app.wait("the healing tool") { $0.activeTool == .heal }
            app.covered(.tool(.heal), via: .mouse)
            for (index, mode) in [RetouchSpot.Mode.heal, .clone, .remove].enumerated() {
                try app.run("the \(mode) mode") { await $0.setSpotMode(mode) }
                let before = try app.main { $0.recipe.spots.count }
                try app.run("a \(mode) spot", timeout: 120) { await $0.addSpot(at: ImagePoint(
                    x: 0.3 + 0.15 * Double(index),
                    y: 0.6,
                )) }
                try app.wait("the \(mode) spot") { $0.recipe.spots.count > before }
            }
            for parameter in [ParameterID.spotSize, .spotFeather, .spotOpacity] {
                try app.set(parameter, parameter.spec.clamp(parameter.spec.defaultValue + 5))
                app.covered(.parameter(parameter), via: .model)
            }
            let before = try app.main { $0.recipe.spots.count }
            try app.run("a brushed stroke", timeout: 120) { model in
                await model.addStroke([
                    ImagePoint(x: 0.2, y: 0.2),
                    ImagePoint(x: 0.25, y: 0.22),
                    ImagePoint(x: 0.3, y: 0.25),
                ])
            }
            try app.wait("the stroke") { $0.recipe.spots.count > before }
            try app.press(.deleteMask)
            try app.wait("⌫ to delete the selected spot") { $0.recipe.spots.count == before }
            try app.main { $0.deleteAllSpots() }
            let redEye = try app.main { _ in EditTool.redEye.plannedPhase }
            try app.expect(redEye != nil, "Red Eye is marked as built")
            // Red Eye opens to say what's coming and when.
            try app.click(.tool(.redEye))
            try app.wait("Red Eye's panel") { $0.activeTool == .redEye }
            app.covered([.tool(.redEye), .feature("healing.red-eye")], via: .mouse)
            try app.main { $0.activeTool = .edit }
            app.covered([.feature("healing.heal"), .feature("healing.clone"), .feature("healing.remove")], via: .model)
        }

        /// Generative Remove (RM-10), with the model this Mac has downloaded: a Remove spot gets three
        /// fills, the arrows go through them, and Content-Aware takes it back.
        static let generative = Scenario(
            "healing.generative", "Generative Remove: a spot's three fills, the arrows, and back to Content-Aware",
            claims: [.feature("healing.remove")],
        ) { app in
            try app.openWorking()
            try app.click(.tool(.heal))
            try app.wait("the healing tool") { $0.activeTool == .heal }
            try app.run("whether generative fill can run") { await $0.loadGenerativeFill() }
            guard try app.main({ $0.generativeAvailability == .ready }) else {
                try app.main { $0.activeTool = .edit }
                throw ScenarioSkip("The run has no generative model (FLUX.2 [klein] 4B, from Settings › Models)")
            }
            try app.main { $0.fillsGeneratively = true }
            try app.run("Remove") { await $0.setSpotMode(.remove) }
            try app.run("a Remove spot", timeout: 60) { await $0.addSpot(at: ImagePoint(x: 0.4, y: 0.6)) }
            try app.wait("three fills", timeout: 600) { $0.generating == nil && $0.selectedSpot?.fill != nil }
            let fills = try app
                .main { model in model.selectedSpot.map { model.generatedFills[$0.id]?.count ?? 0 } ?? 0 }
            try app.expect(fills == EditorModel.fillVariations, "\(fills) fills")
            let first = try app.main { $0.selectedSpot?.fill }
            try app.main { $0.showFillVariation(1) }
            try app.expect(try app.main { $0.selectedSpot?.fill } != first, "The arrow shows the next fill")
            try app.main { $0.useContentAwareFill() }
            try app.expect(try app.main { $0.selectedSpot?.fill } == nil, "Content-Aware takes the fill back")
            try app.main { model in
                model.fillsGeneratively = false
                model.deleteAllSpots()
                model.activeTool = .edit
            }
            app.covered(.feature("healing.remove"), via: .model)
        }

        static let dustAndFind = Scenario(
            "healing.dust-and-find", "Remove Dust, Visualize Spots, person and object picks, and Find",
            claims: [
                .feature("healing.dust"),
                .feature("healing.visualize"),
                .feature("healing.picks"),
                .feature("healing.find"),
                .parameter(.spotVisualize),
            ],
        ) { app in
            try app.openWorking()
            try app.main { $0.activeTool = .heal }
            try app.run("Remove Dust", timeout: 240) { await $0.removeDust() }
            try app.set(.spotVisualize, 1)
            try app.set(.spotVisualize, 0)
            app.covered(
                [.feature("healing.dust"), .feature("healing.visualize"), .parameter(.spotVisualize)],
                via: .model,
            )
            try app.main { $0.spotPick = .object }
            try app.run("an object pick", timeout: 240) { await $0.pickRegion(at: ImagePoint(x: 0.5, y: 0.55)) }
            app.covered(.feature("healing.picks"), via: .model)
            try app.run("the things to find", timeout: 60) { await $0.loadThingsToFind() }
            let things = try app.main { $0.thingsToFind }
            if let thing = things.first {
                try app.main { $0.thingToFind = thing }
                try app.run("Find", timeout: 300) { await $0.findThings() }
                app.covered(.feature("healing.find"), via: .model)
            }
            try app.main { model in
                model.deleteAllSpots()
                model.spotPick = .spot
                model.activeTool = .edit
            }
            if things.isEmpty {
                throw ScenarioSkip("Find needs OWLv2, which isn't downloaded")
            }
        }
    }
#endif
