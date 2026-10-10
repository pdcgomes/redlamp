import Foundation
import RedlampEngineAPI
import Testing
@_spi(Harness) @testable import RedlampUI

/// The People picker (UX-21): who is in the photo and which of their parts become masks.
@MainActor
struct PeoplePickerTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

    /// Three people, whose faces Vision numbers the other way round, each with a mask.
    private func threePeople(_ engine: StubEngine = StubEngine()) async throws -> (EditorModel, StubEngine) {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        engine.people = (0 ..< 3).map { index in
            PersonFound(
                instance: index, faceInstance: 2 - index,
                box: ImageRect(x: 0.1 + 0.3 * Double(index), y: 0.2, width: 0.2, height: 0.6),
                face: ImageRect(x: 0.15 + 0.3 * Double(index), y: 0.25, width: 0.1, height: 0.1),
            )
        }
        engine.computed = (0 ..< 3).map { index in
            AIMask(
                kind: .people, provider: "stub", revision: 1, instance: index, analysisHash: "h",
                center: ImagePoint(x: 0.2 + 0.3 * Double(index), y: 0.5),
                bitmap: MaskBitmap(sha256: "p\(index)", width: 4, height: 4),
            )
        }
        let model = EditorModel(engine: engine)
        model.select(folder.appending(path: "IMG_0002.ARW"))
        for _ in 0 ..< 200 where model.info == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(model.info != nil)
        return (model, engine)
    }

    private func open(_ model: EditorModel, _ mode: MaskPickerMode = .new) async throws {
        model.openPeoplePicker(mode)
        for _ in 0 ..< 200 where model.peoplePicker?.people == nil || model.peopleCrops.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(model.peoplePicker?.people != nil)
    }

    /// Waits for what the editor asks the engine off the main actor, such as its list of AI masks
    /// (RESP-15), which can take seconds on a busy Mac.
    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func `the picker shows who is in the photo, with a crop of each, none ticked`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (model, _) = try await threePeople()
        try await open(model)
        let picker = try #require(model.peoplePicker)
        #expect(picker.people?.count == 3)
        #expect(picker.chosen.isEmpty)
        #expect(picker.parts == [.entirePerson])
        #expect(model.peopleCrops.count == 3)
        #expect(try picker.name(of: #require(picker.people?[1])) == "Person 2")
        #expect(model.activeTool == .masking)
    }

    @Test func `Esc closes the picker before it leaves the Masking tool`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (model, _) = try await threePeople()
        try await open(model)
        #expect(model.perform(.cancel))
        #expect(model.peoplePicker == nil)
        #expect(model.activeTool == .masking, "the first Esc closes the picker")
        #expect(model.perform(.cancel))
        #expect(model.activeTool == .edit, "the second leaves the tool")
    }

    @Test func `a person ticked gets a mask of their own, named for them`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (model, engine) = try await threePeople()
        try await open(model)
        try model.togglePerson(#require(model.peoplePicker?.people?[1]))
        await model.createPeopleMasks()
        #expect(engine.lastRequest?.people == [1])
        #expect(model.recipe.masks.count == 1)
        #expect(model.recipe.masks[0].name == "Person 2")
        #expect(model.recipe.masks[0].components.count == 1)
        #expect(model.history.last?.name == "New People")
        #expect(model.peoplePicker == nil)
    }

    @Test func `separate masks make one for each person ticked, in one step`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (model, _) = try await threePeople()
        try await open(model)
        for person in try #require(model.peoplePicker?.people) {
            model.togglePerson(person)
        }
        model.setPeopleSeparate(true)
        let steps = model.history.count
        await model.createPeopleMasks()
        #expect(model.recipe.masks.map(\.name) == ["Person 1", "Person 2", "Person 3"])
        #expect(model.history.count == steps + 1)
        #expect(model.history.last?.name == "New People Masks")
    }

    @Test func `several parts make one mask with a component for each`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (model, engine) = try await threePeople()
        try await open(model)
        try model.togglePerson(#require(model.peoplePicker?.people?[0]))
        model.togglePersonPart(.entirePerson)
        model.togglePersonPart(.hair)
        model.togglePersonPart(.faceSkin)
        await model.createPeopleMasks()
        #expect(engine.requests.suffix(2).map(\.part) == [.faceSkin, .hair])
        #expect(model.recipe.masks.count == 1)
        #expect(model.recipe.masks[0].name == "Person 1")
        #expect(model.recipe.masks[0].components.count == 2)
    }

    @Test func `one part of one person is named for both`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (model, _) = try await threePeople()
        try await open(model)
        try model.togglePerson(#require(model.peoplePicker?.people?[1]))
        model.togglePersonPart(.entirePerson)
        model.togglePersonPart(.faceSkin)
        await model.createPeopleMasks()
        #expect(model.recipe.masks.map(\.name) == ["Face Skin · Person 2"])
        #expect(model.history.last?.name == "New Face Skin")
    }

    @Test func `the picker subtracts the people ticked from a mask`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (model, engine) = try await threePeople()
        model.startDrawing(.radial)
        model.beginDrawing(.radial(RadialMask(center: ImagePoint(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.2)))
        model.finishDrawing()
        let target = try #require(model.recipe.masks.first?.id)
        try await open(model, .component(.subtract, target: target))
        try model.togglePerson(#require(model.peoplePicker?.people?[2]))
        await model.createPeopleMasks()
        #expect(engine.lastRequest?.combined == true)
        #expect(engine.lastRequest?.people == [2])
        #expect(model.recipe.masks.count == 1)
        #expect(model.recipe.masks[0].components.last?.operation == .subtract)
        #expect(model.history.last?.name == "Subtract People")
    }

    /// A mask's components combine in order: each part ticked has to subtract, or the parts
    /// after the first are added back.
    @Test func `the picker subtracts every part ticked from a mask`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (model, _) = try await threePeople()
        let target = try drawRadial(in: model)
        try await open(model, .component(.subtract, target: target))
        try model.togglePerson(#require(model.peoplePicker?.people?[0]))
        model.togglePersonPart(.entirePerson)
        model.togglePersonPart(.faceSkin)
        model.togglePersonPart(.hair)
        await model.createPeopleMasks()
        let added = try #require(model.recipe.masks.first?.components.dropFirst())
        #expect(added.count == 2)
        #expect(added.allSatisfy { $0.operation == .subtract })
    }

    /// Intersecting with several parts would need them as one component.
    @Test func `the picker intersects a mask with one part at a time`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (model, _) = try await threePeople()
        let target = try drawRadial(in: model)
        try await open(model, .component(.intersect, target: target))
        try model.togglePerson(#require(model.peoplePicker?.people?[0]))
        model.togglePersonPart(.faceSkin)
        #expect(model.peoplePicker?.canCreate == false, "Entire Person and Face Skin")
        await model.createPeopleMasks()
        #expect(model.recipe.masks.first?.components.count == 1)
        model.togglePersonPart(.entirePerson)
        #expect(model.peoplePicker?.canCreate == true)
        await model.createPeopleMasks()
        #expect(model.recipe.masks.first?.components.count == 2)
        #expect(model.recipe.masks.first?.components.last?.operation == .intersect)
    }

    @Test func `opening another photo closes the picker`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (model, _) = try await threePeople()
        try await open(model)
        let other = folder.appending(path: "IMG_0003.ARW")
        model.select(other)
        for _ in 0 ..< 400 where model.info?.url != other {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.info?.url == other)
        #expect(model.peoplePicker == nil)
        #expect(model.peopleCrops.isEmpty)
    }

    private func drawRadial(in model: EditorModel) throws -> UUID {
        model.startDrawing(.radial)
        model.beginDrawing(.radial(RadialMask(center: ImagePoint(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.2)))
        model.finishDrawing()
        return try #require(model.recipe.masks.first?.id)
    }

    /// The engine's list of People parts can arrive after the picker opens (RESP-15).
    @Test func `ticking a part whose model isn't here asks for it, and Not Now unticks it`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = StubEngine()
        engine.neededModel = ModelInfo(
            id: "sam3", name: "SAM 3", purpose: "People parts", downloadBytes: 1, state: .notDownloaded,
        )
        engine.partsNeedingModel = [.hair]
        engine.maskList.hold()
        defer { engine.maskList.release() }
        let (model, _) = try await threePeople(engine)
        try await open(model)
        engine.maskList.release()
        try await eventually { model.peoplePicker?.needsModel[.hair] != nil }
        #expect(model.peoplePicker?.needsModel[.hair]?.id == "sam3")
        model.togglePersonPart(.hair)
        #expect(model.pendingModel?.part == .hair)
        model.declinePendingModel()
        #expect(model.pendingModel == nil)
        #expect(model.peoplePicker?.parts == [.entirePerson])
    }

    @Test func `with nobody found the picker says so and makes nothing`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (model, engine) = try await threePeople()
        engine.people = []
        model.openPeoplePicker(.new)
        for _ in 0 ..< 200 where model.peoplePicker?.people == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.peoplePicker?.people == [])
        await model.createPeopleMasks()
        #expect(model.recipe.masks.isEmpty)
    }

    /// A face part is numbered by face, which the people found map to their person.
    @Test func `components name the person they are of`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (model, _) = try await threePeople()
        #expect(model.personNumber(part: .hair, instance: 1) == nil)
        try await open(model)
        model.closePeoplePicker()
        #expect(model.personNumber(part: .hair, instance: 1) == 2)
        #expect(model.personNumber(part: .hair, instance: 5) == nil)
        #expect(model.personNumber(part: .faceSkin, instance: 2) == 1)
        #expect(model.personNumber(part: .lips, instance: 0) == 3)
        #expect(model.personNumber(part: .entirePerson, instance: nil) == nil)
    }
}
