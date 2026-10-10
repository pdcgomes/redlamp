import AppKit
import CoreGraphics
import Foundation
import ImageIO
import RedlampDocument
import RedlampLibrary
import Testing
import UniformTypeIdentifiers
@_spi(Harness) @testable import RedlampUI

/// Show Photos in Subfolders (LIB-10): on by default, as in Lightroom Classic, a choice the user made kept;
/// each folder of the tree counted from the library's index, its own photos or with those below it, as
/// photos come and go; and a folder holding only folders showing every photo beneath it.
@MainActor
struct FolderCountsTests {
    private let base = FileManager.default.temporaryDirectory
        .appending(path: "folder-counts-\(UUID().uuidString)", directoryHint: .isDirectory).standardizedFileURL
    private let suite = "folder-counts-tests-\(UUID().uuidString)"

    private var root: URL {
        base.appending(path: "Photos", directoryHint: .isDirectory)
    }

    private var defaults: UserDefaults {
        UserDefaults(suiteName: suite)!
    }

    private let opened = Opened()

    @MainActor
    final class Opened {
        var services: [LibraryService] = []
    }

    private func cleanUp() {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: photo("Year/B/C/locked.JPG").path,
        )
        LibrarySandbox.remove(base, closing: opened.services)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func folder(_ path: String) -> URL {
        root.appending(path: path, directoryHint: .isDirectory)
    }

    private func photo(_ path: String) -> URL {
        root.appending(path: path, directoryHint: .notDirectory)
    }

