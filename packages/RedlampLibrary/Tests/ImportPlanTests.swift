import Foundation
import RedlampDocument
import RedlampEngineAPI
import Testing
@testable import RedlampLibrary

struct ImportPlanTests {
    private static func shot(
        _ name: String, _ seconds: Double, contents: Data? = nil, sidecars: [String: Data] = [:],
    ) -> SimulatedCard.Shot {
        SimulatedCard.Shot(name: name, captured: cameraTime(seconds), contents: contents, sidecars: sidecars)
    }

    @Test func `folders come from capture dates and names from the template, collisions numbered in capture order`(
    ) async throws {
        let sandbox = try await ImportSandbox.make()
        defer { sandbox.remove() }
        // Named against their capture order, two days.
        let source = try sandbox.card("CARD", [
            Self.shot("IMG_0003.JPG", 1), Self.shot("IMG_0001.JPG", 2), Self.shot("IMG_0002.JPG", 3),
            Self.shot("IMG_0004.JPG", 86400 + 1), Self.shot("IMG_0005.JPG", 86400 + 2),
        ])
        // Names already taken: one at the destination, one at the backup, by another photo's raw.
        for (root, path) in [
            (sandbox.destination, "2026/2026-10-06/20261006.JPG"), (sandbox.backup, "2026/2026-10-05/20261005.NEF"),
        ] {
            let file = root.appending(path: path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            try Data("someone else's".utf8).write(to: file)
        }
        let session = sandbox.session([source], previews: false)
        let plan = try await session.plan(sandbox.settings(names: "{date:yyyyMMdd}"))
        let named = Dictionary(uniqueKeysWithValues: plan.items.map { item in
            (FilePlanner.split(item.copies[0].source).name, item.copies[0].path)
        })
        #expect(named == [
            "IMG_0003.JPG": "2026/2026-10-05/20261005-2.JPG", "IMG_0001.JPG": "2026/2026-10-05/20261005-3.JPG",
            "IMG_0002.JPG": "2026/2026-10-05/20261005-4.JPG", "IMG_0004.JPG": "2026/2026-10-06/20261006-2.JPG",
            "IMG_0005.JPG": "2026/2026-10-06/20261006-3.JPG",
        ])
        #expect(plan.items.map { FilePlanner.split($0.copies[0].source).name }
            == ["IMG_0003.JPG", "IMG_0001.JPG", "IMG_0002.JPG", "IMG_0004.JPG", "IMG_0005.JPG"])
        #expect(plan.numbered == 5 && plan.folders == ["2026", "2026/2026-10-05", "2026/2026-10-06"])
        let first = try #require(plan.items.first)
        #expect(plan.targets(of: first.copies[0]).map(\.path) == [
            sandbox.destination.path + "/2026/2026-10-05/20261005-2.JPG",
            sandbox.backup.path + "/2026/2026-10-05/20261005-2.JPG",
        ])

        // A level that comes out empty is left out; the camera's names are kept by default.
        let flat = try await session.plan(sandbox.settings(folders: "{date:yyyy}/{text:shoot}"))
        #expect(flat.items.map(\.copies[0].path).sorted() == (1 ... 5).map { String(format: "2026/IMG_%04d.JPG", $0) })
        var named2 = try sandbox.settings(folders: "{date:yyyy}/{date:yyyy-MM-dd}{text:shoot|before:\" \"}")
        named2.texts = ["shoot": "Harbour"]
        let shoot = try await session.plan(named2)
        #expect(shoot.folders == ["2026", "2026/2026-10-05 Harbour", "2026/2026-10-06 Harbour"])
        // Nothing was written while planning.
        #expect(ImportSandbox.files(in: sandbox.destination).count == 1)
    }

    @Test func `raw only leaves a raw's JPEG and the photos that aren't raws on the card`() async throws {
        let sandbox = try await ImportSandbox.make()
        defer { sandbox.remove() }
        let source = try sandbox.card("CARD", [
            Self.shot("IMG_0001.CR3", 1, contents: Data("raw 1".utf8), sidecars: ["IMG_0001.xmp": Data("<x/>".utf8)]),
            Self.shot("IMG_0001.JPG", 1), Self.shot("IMG_0002.JPG", 2),
            Self.shot(
                "IMG_0003.ARW",
                3,
                contents: Data("raw 3".utf8),
                sidecars: ["IMG_0003.JPG.xmp": Data("<x/>".utf8)],
            ),
            Self.shot("IMG_0003.JPG", 3),
        ])
        let session = sandbox.session([source], previews: false)
        let plan = try await session.plan(sandbox.settings(rawOnly: true))
        #expect(plan.items.map { $0.copies.map(\.name) } == [["IMG_0001.CR3", "IMG_0001.xmp"], ["IMG_0003.ARW"]])
        #expect(Set(plan.left.filter { $0.reason == .rawOnly }.map { ($0.file as NSString).lastPathComponent })
            == ["IMG_0001.JPG", "IMG_0002.JPG", "IMG_0003.JPG"])
        let all = try await session.plan(sandbox.settings())
        #expect(all.items.map { $0.copies.map(\.name) } == [
            ["IMG_0001.CR3", "IMG_0001.JPG", "IMG_0001.xmp"], ["IMG_0002.JPG"],
            ["IMG_0003.ARW", "IMG_0003.JPG", "IMG_0003.JPG.xmp"],
        ])
    }

    @Test func `a raw and its JPEG arrive together with their sidecars, renamed alike`() async throws {
        let sandbox = try await ImportSandbox.make()
        defer { sandbox.remove() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let rated = try encoder.encode(Sidecar(
            recipe: EditRecipe(), metadata: PhotoMetadata(rating: 2),
            modified: Date(timeIntervalSince1970: 1_790_000_000),
        ))
        let source = try sandbox.card("CARD", [
            Self.shot("IMG_0001.CR3", 1, contents: Data("raw 1".utf8), sidecars: [
                "IMG_0001.xmp": Data("<x:xmpmeta/>".utf8), "IMG_0001.CR3.xmp": Data("<x:xmpmeta darktable/>".utf8),
                "IMG_0001.JPG.redlamp/edit.json": rated,
            ]),
            Self.shot("IMG_0001.JPG", 1),
        ])
        let session = sandbox.session([source], previews: false)
        let plan = try await session.plan(sandbox.settings(names: "Harbour-{number}"))
        #expect(plan.items.count == 1)
        #expect(try Set(#require(plan.items.first).copies.map(\.name)) == [
            "Harbour-0001.CR3", "Harbour-0001.JPG", "Harbour-0001.xmp", "Harbour-0001.CR3.xmp",
            "Harbour-0001.JPG.redlamp",
        ])
        let outcome = try await session.importer().run(plan)
        #expect(outcome.verified == 1 && outcome.files == 5 && outcome.backups == 5 && outcome.isSafeToErase)
        let card = ImportSandbox.files(in: source.photosFolder.appending(path: "100CANON"))
        let backup = ImportSandbox.files(in: sandbox.backup.appending(path: "2026/2026-10-05"))
        let destination = ImportSandbox.files(in: sandbox.destination.appending(path: "2026/2026-10-05"))
        for (name, data) in card {
            let renamed = name.replacingOccurrences(of: "IMG_0001", with: "Harbour-0001")
            #expect(backup[renamed] == data, "\(renamed)")
            if !name.hasSuffix("edit.json") {
                #expect(destination[renamed] == data, "\(renamed)")
            }
        }
        // At the destination, each photo's .redlamp keeps what it held and records the name it had.
        let store = SidecarStore()
        let jpeg = sandbox.destination.appending(path: "2026/2026-10-05/Harbour-0001.JPG")
        let raw = sandbox.destination.appending(path: "2026/2026-10-05/Harbour-0001.CR3")
        #expect(store.load(for: jpeg)?.metadata?.rating == 2)
        #expect(store.load(for: jpeg)?.metadata?.originalName == "IMG_0001.JPG")
        #expect(store.load(for: raw)?.metadata?.originalName == "IMG_0001.CR3")
        #expect(ImportSandbox.leftovers(in: sandbox.destination).isEmpty && ImportSandbox.leftovers(in: sandbox.backup)
            .isEmpty)
    }
}
