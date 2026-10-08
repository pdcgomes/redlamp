import Foundation
import RedlampBench
import RedlampEngineAPI
import Testing

struct BenchFolderTests {
    @Test func `A manifest round-trips and keeps the fields a newer Redlamp wrote`() throws {
        let scratch = Scratch()
        let folder = try makeTask(in: scratch)
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: folder.url.appending(
            path: BenchManifest.fileName,
        ))) as? [String: Any])
        json["futureField"] = ["kept": true]
        try JSONSerialization.data(withJSONObject: json).write(to: folder.url.appending(path: BenchManifest.fileName))

        let reloaded = try BenchFolder.load(folder.url)
        #expect(reloaded.manifest.unknownFields["futureField"] == .object(["kept": .bool(true)]))
        try reloaded.saveManifest()
        let again = try BenchFolder.load(folder.url)
        #expect(again.manifest.unknownFields["futureField"] == .object(["kept": .bool(true)]))
        #expect(again.manifest.steps == folder.manifest.steps)
        #expect(again.manifest.steps[0].action == .share(assets: nil))
        #expect(again.manifest.requestedBy?.tracker == "DEC-08")
    }

    @Test func `A new task records each asset's hash and checks out clean`() throws {
        let scratch = Scratch()
        let folder = try makeTask(in: scratch)
        #expect(folder.manifest.assets.map(\.id) == ["photo-1", "photo-2", "photo-3"])
        #expect(folder.manifest.assets.allSatisfy { $0.sha256.count == 64 && $0.bytes > 0 })
        #expect(folder.validate().isEmpty)
        #expect(!folder.isComplete)
        #expect(folder.missing == ["photo-1", "photo-2", "photo-3"])
    }

    @Test func `Validation catches paths outside the folder, changed files and bad step references`() throws {
        let scratch = Scratch()
        var folder = try makeTask(in: scratch)
        folder.manifest.assets[0].file = "../escape.png"
        try Data("changed".utf8).write(to: folder.url.appending(path: folder.manifest.assets[1].file))
        folder.manifest.steps.append(.init(id: "q", title: "Answer", action: .answer(question: "missing")))
        folder.manifest.steps.append(.init(id: "x", title: "Share one", action: .share(assets: ["nope"])))
        folder.manifest.steps.append(.init(id: "long", title: "Long", detail: String(repeating: "word ", count: 80)))

        let messages = folder.validate().map(\.description)
        #expect(messages.contains { $0.hasPrefix("error") && $0.contains("../escape.png is outside the folder") })
        #expect(messages.contains { $0.contains("photo-2.png") && ($0.contains("SHA-256") || $0.contains("bytes")) })
        #expect(messages.contains { $0.contains("question missing") })
        #expect(messages.contains { $0.contains("asset nope") })
        #expect(messages.contains { $0.hasPrefix("warning") && $0.contains("too long for one screen") })
    }

    @Test func `Only safe relative paths stay inside a folder`() {
        for path in ["assets/a.jpg", "results/1-x.png", "a"] {
            #expect(BenchFile.isSafeRelativePath(path))
        }
        for path in ["", "/etc/passwd", "../x", "assets/../../x", "assets//x", "~/x", "a\\b", "./x"] {
            #expect(!BenchFile.isSafeRelativePath(path))
        }
        #expect(BenchFile.safeName("IMG 1234 (2).JPG") == "IMG-1234--2-.JPG")
        #expect(BenchFile.safeName("../../x") == "-..-x")
    }

    @Test func `A task is complete when every asset that counts has a result and questions are answered`() throws {
        let scratch = Scratch()
        var folder = try makeTask(in: scratch)
        folder.manifest.questions = [.init(id: "sky", text: "Did it select the whole sky?", choices: ["Yes", "No"])]
        folder.manifest.assets[2].counts = false
        try folder.saveManifest()
        for asset in folder.manifest.assets.prefix(2) {
            let result = try TestImages.write(TestImages.photo(seed: 99), to: scratch.file("\(asset.id)-out.png"))
            try folder.addResult(copying: result, originalName: "\(asset.id).png", pairer: BenchPairer(folder: folder))
        }
        #expect(folder.missing.isEmpty)
        #expect(!folder.isComplete)
        folder.results.answers["sky"] = "Yes"
        #expect(folder.isComplete)
        #expect(folder.isMet(folder.manifest.steps[2]))
        #expect(!folder.isMet(folder.manifest.steps[0]))
    }

    @Test func `IDs are lowercase slugs`() {
        let id = BenchManifest.newID(title: "Prequel · Cine Film 2", date: Date(timeIntervalSince1970: 1_791_446_400))
        #expect(BenchManifest.isValidID(id))
        #expect(id.contains("prequel-cine-film-2"))
        #expect(!BenchManifest.isValidID("Has Spaces"))
        #expect(!BenchManifest.isValidID(".hidden"))
    }
}