    /// Small JPEGs at `paths` below the root, each its own colour.
    private func photos(_ paths: [String], from shade: Int = 0) throws {
        for (number, path) in paths.enumerated() {
            let url = photo(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            )
            let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try #require(CGContext(
                data: nil, width: 48, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
            ))
            let tone = shade + number
            context.setFillColor(
                red: CGFloat(tone % 7) / 7, green: CGFloat(tone % 5) / 5, blue: CGFloat(tone % 3) / 3, alpha: 1,
            )
            context.fill(CGRect(x: 0, y: 0, width: 48, height: 32))
            let data = NSMutableData()
            let destination = try #require(CGImageDestinationCreateWithData(
                data, UTType.jpeg.identifier as CFString, 1, nil,
            ))
            try CGImageDestinationAddImage(destination, #require(context.makeImage()), nil)
            #expect(CGImageDestinationFinalize(destination))
            try (data as Data).write(to: url)
        }
    }

    private func eventually(seconds: Double = 5, _ condition: () -> Bool) async throws {
        for _ in 0 ..< Int(seconds * 200) where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// A library following the root, once it has indexed it and caught up with the disk.
    private func indexedLibrary() async throws -> (FolderLibrary, LibraryService) {
        let library = FolderLibrary()
        library.add([root])
        let service = LibraryService(
            paths: LibraryPaths(root: base.appending(path: "Library", directoryHint: .isDirectory)),
            sidecars: library.sidecars,
        ) { url, size in StoreThumbnailMaker.imageIO(url, nil, size) }
        opened.services.append(service)
        library.attach(service)
        for _ in 0 ..< 2000 where await !service.canShow(root, includingSubfolders: true) {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await service.canShow(root, includingSubfolders: true), "the library caught up with the root")
        return (library, service)
    }

    private func rows(_ outline: SidebarOutlineView) -> [String: FolderRow] {
        var rows: [String: FolderRow] = [:]
        for row in 0 ..< outline.numberOfRows {
            if let node = outline.item(atRow: row) as? SidebarNode, case let .folder(folder) = node.kind {
                rows[folder.name] = folder
            }
        }
        return rows
    }

    @Test func `the Show Photos in Subfolders setting is on by default, and a choice the user made is kept`() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(FolderLibrary().includesSubfolders)
        #expect(FolderLibrary(defaults: defaults).includesSubfolders)

        // Earlier versions wrote their default, off, at every save, so what they wrote isn't a choice.
        defaults.set(false, forKey: "folders.subfolders")
        let upgraded = FolderLibrary(defaults: defaults)
        #expect(upgraded.includesSubfolders)
        upgraded.add([root])
        #expect(FolderLibrary(defaults: defaults).includesSubfolders, "saving the working set chooses nothing")

        upgraded.setIncludesSubfolders(false)
        #expect(!FolderLibrary(defaults: defaults).includesSubfolders, "turned off, it stays off")
        upgraded.setIncludesSubfolders(true)
        #expect(FolderLibrary(defaults: defaults).includesSubfolders, "turned on again, it stays on")
    }

    @Test func `a folder counts its own photos, or with subfolders every photo below it, from the index as photos come and go`(
    ) async throws {
        defer { cleanUp() }
        try photos(["top.JPG", "Year/A/1.JPG", "Year/A/2.JPG", "Year/B/3.JPG", "Year/B/C/4.JPG", "Year/B/C/5.JPG"])
        let (library, _) = try await indexedLibrary()
        try await eventually { library.photoCount(of: root) == 6 }
        #expect(library.includesSubfolders)
        #expect(library.photoCount(of: root) == 6)
        #expect(library.photoCount(of: folder("Year")) == 5, "a folder holding only folders counts their photos")
        #expect(library.photoCount(of: folder("Year/B")) == 3)
        #expect(library.photoCount(of: folder("Year/B/C")) == 2)
        #expect(library.tree.isEmpty, "counted from the index, not from listings of the disk")

        library.setIncludesSubfolders(false)
        #expect(library.photoCount(of: root) == 1)
        #expect(library.photoCount(of: folder("Year")) == 0)
        #expect(library.photoCount(of: folder("Year/B")) == 1)
        #expect(library.photoCount(of: folder("Year/B/C")) == 2)

        library.setIncludesSubfolders(true)
        try photos(["Year/B/C/6.JPG", "Year/A/New/7.JPG"], from: 10)
        try await eventually(seconds: 30) { library.photoCount(of: root) == 8 }
        #expect(library.photoCount(of: root) == 8)
        #expect(library.photoCount(of: folder("Year")) == 7)
        #expect(library.photoCount(of: folder("Year/A")) == 3)
        #expect(library.photoCount(of: folder("Year/A/New")) == 1)
        #expect(library.photoCount(of: folder("Year/B/C")) == 3)

        try FileManager.default.removeItem(at: photo("Year/B/3.JPG"))
        try FileManager.default.removeItem(at: folder("Year/A/New"))
        try await eventually(seconds: 30) { library.photoCount(of: root) == 6 }
        #expect(library.photoCount(of: root) == 6)
        #expect(library.photoCount(of: folder("Year/B")) == 3)
        #expect(library.photoCount(of: folder("Year/A")) == 2)
        #expect(
            library.photoCount(of: folder("Year/A/New")) == 0,
            "a folder gone from the disk counts its missing photo as none",
        )
        library.setIncludesSubfolders(false)
        #expect(library.photoCount(of: folder("Year/B")) == 0)
    }

    @Test func `the Folders panel shows the library's counts, a changed count in its row and the other rows as they were`(
    ) async throws {
        defer { cleanUp() }
        try photos(["Year/A/1.JPG", "Year/A/2.JPG", "Year/B/3.JPG"])
        let (library, _) = try await indexedLibrary()
        library.setExpanded(root, true)
        library.setExpanded(folder("Year"), true)
        let model = EditorModel(engine: StubEngine(), library: library)
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 260, height: 400), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        let list = SidebarListView(model: model)
        window.contentView = list
        defer { window.contentView = nil }
        list.layoutSubtreeIfNeeded()
        // Each row's folder listed (for its subfolders) as it first shows, and so made again once.
        try await eventually {
            ["", "Year", "Year/A", "Year/B"].allSatisfy { library.node(for: folder($0)) != nil }
                && rows(list.folders)["A"]?.count == 2 && rows(list.folders)["Year"]?.count == 3
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(rows(list.folders)["Photos"]?.count == 3)
        #expect(rows(list.folders)["Year"]?.count == 3 && rows(list.folders)["Year"]?.isSelectable == true)
        #expect(rows(list.folders)["B"]?.count == 1)

        let b = try #require((0 ..< list.folders.numberOfRows).first { row in
            (list.folders.item(atRow: row) as? SidebarNode).map { node in
                if case let .folder(folder) = node.kind {
                    folder.name == "B"
                } else {
                    false
                }
            } ?? false
        })
        let neighbour = list.folders.view(atColumn: 0, row: b, makeIfNecessary: false)
        try photos(["Year/A/4.JPG"], from: 20)
        try await eventually(seconds: 30) { rows(list.folders)["Year"]?.count == 4 }
        #expect(rows(list.folders)["Year"]?.count == 4 && rows(list.folders)["A"]?.count == 3)
        #expect(list.folders.view(atColumn: 0, row: b, makeIfNecessary: false) === neighbour, "B's row wasn't remade")

        // A change in the root's own folder, as the disk's events report it, finds the root where it was.
        library.changed([root.path])
        try await Task.sleep(for: .milliseconds(300))
        #expect(
            list.folders.view(atColumn: 0, row: b, makeIfNecessary: false) === neighbour,
            "the roots weren't shown again",
        )

        library.setIncludesSubfolders(false)
        try await eventually { rows(list.folders)["Year"]?.count == 0 }
        #expect(rows(list.folders)["Year"]?.isSelectable == false)
        #expect(rows(list.folders)["A"]?.count == 3)
    }

    @Test func `photos that can't be read aren't counted, as their folder's list leaves them out`() async throws {
        defer { cleanUp() }
        try photos(["Year/B/C/1.JPG", "Year/B/C/locked.JPG"])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: photo("Year/B/C/locked.JPG").path,
        )
        let (library, _) = try await indexedLibrary()
        try await eventually(seconds: 10) { library.photoCount(of: folder("Year")) == 1 }
        #expect(library.photoCount(of: folder("Year")) == 1)
        library.open(folder("Year"))
        try await eventually(seconds: 10) { library.isShownFromLibrary && !library.isListing }
        #expect(library.items.map(\.name) == ["1.JPG"])
    }

    @Test func `a folder holding only folders shows every photo beneath it, from the library or the disk`(
    ) async throws {
        defer { cleanUp() }
        try photos(["Year/March/1.JPG", "Year/March/2.JPG", "Year/April/3.JPG", "Year/April/Picks/4.JPG"])
        let listed = FolderLibrary()
        listed.add([root])
        listed.open(folder("Year"))
        try await eventually { !listed.isListing && listed.count == 4 }
        #expect(listed.items.map(\.name) == ["3.JPG", "4.JPG", "1.JPG", "2.JPG"])

        let (library, _) = try await indexedLibrary()
        library.open(folder("Year"))
        try await eventually(seconds: 10) { library.isShownFromLibrary && !library.isListing }
        #expect(library.isShownFromLibrary)
        #expect(library.items.map(\.url) == listed.items.map(\.url))
    }
}
