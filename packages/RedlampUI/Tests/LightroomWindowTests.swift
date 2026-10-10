import AppKit
import Foundation
import RedlampDocument
import RedlampLibrary
import Testing
@_spi(Harness) @testable import RedlampUI

/// File › Import from Lightroom Classic… (LIB-29): the window's report of a catalog, its root folders added to
/// Folders and indexed before the import, the import with its progress, and Undo Import.
@MainActor
@Suite(.serialized)
struct LightroomWindowTests {
    /// A catalog of two root folders: the sandbox's root, in the library, and `other`, which isn't, with a photo
    /// in each, rated, picked, labelled and given a keyword and a collection.
    static func catalog(root: URL, other: URL, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let database = try SQLiteDatabase(path: url.path)
        func text(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
        }
        try database.execute("""
        CREATE TABLE AgLibraryRootFolder (id_local INTEGER PRIMARY KEY, absolutePath, name);
        CREATE TABLE AgLibraryFolder (id_local INTEGER PRIMARY KEY, pathFromRoot, rootFolder);
        CREATE TABLE AgLibraryFile (id_local INTEGER PRIMARY KEY, folder, idx_filename, sidecarExtensions);
        CREATE TABLE Adobe_images (id_local INTEGER PRIMARY KEY, colorLabels NOT NULL DEFAULT '', masterImage,
          copyName, pick NOT NULL DEFAULT 0, rating, rootFile);
        CREATE TABLE AgLibraryKeyword (id_local INTEGER PRIMARY KEY, name, parent, includeOnExport DEFAULT 1,
          includeParents DEFAULT 1, includeSynonyms DEFAULT 1, keywordType);
        CREATE TABLE AgLibraryKeywordImage (id_local INTEGER PRIMARY KEY, image, tag);
        CREATE TABLE AgLibraryCollection (id_local INTEGER PRIMARY KEY, creationId, name, parent,
          systemOnly NOT NULL DEFAULT '');
        CREATE TABLE AgLibraryCollectionImage (id_local INTEGER PRIMARY KEY, collection, image);
        INSERT INTO AgLibraryRootFolder VALUES (1, \(text(root.standardizedFileURL.path + "/")), 'Photos'),
          (2, \(text(other.standardizedFileURL.path + "/")), 'Other');
        INSERT INTO AgLibraryFolder VALUES (3, '', 1), (4, 'Day/', 2);
        INSERT INTO AgLibraryFile VALUES (5, 3, 'A.jpg', NULL), (6, 4, 'B.jpg', NULL);
        INSERT INTO Adobe_images VALUES (7, 'Green', NULL, NULL, 1, 4, 5), (8, 'Blue', NULL, NULL, 0, 3, 6);
        INSERT INTO AgLibraryKeyword VALUES (9, NULL, NULL, 1, 1, 1, NULL), (10, 'Window test', 9, 1, 1, 1, NULL);
        INSERT INTO AgLibraryKeywordImage VALUES (11, 7, 10), (12, 8, 10);
        INSERT INTO AgLibraryCollection VALUES (13, 'com.adobe.ag.library.collection', 'Window picks', NULL, '');
        INSERT INTO AgLibraryCollectionImage VALUES (14, 13, 7), (15, 13, 8);
        """)
    }

    @Test func `the window reports a catalog, adds its other folder, imports and takes the import back`() async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        try sandbox.photos(["A.jpg"])
        let other = sandbox.base.appending(path: "Other", directoryHint: .isDirectory)
        try sandbox.photos(["Day/B.jpg"], under: other, from: 1)
        let catalog = sandbox.base.appending(path: "Catalog/Lightroom Catalog.lrcat")
        try Self.catalog(root: sandbox.root, other: other, at: catalog)
        let model = try await sandbox.open()

        LightroomWindowController.show(editor: model)
        let window = try #require(LightroomWindowController.current)
        defer { window.close() }
        #expect(window.button("lightroom.import")?.enabled == false)
        window.choose(catalog: catalog)
        try await sandbox.eventually { window.isReported }
        let report = try #require(window.report)
        #expect(report.roots.map(\.state) == [.inLibrary, .notInLibrary])
        #expect(report.found == 1 && report.waiting == 1)
        #expect(window.button("lightroom.import")?.enabled == true)
        #expect(SidecarStore().load(for: sandbox.photo("A.jpg")) == nil, "the report writes nothing")

        window.model.startImport()
        try await sandbox.eventually(seconds: 90) { window.isImported }
        #expect(window.problem == nil, "\(window.problem ?? "")")
        #expect(window.outcome?.record.photos == 2)
        #expect(model.library.root(containing: other.appending(path: "Day/B.jpg")) != nil, "the folder is in Folders")
        let first = SidecarStore().load(for: sandbox.photo("A.jpg"))?.metadata
        #expect(first?.rating == 4 && first?.flag == .pick && first?.label == .green)
        #expect(first?.keywords == ["Window test"] && first?.collections == ["Window picks"])
        let second = SidecarStore().load(for: other.appending(path: "Day/B.jpg"))?.metadata
        #expect(second?.rating == 3 && second?.label == .blue && second?.collections == ["Window picks"])
        try await sandbox.eventually { window.button("lightroom.undo")?.enabled == true }

        window.model.undo()
        try await sandbox.eventually(seconds: 60) { window.isUndone }
        #expect(window.problem == nil, "\(window.problem ?? "")")
        #expect(SidecarStore().load(for: sandbox.photo("A.jpg"))?.metadata?.isEmpty ?? true)
        #expect(SidecarStore().load(for: other.appending(path: "Day/B.jpg"))?.metadata?.isEmpty ?? true)
        if let root = model.library.root(containing: other) {
            await model.library.remove(root)?.value
        }
    }

    @Test func `a catalog that can't be read says why, and a moved folder is found where it's located`() async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        try sandbox.photos(["A.jpg"])
        let model = try await sandbox.open()
        let model2 = LightroomImportModel(editor: model)
        let text = sandbox.base.appending(path: "notes.lrcat")
        try Data("not a catalog, only some text long enough for a header of sorts".utf8).write(to: text)
        model2.choose(text)
        try await sandbox.eventually { model2.phase == .choosing && model2.problem != nil }
        #expect(model2.problem?.contains("isn't a Lightroom Classic catalog") == true)

        let gone = URL(fileURLWithPath: "/Volumes/Gone \(UUID().uuidString)", isDirectory: true)
        let catalog = sandbox.base.appending(path: "Catalog/Moved.lrcat")
        try Self.catalog(root: gone, other: sandbox.base.appending(path: "Nowhere"), at: catalog)
        model2.choose(catalog)
        try await sandbox.eventually { model2.phase == .reported }
        #expect(model2.report?.roots.map(\.state) == [.missing, .missing])
        model2.locate(gone.standardizedFileURL.path + "/", at: sandbox.root)
        try await sandbox.eventually { model2.phase == .reported && model2.report?.found == 1 }
        #expect(model2.report?.roots.first?.moved == true && model2.report?.roots.first?.state == .inLibrary)
        #expect(model2.status.contains("Importing changes 1 photo"))
    }
}
