import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampDocument

struct JSONPatchTests {
    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    private func roundTrips(_ old: String, _ new: String) throws -> [JSONPatch.Operation] {
        let before = try json(old)
        let after = try json(new)
        let patch = JSONPatch.diff(from: before, to: after)
        #expect(try JSONPatch.apply(patch, to: before) == after)
        return patch
    }

    @Test func `objects change key by key`() throws {
        let patch = try roundTrips(#"{"a":1,"b":{"c":2,"d":3},"e":4}"#, #"{"a":1,"b":{"c":5,"f":6},"g":7}"#)
        #expect(Set(patch) == [
            JSONPatch.Operation(.remove, "/e"),
            JSONPatch.Operation(.remove, "/b/d"),
            JSONPatch.Operation(.replace, "/b/c", .number(5)),
            JSONPatch.Operation(.add, "/b/f", .number(6)),
            JSONPatch.Operation(.add, "/g", .number(7)),
        ])
    }

    @Test func `an appended element is one add`() throws {
        let patch = try roundTrips(#"{"strokes":[[1,2],[3,4]]}"#, #"{"strokes":[[1,2],[3,4],[5,6]]}"#)
        #expect(patch == [JSONPatch.Operation(.add, "/strokes/2", .array([.number(5), .number(6)]))])
    }

    @Test func `one element inserted or removed moves the rest along`() throws {
        #expect(try roundTrips("[1,2,3,4]", "[1,3,4]") == [JSONPatch.Operation(.remove, "/1")])
        #expect(try roundTrips("[1,3,4]", "[1,2,3,4]") == [JSONPatch.Operation(.add, "/1", .number(2))])
    }

    @Test func `arrays change element by element, and shorten from the end`() throws {
        _ = try roundTrips("[1,2,3,4,5]", "[1,9,3]")
        _ = try roundTrips("[1,2]", "[7,8,9,10]")
        _ = try roundTrips(#"[{"x":1},{"x":2}]"#, #"[{"x":1},{"x":3}]"#)
    }

    @Test func `keys with slashes and tildes are escaped`() throws {
        let patch = try roundTrips(#"{"a/b":1,"m~n":2}"#, #"{"a/b":3,"m~n":4}"#)
        #expect(Set(patch.map(\.path)) == ["/a~1b", "/m~0n"])
    }

    @Test func `a value of another type is replaced, and so is the whole document`() throws {
        _ = try roundTrips(#"{"a":[1]}"#, #"{"a":{"b":1}}"#)
        #expect(try roundTrips("[1]", #"{"a":1}"#) == [JSONPatch.Operation(.replace, "", json(#"{"a":1}"#))])
    }

    @Test func `bad paths are errors`() throws {
        let document = try json(#"{"a":[1,2]}"#)
        #expect(throws: JSONPatch.Error.invalidPath("/b/c")) {
            try JSONPatch.apply([JSONPatch.Operation(.add, "/b/c", .number(1))], to: document)
        }
        #expect(throws: JSONPatch.Error.invalidPath("/a/5")) {
            try JSONPatch.apply([JSONPatch.Operation(.replace, "/a/5", .number(1))], to: document)
        }
        #expect(throws: JSONPatch.Error.missingValue("/a/0")) {
            try JSONPatch.apply([JSONPatch.Operation(.replace, "/a/0")], to: document)
        }
    }
}

struct HistorySessionTests {
    private func stroke(_ x: Double) -> BrushStroke {
        BrushStroke(points: (0 ..< 50).map { ImagePoint(x: x, y: Double($0) / 50) }, size: 0.05)
    }

    @Test func `actions are written as short strings, and unknown ones read as edits`() throws {
        let actions: [HistoryAction] = [
            .open, .adjustment(.exposure), .mask(.brush), .mask(nil), .crop, .restore, .reset, .edit,
        ]
        let data = try JSONEncoder().encode(actions)
        #expect(String(bytes: data, encoding: .utf8)
            == #"["open","adjustment:basic.exposure","mask:brush","mask","crop","restore","reset","edit"]"#)
        #expect(try JSONDecoder().decode([HistoryAction].self, from: data) == actions)
        let future = Data(#"["hologram","adjustment:future.slider","mask:lasso"]"#.utf8)
        #expect(try JSONDecoder().decode([HistoryAction].self, from: future) == [.edit, .edit, .mask(nil)])
    }

    @Test func `a step reads as one line`() {
        let recipe = EditRecipe()
        #expect(HistoryStep(
            action: .adjustment(.exposure),
            title: "Exposure",
            before: "0.00",
            after: "+0.50",
            recipe: recipe,
        ).name == "Exposure: 0.00 → +0.50")
        #expect(HistoryStep(action: .recipe, title: "Recipe", after: "Portra", recipe: recipe).name == "Recipe: Portra")
        #expect(HistoryStep(action: .mask(.brush), title: "Brush Stroke", recipe: recipe).name == "Brush Stroke")
    }

    @Test func `a session round trips, each step stored as the change from the one before`() throws {
        var recipe = EditRecipe()
        var steps = [HistoryStep(action: .open, title: "Opened", recipe: recipe)]
        recipe[.exposure] = 0.5
        steps.append(HistoryStep(
            action: .adjustment(.exposure),
            title: "Exposure",
            before: "0.00",
            after: "+0.50",
            recipe: recipe,
        ))
        recipe.masks = [MaskLayer(name: "Mask 1", components: [MaskComponent(shape: .brush(BrushMask(
            strokes: [stroke(0.1)],
        )))])]
        steps.append(HistoryStep(action: .mask(.brush), title: "New Brush", recipe: recipe))
        for x in [0.2, 0.3, 0.4] {
            guard case var .brush(brush) = recipe.masks[0].components[0].shape else { return }
            brush.strokes.append(stroke(x))
            recipe.masks[0].components[0].shape = .brush(brush)
            steps.append(HistoryStep(action: .mask(.brush), title: "Brush Stroke", recipe: recipe))
        }
        let session = HistorySession(started: Date(timeIntervalSince1970: 1_000_000), steps: steps)

        let data = try session.encoded()
        let decoded = try HistorySession(decoding: data)
        #expect(decoded == session)

        let file = try JSONDecoder.sidecar.decode(HistoryFile.self, from: data)
        #expect(file.steps[0].recipe != nil && file.steps[0].patch == nil)
        #expect(file.steps[1].patch == [JSONPatch.Operation(.add, "/values/basic.exposure", .number(0.5))])
        let lastStroke = try #require(file.steps.last?.patch)
        #expect(lastStroke.count == 1)
        #expect(lastStroke.first?.path.hasSuffix("/strokes/3") == true)
    }

    @Test func `a file from a newer format isn't read`() throws {
        let data = try HistorySession(steps: [HistoryStep(action: .open, title: "Opened", recipe: EditRecipe())])
            .encoded()
        let json = try #require(String(bytes: data, encoding: .utf8))
        let newer = Data(json.replacingOccurrences(of: #""version" : 1"#, with: #""version" : 9"#).utf8)
        #expect(throws: HistoryFileError.unsupported) { try HistorySession(decoding: newer) }
    }
}

struct SidecarHistoryTests {
    private func temporaryImage() throws -> (URL, () -> Void) {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory.appending(path: "IMG_0001.ARW"), { try? FileManager.default.removeItem(at: directory) })
    }

    /// Files keep whole seconds.
    private func session(started: Date = Date(timeIntervalSince1970: 1000), exposure: Double = 0.5) -> HistorySession {
        var recipe = EditRecipe()
        let opened = HistoryStep(action: .open, title: "Opened", recipe: recipe)
        recipe[.exposure] = exposure
        return HistorySession(started: started, steps: [
            opened, HistoryStep(action: .adjustment(.exposure), title: "Exposure", recipe: recipe),
        ])
    }

    private func historyFiles(_ store: SidecarStore, _ image: URL) -> [String] {
        let directory = store.url(for: image).appending(path: SidecarStore.historyDirectory)
        return ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    private func subjectMask(_ png: Data) -> MaskLayer {
        MaskLayer(name: "Subject", components: [MaskComponent(shape: .ai(AIMask(
            kind: .subject, provider: "test", revision: 1, analysisHash: "0", center: ImagePoint(x: 0.5, y: 0.5),
            bitmap: MaskBitmap(png: png, width: 4, height: 2),
        )))])
    }

    @Test func `the open session is saved beside the edit and loads back`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        let open = session()
        try store.save(Sidecar(recipe: #require(open.steps.last?.recipe), session: open), for: image)

        #expect(historyFiles(store, image) == ["\(open.id.uuidString).json"])
        #expect(store.loadHistory(for: image) == [open])
        #expect(store.load(for: image)?.session == nil, "the edit's JSON doesn't hold history")
    }

    @Test func `a session without edits isn't kept`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        var open = session()
        var recipe = EditRecipe()
        recipe[.contrast] = 10
        try store.save(Sidecar(recipe: recipe, session: open), for: image)
        #expect(historyFiles(store, image).count == 1)

        open.steps.removeLast()
        try store.save(Sidecar(recipe: recipe, session: open), for: image)
        #expect(historyFiles(store, image).isEmpty)
    }

    @Test func `history changes are written when the edit hasn't changed`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        var open = session()
        let recipe = try #require(open.steps.last?.recipe)
        try store.save(Sidecar(recipe: recipe, session: open), for: image)
        let edit = try Data(contentsOf: store.editURL(for: image))

        open.steps.append(HistoryStep(action: .edit, title: "Edit", recipe: recipe))
        try store.save(Sidecar(recipe: recipe, session: open), for: image)
        #expect(try Data(contentsOf: store.editURL(for: image)) == edit)
        #expect(store.loadHistory(for: image).first?.steps.count == 3)
    }

    @Test func `saving without a session leaves history alone, and clearing removes the others`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        let first = session(started: Date(timeIntervalSince1970: 1000))
        try store.save(Sidecar(recipe: #require(first.steps.last?.recipe), session: first), for: image)
        var metadataOnly = try #require(store.load(for: image))
        metadataOnly.metadata = PhotoMetadata(rating: 3)
        try store.save(metadataOnly, for: image)
        #expect(historyFiles(store, image).count == 1)

        let second = session(started: Date(timeIntervalSince1970: 2000), exposure: 1)
        var cleared = try Sidecar(recipe: #require(second.steps.last?.recipe), session: second)
        cleared.clearsHistory = true
        try store.save(cleared, for: image)
        #expect(historyFiles(store, image) == ["\(second.id.uuidString).json"])
    }

    @Test func `only the most recent sessions are kept`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        let sessions = (0 ..< SidecarStore.keptSessions + 3).map {
            session(started: Date(timeIntervalSince1970: 1000 + Double($0) * 60), exposure: Double($0) / 10)
        }
        for session in sessions {
            try store.save(Sidecar(recipe: #require(session.steps.last?.recipe), session: session), for: image)
        }
        let kept = store.loadHistory(for: image)
        #expect(kept.count == SidecarStore.keptSessions)
        #expect(kept.map(\.id) == sessions.suffix(SidecarStore.keptSessions).reversed().map(\.id), "newest first")
    }

    @Test func `history keeps a sidecar whose edit is back to defaults`() {
        let open = session()
        #expect(!Sidecar(recipe: EditRecipe(), session: open).isPristine)
        var undone = open
        undone.steps.removeLast()
        #expect(Sidecar(recipe: EditRecipe(), session: undone).isPristine)
    }

    @Test func `bitmaps that only history uses are kept, and come back with it`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        let png = Data("subject".utf8)
        var masked = EditRecipe()
        masked.masks = [subjectMask(png)]
        let open = HistorySession(steps: [
            HistoryStep(action: .open, title: "Opened", recipe: EditRecipe()),
            HistoryStep(action: .mask(.subject), title: "New Subject", recipe: masked),
            HistoryStep(action: .mask(nil), title: "Delete Subject", recipe: EditRecipe()),
        ])
        var edit = EditRecipe()
        edit[.exposure] = 0.3
        try store.save(Sidecar(recipe: edit, session: open), for: image)
        edit[.exposure] = 0.4
        try store.save(Sidecar(recipe: edit), for: image)

        let sha = MaskBitmap.hash(png)
        #expect(FileManager.default.fileExists(atPath: store.bitmapURL(sha, for: image).path))
        #expect(store.loadHistory(for: image).first?.steps[1].recipe.maskBitmaps.first?.png == png)
    }

    @Test func `a conflicting copy's sessions are added, with their bitmaps`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let (other, cleanupOther) = try temporaryImage()
        defer { cleanupOther() }
        let store = SidecarStore()
        let mine = session(started: Date(timeIntervalSince1970: 1000))
        try store.save(Sidecar(recipe: #require(mine.steps.last?.recipe), session: mine), for: image)
        let png = Data("theirs".utf8)
        var masked = EditRecipe()
        masked.masks = [subjectMask(png)]
        let theirs = HistorySession(started: Date(timeIntervalSince1970: 2000), steps: [
            HistoryStep(action: .open, title: "Opened", recipe: EditRecipe()),
            HistoryStep(action: .mask(.subject), title: "New Subject", recipe: masked),
        ])
        try store.save(Sidecar(recipe: masked, session: theirs), for: other)

        try SidecarStore.copyHistory(from: store.url(for: other), into: store.url(for: image))
        let loaded = store.loadHistory(for: image)
        #expect(loaded.map(\.id) == [theirs.id, mine.id])
        #expect(loaded.first?.steps.last?.recipe.maskBitmaps.first?.png == png)
    }

    // MARK: - Emptied sidecars

    @Test func `clearing the rating of a reset photo keeps its history`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        try store.save(
            Sidecar(recipe: EditRecipe(), metadata: PhotoMetadata(rating: 2), session: session()),
            for: image,
        )

        try Library.writeMetadata(for: image, store: store) { $0 = PhotoMetadata() }
        #expect(store.loadHistory(for: image).count == 1)
        // Rolling back: what is kept is an edit the previous build reads.
        let edit = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: store.editURL(for: image)))
        guard case let .object(root) = edit else {
            Issue.record("sidecar did not encode as an object")
            return
        }
        #expect(Set(root.keys).isSubset(of: ["format", "recipe", "snapshots", "metadata", "modified"]))
        #expect(store.load(for: image)?.recipe.isPristine == true)
    }

    @Test func `an emptied sidecar keeps fields this build doesn't know`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        let json = #"{"format":"app.redlamp.edit","recipe":{"version":1,"processVersion":1},"keywords":["harbour"]}"#
        try Data(json.utf8).write(to: store.url(for: image))

        try store.saveOrRemove(Sidecar(recipe: EditRecipe()), for: image)
        #expect(store.load(for: image)?.unknownFields["keywords"] == .array([.string("harbour")]))
    }

    @Test func `an emptied sidecar with nothing else in it is removed, and none is made`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        var recipe = EditRecipe()
        recipe[.exposure] = 0.5
        try store.save(Sidecar(recipe: recipe), for: image)

        try store.saveOrRemove(Sidecar(recipe: EditRecipe()), for: image)
        #expect(!FileManager.default.fileExists(atPath: store.url(for: image).path))
        try store.saveOrRemove(Sidecar(recipe: EditRecipe()), for: image)
        #expect(!FileManager.default.fileExists(atPath: store.url(for: image).path))

        let open = session()
        try store.save(Sidecar(recipe: #require(open.steps.last?.recipe), session: open), for: image)
        var cleared = Sidecar(recipe: EditRecipe(), session: HistorySession(steps: []))
        cleared.clearsHistory = true
        try store.saveOrRemove(cleared, for: image)
        #expect(!FileManager.default.fileExists(atPath: store.url(for: image).path), "Clear History on a reset photo")
    }
}
