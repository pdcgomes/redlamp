import CoreGraphics
import Foundation
import RedlampEngineAPI

/// The People picker (UX-21): the people found in the photo, those ticked, and the parts to mask.
struct PeoplePicker: Equatable {
    var mode: MaskPickerMode
    /// nil until the people are found.
    var people: [PersonFound]?
    var chosen: Set<Int> = []
    var parts: Set<PersonPart> = [.entirePerson]
    /// One mask for each person, rather than one for them all.
    var separate = false
    /// The parts whose model isn't downloaded yet.
    var needsModel: [PersonPart: ModelInfo] = [:]

    /// "Person 2", by where they are in the photo's list.
    func name(of person: PersonFound) -> String {
        guard person.instance != nil, let index = people?.firstIndex(of: person) else { return "Everyone" }
        return "Person \(index + 1)"
    }
}

/// The parts Vision finds on a face, numbered by face rather than by person.
let faceParts: Set<PersonPart> = [.faceSkin, .eyebrows, .eyeSclera, .iris, .lips, .teeth]

extension EditorModel {
    /// Opens the picker and finds who's in the photo. Only someone alone in it starts ticked.
    func openPeoplePicker(_ mode: MaskPickerMode) {
        guard let visit = currentVisit else { return }
        activeTool = .masking
        cancelDrawing()
        peoplePicker = PeoplePicker(mode: mode)
        peopleCrops = [:]
        maskMessage = nil
        Task {
            await refreshPartsNeedingModel()
            let people: [PersonFound]
            do {
                people = try await engine.peopleFound()
            } catch {
                guard currentVisit == visit, peoplePicker != nil else { return }
                maskMessage = error.localizedDescription
                people = []
            }
            guard currentVisit == visit, peoplePicker != nil else { return }
            peoplePicker?.people = people
            peoplePicker?.chosen = people.count == 1 ? [people[0].id] : []
            foundPeople = (visit, people)
            await loadPeopleCrops(people, visit: visit)
        }
    }

    func closePeoplePicker() {
        peoplePicker = nil
        peopleCrops = [:]
        hoveredPersonBox = nil
    }

    func togglePerson(_ person: PersonFound) {
        guard peoplePicker != nil else { return }
        if peoplePicker?.chosen.remove(person.id) == nil {
            peoplePicker?.chosen.insert(person.id)
        }
    }

    /// Ticking a part whose model isn't downloaded asks to download it; Not Now unticks it.
    func togglePersonPart(_ part: PersonPart) {
        guard let picker = peoplePicker else { return }
        if peoplePicker?.parts.remove(part) == nil {
            peoplePicker?.parts.insert(part)
            if let model = picker.needsModel[part] {
                pendingModel = (model, .people, part, .vegetation)
            }
        }
    }

    func refreshPartsNeedingModel() async {
        var needs: [PersonPart: ModelInfo] = [:]
        for part in availablePersonParts {
            needs[part] = await engine.modelNeeded(for: .people, part: part)
        }
        peoplePicker?.needsModel = needs
    }

    /// The number of the person an AI People component is of, as the picker numbers them (left to
    /// right); nil for everyone, or before the photo's people are known. A face part is numbered
    /// by its face. In a crowd SAM 3's one piece is numbered too, but is no one's.
    func personNumber(part: PersonPart, instance: Int?) -> Int? {
        guard let instance, let (visit, people) = foundPeople, visit == currentVisit else { return nil }
        let index = faceParts.contains(part)
            ? people.firstIndex { $0.faceInstance == instance }
            : people.firstIndex { $0.instance == instance }
        return index.map { $0 + 1 }
    }

    /// Finds the photo's people for the components' names, once there are People components.
    func findPeopleForNames() async {
        guard let visit = currentVisit, foundPeople?.visit != visit else { return }
        let hasPeople = recipe.masks.flatMap(\.components).contains { component in
            guard case let .ai(mask) = component.shape else { return false }
            return mask.kind == .people
        }
        guard hasPeople, let people = try? await engine.peopleFound(), currentVisit == visit else { return }
        foundPeople = (visit, people)
    }

    func setPeopleSeparate(_ separate: Bool) {
        peoplePicker?.separate = separate
    }

