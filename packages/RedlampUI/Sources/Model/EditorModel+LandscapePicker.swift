import Foundation
import RedlampEngineAPI

/// The Landscape picker (UX-26): the regions SAM 3 finds in the photo, those ticked, and whether
/// each gets a mask of its own.
struct LandscapePicker: Equatable {
    var mode: MaskPickerMode
    /// nil until the regions are found.
    var regions: [LandscapeFound]?
    var chosen: Set<LandscapeClass> = []
    /// One mask for each region, rather than one for them all.
    var separate = false

    /// A mask's components combine in order, so intersecting takes one region at a time.
    var canCreate: Bool {
        !chosen.isEmpty && (mode.operation != .intersect || chosen.count == 1)
    }
}

extension EditorModel {
    /// Opens the picker and finds the photo's regions. A region alone in the photo starts ticked.
    func openLandscapePicker(_ mode: MaskPickerMode) {
        guard let visit = currentVisit else { return }
        activeTool = .masking
        cancelDrawing()
        closePeoplePicker()
        landscapePicker = LandscapePicker(mode: mode)
        maskMessage = nil
        Task {
            let regions: [LandscapeFound]
            do {
                regions = try await engine.landscapeFound()
            } catch {
                guard currentVisit == visit, landscapePicker != nil else { return }
                maskMessage = (error as? MaskComputationError)?.description ?? error.localizedDescription
                regions = []
            }
            guard currentVisit == visit, landscapePicker?.regions == nil else { return }
            landscapePicker?.regions = regions
            landscapePicker?.chosen = regions.count == 1 ? [regions[0].landscape] : []
        }
    }

    func closeLandscapePicker() {
        landscapePicker = nil
    }

    func toggleLandscape(_ landscape: LandscapeClass) {
        guard landscapePicker != nil else { return }
        if landscapePicker?.chosen.remove(landscape) == nil {
            landscapePicker?.chosen.insert(landscape)
        }
    }

    func setLandscapeSeparate(_ separate: Bool) {
        landscapePicker?.separate = separate
    }

    /// Makes the picker's masks: one of every region ticked, or one each; or, for a component,
    /// the regions added to (each subtracted from, or the one intersected with) the target.
    func createLandscapeMasks() async {
        guard let picker = landscapePicker, picker.canCreate, let visit = currentVisit, aiMaskProgress == nil
        else { return }
        let target = picker.mode.target
        let operation = picker.mode.operation
        guard target != nil || hasRoomForMask(recipe.masks) else { return }
        let regions = LandscapeClass.allCases.filter(picker.chosen.contains)
        aiMaskProgress = .landscape
        maskMessage = nil
        defer { aiMaskProgress = nil }

        var made: [(region: LandscapeClass, component: MaskComponent)] = []
        var missing: [LandscapeClass] = []
        for region in regions {
            let request = MaskRequest(kind: .landscape, landscape: region)
            guard let mask = try? await engine.computeMasks(request).first else {
                missing.append(region)
                continue
            }
            made.append((region, MaskComponent(shape: .ai(mask), operation: target == nil ? .add : operation)))
        }
        guard currentVisit == visit, landscapePicker != nil else { return }
        guard !made.isEmpty else {
            maskMessage = MaskComputationError.notFound(regions[0]).description
            return
        }
        if !missing.isEmpty {
            maskMessage = "Not found: \(missing.map(\.name).joined(separator: ", "))."
        }

        let title = made.count == 1 ? made[0].region.name : "Landscape"
        let components = made.map(\.component)
        var next = recipe
        if let target, let index = next.masks.firstIndex(where: { $0.id == target }) {
            next.masks[index].components += components
            selectedMaskID = target
            selectedComponentID = components.last?.id
            commit(next, .mask(.landscape), "\(operation.name) \(title)")
        } else if picker.separate, made.count > 1 {
            for (region, component) in made where hasRoomForMask(next.masks) {
                next.masks.append(MaskLayer(name: region.name, components: [component]))
            }
            selectedMaskID = next.masks.last?.id
            selectedComponentID = nil
            commit(next, .mask(.landscape), "New Landscape Masks")
        } else {
            let mask = MaskLayer(name: title, components: components)
            next.masks.append(mask)
            selectedMaskID = mask.id
            selectedComponentID = components.last?.id
            commit(next, .mask(.landscape), "New \(title)")
        }
        closeLandscapePicker()
    }
}
