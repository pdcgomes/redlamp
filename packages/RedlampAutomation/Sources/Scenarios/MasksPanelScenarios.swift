#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import RedlampEngineAPI
    @_spi(Harness) import RedlampUI
    import Synchronization

    /// The Masks panel (UX-20 to UX-24) worked through its own controls, as a person works it:
    /// clicks on its buttons, tiles, rows and checkboxes, choices in its menus, and drags on its
    /// value fields. Hovers aren't among them, since SwiftUI reads them from the real pointer:
    /// `PointerPreviewTests` and `MasksPanelViewTests` cover the previews they start.
    enum MasksPanelScenarios {
        static let all: [Scenario] = [panel, tools, people]

        static let panel = Scenario(
            "masking.panel",
            "The Masks panel by its controls: the picker, a mask's menu, eye and Invert, Add, Subtract and Intersect "
                + "with Existing Mask, a component's menus, and the header's",
            claims: [
                .feature("masking.overlay"),
                .feature("masking.combining"),
                .feature("masking.radial"),
                .feature("masking.linear"),
                .mask(.existingMask),
            ],
            needsFocus: true,
        ) { app in
            try app.openMasks()

            // With no masks the picker is the list; New Mask opens it over the panel.
            try app.tap(.identifier("masks.picker.radial"))
            try app.wait("a radial gradient armed") { $0.drawingKind == .radial }
            try app.drawArmedGradient(.radial)
            let first = try app.selectedMask()
            try app.pick(.linear, from: "masks.new")
            try app.drawArmedGradient(.linear)
            let second = try app.selectedMask()
            try app.expect(first != second, "New Mask made no mask")

            // The selected mask's menu, and Invert and Reset at the top of its settings.
            try app.choose("Duplicate", inMenuOf: .row(second, "menu"))
            try app.wait("a copy") { $0.masks.count == 3 }
            let copy = try app.selectedMask()
            try app.choose("Duplicate and Invert", inMenuOf: .row(copy, "menu"))
            try app.wait("an inverted copy") { $0.masks.count == 4 && $0.selectedMask?.inverted == true }
            let inverted = try app.selectedMask()
            try app.choose("Invert", inMenuOf: .row(inverted, "menu"))
            try app.wait("Invert in the mask's menu") { $0.selectedMask?.inverted == false }
            try app.tap(.identifier("masks.mask.invert"))
            try app.wait("Invert at the top of the mask") { $0.selectedMask?.inverted == true }
            try app.set(.localExposure, 0.5)
            try app.tap(.identifier("masks.mask.reset"))
            try app.wait("Reset") { $0.sliderValue(.localExposure) == 0 }
            try app.set(.localExposure, 0.5)
            try app.choose("Reset Adjustments", inMenuOf: .row(inverted, "menu"))
            try app.wait("Reset Adjustments") { $0.sliderValue(.localExposure) == 0 }
            let name = try app.main { $0.selectedMask?.name ?? "" }
            try app.choose("Delete \(name)", inMenuOf: .row(inverted, "menu"))
            try app.wait("the mask deleted from its menu") { $0.recipe.mask(inverted) == nil }

            // Rename… puts a field in the row; choosing another mask by its row puts it away.
            try app.choose("Rename…", inMenuOf: .row(copy, "menu"))
            try app.waitFor(.row(copy, "name"))
            let chosen = try app.chooseRow(.row(first)) { $0.selectMask(first) }
            try app.wait("the first mask chosen by its row") { $0.selectedMaskID == first }
            try app.waitFor(.row(copy, "name"), shown: false)

            // The eye hides and shows a mask; with Option it shows that mask alone, then all again.
            try app.tap(.row(second, "eye"))
            try app.wait("the second mask hidden") { $0.recipe.mask(second)?.isVisible == false }
            try app.tap(.row(second, "eye"))
            try app.wait("the second mask shown") { $0.recipe.mask(second)?.isVisible == true }
            try app.holding(.option) { try app.tap(.row(second, "eye"), modifiers: .option) }
            try app.wait("the second mask shown alone") { $0.masks.filter(\.isVisible).map(\.id) == [second] }
            try app.holding(.option) { try app.tap(.row(second, "eye"), modifiers: .option) }
            try app.wait("every mask shown") { $0.masks.allSatisfy(\.isVisible) }

            // Add, Subtract and Intersect open the picker for the first mask's components.
            try app.pick(.linear, from: "masks.subtract")
            try app.drawArmedGradient(.linear)
            try app.wait("a subtracted component") { $0.recipe.mask(first)?.components.last?.operation == .subtract }
            try app.tap(.identifier("masks.add"))
            try app.waitForPopover("Add's picker")
            try app.tap(.identifier("masks.picker.existing.\(second.uuidString)"))
            try app.wait("the second mask as a component") { model in
                model.recipe.mask(first)?.components.contains { $0.shape.kind == .existingMask } == true
            }
            try app.pick(.radial, from: "masks.intersect")
            try app.drawArmedGradient(.radial)
            try app.wait("an intersected component") { $0.recipe.mask(first)?.components.last?.operation == .intersect }

            // A component chosen by its row, its operation from its icon's menu, Invert, and Delete.
            let component = try app.main { $0.recipe.mask(first)?.components[1].id }
            guard let component else { throw ScenarioFailure("The first mask has no second component") }
            _ = try app.chooseRow(.component(component)) { $0.selectedComponentID = component }
            try app.wait("the component chosen by its row") { $0.selectedComponentID == component }
            try app.choose("Set to Intersect", inMenuOf: .component(component, "operation"))
            try app.wait("the component intersecting") { $0.component(component, in: first)?.operation == .intersect }
            try app.choose("Set to Subtract", inMenuOf: .component(component, "operation"))
            try app.wait("the component subtracting") { $0.component(component, in: first)?.operation == .subtract }
            try app.tap(.component(component, "invert"))
            try app.wait("the component inverted") { $0.component(component, in: first)?.inverted == true }
            try app.choose("Delete", inMenuOf: .component(component, "menu"))
            try app.wait("the component deleted") { $0.component(component, in: first) == nil }

            // The header: the overlay and the pins, then Delete All Masks from its menu.
            let overlay = try app.main { $0.showMaskOverlay }
            try app.tap(.identifier("masks.overlay"))
            try app.wait("the overlay switched") { $0.showMaskOverlay != overlay }
            try app.tap(.identifier("masks.overlay"))
            try app.wait("the overlay switched back") { $0.showMaskOverlay == overlay }
            let pins = try app.main { $0.showMaskPins }
            try app.tap(.identifier("masks.pins"))
            try app.wait("the pins switched") { $0.showMaskPins != pins }
            try app.tap(.identifier("masks.pins"))
            try app.wait("the pins switched back") { $0.showMaskPins == pins }
            try app.choose("Delete All Masks", inMenuOf: .identifier("masks.actions"))
            try app.wait("every mask deleted") { $0.masks.isEmpty }
            try app.waitFor(.identifier("masks.picker.radial"))
            app.recorder.write("note", ["rows": chosen.rawValue])
            app.covered(
                [
                    .feature("masking.overlay"),
                    .feature("masking.combining"),
                    .feature("masking.radial"),
                    .feature("masking.linear"),
                    .mask(.existingMask),
                ],
                via: .mouse,
            )
        }

        static let tools = Scenario(
            "masking.panel-tools",
            "The Masks panel's tools by their controls: a luminance range's stops and map, the brush's Auto Mask, "
                + "the overlay's options and Opacity, an AI mask's Refine Edges and Refine Edge Brush with its Size, "
                + "and a preset from the header",
            claims: [
                .feature("masking.luminance-range"),
                .feature("masking.brush"),
                .feature("masking.overlay"),
                .feature("masking.refine"),
                .feature("masking.presets"),
            ],
        ) { app in
            try app.openMasks()

            // A luminance range from the picker, its four stops scrubbed, and its map.
            try app.tap(.identifier("masks.picker.luminanceRange"))
            try app.wait("the luminance range's sampler") { $0.drawingKind == .luminanceRange }
            try app.run("sampling a luminance range") { await $0.sampleLuminanceRange(at: ImagePoint(x: 0.5, y: 0.5)) }
            try app.wait("a luminance range") { $0.selectedLuminanceRange != nil }
            for stop in 1 ... 4 {
                try app.scrub(.identifier("masks.luminanceRange.stop\(stop)"), "stop \(stop)") { model in
                    model.selectedLuminanceRange.map { range in
                        [range.lower - range.lowerFeather, range.lower, range.upper, range.upper + range.upperFeather]
                    }?[stop - 1]
                }
            }
            try app.tap(.identifier("masks.luminanceMap"))
            try app.wait("the luminance map") { $0.showLuminanceMap }
            try app.tap(.identifier("masks.luminanceMap"))
            try app.wait("the luminance map off") { !$0.showLuminanceMap }
            try app.tap(.identifier("masks.hint.done"))
            try app.wait("the sampler put down") { $0.drawingKind == nil }

            // The brush from the mask's Add, and its Auto Mask.
            try app.pick(.brush, from: "masks.add")
            try app.wait("the brush") { $0.isBrushing }
            let auto = try app.main { $0.brushes[$0.activeBrush].autoMask }
            try app.tap(.identifier("masks.brush.autoMask"))
            try app.wait("Auto Mask switched") { $0.brushes[$0.activeBrush].autoMask != auto }
            try app.tap(.identifier("masks.brush.autoMask"))
            try app.wait("Auto Mask switched back") { $0.brushes[$0.activeBrush].autoMask == auto }
            try app.tap(.identifier("masks.hint.done"))
            try app.wait("the brush put down") { !$0.isBrushing }

            // The overlay's options: its mode and colour from their menus, its Opacity scrubbed.
            let (style, color, opacity) = try app.main { (
                $0.maskOverlayStyle,
                $0.maskOverlayColor,
                $0.maskOverlayOpacity,
            ) }
            try app.tap(.identifier("masks.overlayOptions"))
            try app.waitFor(.identifier("masks.overlay.opacity"))
            try app.choose(MaskOverlayStyle.colorOverlay.name, inMenuOf: .identifier("masks.overlay.mode"))
            try app.wait("Color Overlay") { $0.maskOverlayStyle == .colorOverlay }
            try app.choose(MaskOverlayColor.green.name, inMenuOf: .identifier("masks.overlay.color"))
            try app.wait("a green overlay") { $0.maskOverlayColor == .green }
            try app.scrub(.identifier("masks.overlay.opacity"), "the overlay's Opacity") { $0.maskOverlayOpacity }
            try app.tap(.identifier("masks.overlayOptions"))
            try app.waitFor(.identifier("masks.overlay.opacity"), shown: false)
            try app.main { model in
                model.maskOverlayStyle = style
                model.maskOverlayColor = color
                model.maskOverlayOpacity = opacity
            }
            app.covered(
                [.feature("masking.luminance-range"), .feature("masking.brush"), .feature("masking.overlay")],
                via: .mouse,
            )

            // Subject from New Mask's picker, then Refine Edges and the Refine Edge Brush.
            guard try app.main({ $0.availableAIMaskKinds.contains(.subject) }) else {
                throw ScenarioSkip("Apple Vision's Subject mask isn't available")
            }
            try app.pick(.subject, from: "masks.new")
            try app.wait("a Subject mask", timeout: 180) { model in
                model.selectedMask?.components.contains { $0.shape.kind == .subject } == true || model
                    .maskMessage != nil
            }
            guard let (mask, component) = try app.main({ model -> (UUID, UUID)? in
                guard let mask = model.selectedMask,
                      let component = mask.components.first(where: { $0.shape.kind == .subject })
                else { return nil }
                return (mask.id, component.id)
            }) else {
                throw ScenarioSkip("Subject found nothing to mask in the working photo")
            }
            _ = try app.chooseRow(.component(component)) { $0.selectedComponentID = component }
            try app.wait("the Subject component chosen") { $0.selectedComponentID == component }
            let mark = try app.mark()
            try app.tap(.identifier("masks.refineEdges"))
            try app.wait("Refine Edges", timeout: 240) { model in
                model.activity.events.contains { $0.time >= mark.time && $0.text.contains("Refine Edges") }
                    || model.maskMessage != nil
            }
            try app.tap(.identifier("masks.refineEdgeBrush"))
            try app.wait("the Refine Edge Brush") { $0.isRefiningEdges }
            try app.scrub(.identifier("masks.edgeBrush.size"), "the Refine Edge Brush's Size") { $0.edgeBrushSize }
            try app.tap(.identifier("masks.hint.done"))
            try app.wait("the Refine Edge Brush put down") { !$0.isRefiningEdges }
            try app.expect(try app.main { $0.recipe.mask(mask) != nil }, "The Subject mask went")
            app.covered(.feature("masking.refine"), via: .mouse)

            // A preset from the header's Mask Presets menu.
            if let preset = MaskPreset.builtIn.first(where: { $0.name == "Brighten Subject" }),
               try app.main({ $0.canApply(preset) }) {
                try app.choose(preset.name, inMenuOf: .identifier("masks.presets"))
                try app.wait("the \(preset.name) preset", timeout: 180) { model in
                    model.masks.contains { $0.name == preset.name } || model.maskMessage != nil
                }
                app.covered(.feature("masking.presets"), via: .mouse)
            }
            try app.main { $0.deleteAllMasks() }
        }

        static let people = Scenario(
            "masking.panel-people",
            "The People picker by its controls: Cancel, the person found, a part ticked and unticked, and Create",
            claims: [.feature("masking.people"), .mask(.people)],
        ) { app in
            // None of the samples has a person, but Vision takes the Canon's statue for one.
            guard let canon = try app.photoNames().first(where: { $0.uppercased().hasSuffix(".CR3") }) else {
                throw ScenarioSkip("The run's photos have no Canon sample")
            }
            try app.open(canon)
            try app.openMasks()
            guard try app.main({ $0.availableAIMaskKinds.contains(.people) }) else {
                throw ScenarioSkip("People needs Apple Vision's person segmentation")
            }

            // People opens its picker in the list's place; Cancel gives the list back.
            try app.tap(.identifier("masks.picker.people"))
            try app.waitFor(.identifier("masks.people.cancel"))
            try app.tap(.identifier("masks.people.cancel"))
            try app.waitFor(.identifier("masks.people.cancel"), shown: false)

            try app.pick(.people, from: "masks.new")
            try app.waitFor(.identifier("masks.people.create"))
            let found = Mutex<[Int]>([])
            try app.run("who is in the photo", timeout: 120) { model in
                let people = await (try? model.engine.peopleFound()) ?? []
                found.withLock { $0 = people.map(\.id) }
            }
            guard let person = found.withLock({ $0.first }) else {
                try app.tap(.identifier("masks.people.cancel"))
                throw ScenarioSkip("Vision found nobody in the Canon sample")
            }
            // Someone alone in the photo starts ticked: untick them, then tick them again.
            try app.waitFor(.identifier("masks.people.person.\(person)"))
            try app.tap(.identifier("masks.people.person.\(person)"))
            try app.tap(.identifier("masks.people.person.\(person)"))
            if try app.exists(.identifier("masks.people.part.faceSkin")) {
                try app.tap(.identifier("masks.people.part.faceSkin"))
                try app.tap(.identifier("masks.people.part.faceSkin"))
            }
            try app.tap(.identifier("masks.people.create"))
            try app.wait("a People mask", timeout: 180) { model in
                model.masks.contains { $0.components.contains { $0.shape.kind == .people } } || model.maskMessage != nil
            }
            let (made, message) = try app.main { model in
                (model.masks.contains { $0.components.contains { $0.shape.kind == .people } }, model.maskMessage ?? "")
            }
            try app.expect(made, "Create made no People mask: \(message)")
            try app.main { $0.deleteAllMasks() }
            app.covered([.feature("masking.people"), .mask(.people)], via: .mouse)
        }
    }

    private extension RunningApp {
        /// The working photo in the Masking tool, with no masks.
        func openMasks() throws {
            try openWorking()
            try click(.tool(.masking))
            try wait("the Masking tool") { $0.activeTool == .masking }
            try main { $0.deleteAllMasks() }
            try waitFor(.identifier("masks.new"))
        }

        /// Chooses a row of the list by a click, which SwiftUI's tap gestures take only in a key
        /// window: with the run's focus by the click, otherwise as the click would. How it went.
        func chooseRow(_ target: Target, _ choose: @escaping @MainActor (EditorModel) -> Void) throws -> InputPath {
            if try focus() {
                try tap(target)
                return .mouse
            }
            try main(choose)
            return .model
        }

        func selectedMask() throws -> UUID {
            guard let id = try main({ $0.selectedMaskID }) else { throw ScenarioFailure("No mask is selected") }
            return id
        }

        /// Opens the picker from `button` (New Mask, Add, Subtract or Intersect) and chooses `kind`.
        func pick(_ kind: MaskKind, from button: String) throws {
            try tap(.identifier(button))
            try waitForPopover("\(button)'s picker")
            try tap(.identifier("masks.picker.\(kind.rawValue)"))
            if kind == .people {
                // The People picker takes the list's place; the scenario waits for its buttons.
                return
            } else if kind.isAI {
                try wait("the \(kind.name) mask started", timeout: 30) { model in
                    model.aiMaskProgress != nil || model.pendingModel != nil
                        || model.masks.contains { $0.components.contains { $0.shape.kind == kind } }
                }
            } else {
                try wait("\(kind.name) armed") { $0.drawingKind == kind || $0.isBrushing && kind == .brush }
            }
        }

        func waitForPopover(_ what: String) throws {
            try wait(what) { _ in Views.popoverWindow != nil }
        }

        /// Waits for `target` to come on screen, or with `shown` false to go.
        func waitFor(_ target: Target, shown: Bool = true, timeout: Double = 5) throws {
            let deadline = Date().addingTimeInterval(timeout)
            while try exists(target) != shown {
                if Date() > deadline {
                    throw ScenarioFailure("\(target) \(shown ? "didn't come on screen" : "stayed on screen")")
                }
                pause(0.05)
            }
        }

        /// Scrubs the value field `target` one way and, if the value didn't move (it was at its
        /// end), the other.
        func scrub(
            _ target: Target, _ what: String, value: @escaping @MainActor (EditorModel) -> Double?,
        ) throws {
            let before = try main(value)
            for dx in [30.0, -30] {
                try drag(target, by: CGVector(dx: dx, dy: 0))
                if try main(value) != before {
                    return
                }
            }
            throw ScenarioFailure("Scrubbing \(what) didn't change it")
        }
    }

    private extension Target {
        /// A control on the Masks panel's row for mask `id`, or the row.
        static func row(_ id: UUID, _ control: String? = nil) -> Target {
            .identifier(["masks.row.\(id.uuidString)", control].compactMap(\.self).joined(separator: "."))
        }

        /// A control on the row for component `id`, or the row.
        static func component(_ id: UUID, _ control: String? = nil) -> Target {
            .identifier(["masks.component.\(id.uuidString)", control].compactMap(\.self).joined(separator: "."))
        }
    }

    private extension EditorModel {
        func component(_ id: UUID, in mask: UUID) -> MaskComponent? {
            recipe.mask(mask)?.components.first { $0.id == id }
        }
    }
#endif