    /// A square around each face (the person, when no face was found), from the photo as shot.
    private func loadPeopleCrops(_ people: [PersonFound], visit: PhotoVisit) async {
        guard !people.isEmpty,
              let image = try? await engine.renderStill(StillRequest(recipe: EditRecipe(), maxLongEdge: 1200))
        else { return }
        let (width, height) = (Double(image.width), Double(image.height))
        var crops: [Int: CGImage] = [:]
        for person in people {
            let box = person.face ?? person.box
            let side = max(box.width * width, box.height * height) * (person.face == nil ? 1 : 1.8)
            let rect = CGRect(
                x: box.x * width + box.width * width / 2 - side / 2,
                y: box.y * height + box.height * height / 2 - side / 2,
                width: side, height: side,
            ).intersection(CGRect(x: 0, y: 0, width: width, height: height))
            crops[person.id] = image.cropping(to: rect.integral)
        }
        guard currentVisit == visit, peoplePicker != nil else { return }
        peopleCrops = crops
    }

    /// Makes the picker's masks: one for everyone ticked, or one each; or, for a component, the
    /// parts added to (subtracted from, intersected with) the target. Asks first for any model
    /// a part needs, and carries on once it's downloaded.
    func createPeopleMasks() async {
        guard let picker = peoplePicker, let found = picker.people, let visit = currentVisit,
              aiMaskProgress == nil
        else { return }
        let people = found.filter { picker.chosen.contains($0.id) }
        let parts = PersonPart.allCases.filter(picker.parts.contains)
        guard !people.isEmpty, !parts.isEmpty else { return }
        for part in parts {
            if let model = await engine.modelNeeded(for: .people, part: part) {
                pendingModel = (model, .people, part, .vegetation)
                return
            }
        }
        guard currentVisit == visit, peoplePicker == picker else { return }
        let target = picker.mode.target
        let operation = picker.mode.operation
        guard target != nil || hasRoomForMask(recipe.masks) else { return }
        let combined = target != nil && operation != .add
        let everyone = people.contains { $0.instance == nil }
        let chosen = everyone ? nil : people.compactMap(\.instance)
        aiMaskProgress = .people
        maskMessage = nil
        defer { aiMaskProgress = nil }

        var byPerson: [Int: [MaskComponent]] = [:]
        var missing: [PersonPart] = []
        for part in parts {
            let request = MaskRequest(kind: .people, part: part, combined: combined, people: chosen)
            guard let masks = try? await engine.computeMasks(request), !masks.isEmpty else {
                missing.append(part)
                continue
            }
            guard currentVisit == visit else { return }
            for mask in masks {
                let owner = people.first { person in
                    faceParts.contains(part) ? person.faceInstance == mask.instance : person.instance == mask.instance
                } ?? people[0]
                byPerson[owner.id, default: []].append(MaskComponent(shape: .ai(mask)))
            }
        }
        guard currentVisit == visit else { return }
        guard !byPerson.isEmpty else {
            maskMessage = MaskComputationError.notFound(parts[0]).description
            return
        }
        if !missing.isEmpty {
            maskMessage = "Not found: \(missing.map(\.name).joined(separator: ", "))."
        }

        // "Face Skin"; nil for the whole person, or for several parts.
        let part = parts.count == 1 && parts[0] != .entirePerson ? parts[0].name : nil
        let title = part ?? "People"
        func name(of person: PersonFound) -> String {
            let name = picker.name(of: person)
            return part.map { "\($0) · \(name)" } ?? name
        }
        var next = recipe
        if let target, let index = next.masks.firstIndex(where: { $0.id == target }) {
            var components = people.flatMap { byPerson[$0.id] ?? [] }
            components[0].operation = operation
            next.masks[index].components += components
            selectedMaskID = target
            selectedComponentID = components.last?.id
            commit(next, .mask(.people), "\(operation.name) \(title)")
        } else if picker.separate, byPerson.count > 1 {
            for person in people {
                guard let components = byPerson[person.id], hasRoomForMask(next.masks) else { continue }
                next.masks.append(MaskLayer(name: name(of: person), components: components))
            }
            selectedMaskID = next.masks.last?.id
            selectedComponentID = nil
            commit(next, .mask(.people), "New \(title) Masks")
        } else {
            let components = people.flatMap { byPerson[$0.id] ?? [] }
            let mask = MaskLayer(
                name: people.count == 1 && found.count > 1 ? name(of: people[0]) : title, components: components,
            )
            next.masks.append(mask)
            selectedMaskID = mask.id
            selectedComponentID = components.last?.id
            commit(next, .mask(.people), "New \(title)")
        }
        closePeoplePicker()
    }
}
