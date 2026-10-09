#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import RedlampDesign
    import RedlampDocument
    import RedlampEngineAPI
    import RedlampLibrary
    @_spi(Harness) import RedlampUI
    import Synchronization

    /// Move Edits and Metadata… (LIB-11), on scratch folders of the run's own that the scenarios add to Folders and
    /// take out again: a root's menu in Folders moves its photos' sidecars to Redlamp on this Mac, the Library menu
    /// moves them back, and a move into a folder Redlamp can't write in is refused with the reason.
    enum MoveEditsScenarios {
        static let all: [Scenario] = [moveEdits, performance]

        static let moveEdits = Scenario(
            "library.move-edits",
            "A root's menu in Folders moves its photos' edits and metadata to Redlamp on this Mac, every byte kept and "
                + "the grid's badges with them; the Library menu refuses to move them back while the folder can't be "
                + "written in, saying why, then moves them back",
            claims: [.action(.moveEditsAndMetadata), .feature("library.sidecars")],
        ) { app in
            let scratch = try SourcesScratch(app, photos: ["Kept A.jpg", "Kept B.jpg", "Kept C.jpg"])
            let folder = scratch.folder
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
                scratch.remove(app)
            }
            let edited = ["Kept A.jpg": PhotoMetadata(rating: 4), "Kept C.jpg": PhotoMetadata(rating: 2, flag: .pick)]
            for (name, metadata) in edited {
                try SidecarStore().save(Sidecar(recipe: EditRecipe(), metadata: metadata), for: scratch.photo(name))
            }
            let names = edited.keys.sorted()
            let before = names.map { SidecarFiles.read(SidecarLocator.besidePhoto(scratch.photo($0))) }
            try app.expect(before.allSatisfy { $0 != nil }, "the photos' sidecars beside them")
            try scratch.index(app)

            // The root's menu: the sheet says where they're kept, where they'd go and how many photos have them.
            let row = "folders." + folder.standardizedFileURL.path
            try app.main { model in model.expandedSidebarSections.insert(.folders) }
            try app.wait("the folder's row in the Folders panel") { _ in
                Views.editorWindow.flatMap { Views.find(row, in: $0) } != nil
            }
            try app.rightClickRow(row, choosing: ShortcutAction.moveEditsAndMetadata.title)
            try app.waitForSheet("Move Edits and Metadata")
            try app.wait("the sheet's numbers") { model in
                model.moveEditsSheet?.count == "2 photos have edits or metadata beside the photos."
            }
            let sheet = try app.main { $0.moveEditsSheet }
            try app.expect(
                sheet?.kept == "Beside the photos, in a .redlamp file next to each one"
                    && sheet?.goingTo == "Redlamp on this Mac",
                "the sheet says \(String(describing: sheet))",
            )
            try app.wait("the folder looked through", timeout: 30) { $0.moveEditsSheet?.canMove == true }
            try app.clickInSheet("moveEdits.move")
            try app.waitForNoSheet("Move Edits and Metadata", timeout: 60)
            let onThisMac = try app.main { model in
                names.map { model.library.sidecars.locator.onThisMac(scratch.photo($0)) }
            }
            try app.expect(onThisMac.allSatisfy { $0 != nil }, "the root is kept on this Mac")
            try app.expect(onThisMac.map { $0.flatMap(SidecarFiles.read) } == before, "every byte moved")
            try app.expect(
                names.allSatisfy { !FileManager.default.fileExists(atPath: scratch.photo($0).path + ".redlamp") },
                "nothing left beside the photos",
            )
            try app.wait("the grid's badges as they were", timeout: 30) { model in
                model.items.first { $0.name == "Kept A.jpg" }?.metadata.rating == 4
                    && model.items.first { $0.name == "Kept C.jpg" }?.metadata.flag == .pick
            }
            app.covered([.action(.moveEditsAndMetadata), .feature("library.sidecars")], via: .mouse)

            // While Redlamp can't write in the folder, the Library menu's sheet says so and won't move them back.
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
            try app.choose(.moveEditsAndMetadata)
            try app.waitForSheet("Move Edits and Metadata")
            let refusal = "Redlamp doesn't have permission to write in “\(folder.lastPathComponent)”, so its edits and "
                + "metadata stay in Redlamp on this Mac."
            try app.wait("the refusal", timeout: 30) { model in
                model.moveEditsSheet?.status == refusal && model.moveEditsSheet?.canMove == false
            }
            try app.pressInSheet(KeyCombo(.escape))
            try app.waitForNoSheet("Move Edits and Metadata")
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)

            // Once it can, the Library menu moves them back beside the photos.
            try app.choose(.moveEditsAndMetadata)
            try app.waitForSheet("Move Edits and Metadata")
            try app.wait("the sheet going beside the photos", timeout: 30) { model in
                model.moveEditsSheet?.goingTo == "Beside the photos" && model.moveEditsSheet?.canMove == true
            }
            try app.clickInSheet("moveEdits.move")
            try app.waitForNoSheet("Move Edits and Metadata", timeout: 60)
            let back = names.map { SidecarFiles.read(SidecarLocator.besidePhoto(scratch.photo($0))) }
            try app.expect(back == before, "every byte back beside the photos")
            let left = try app.main { model in
                names.compactMap { model.library.sidecars.locator.onThisMac(scratch.photo($0)) }
                    .filter { FileManager.default.fileExists(atPath: $0.path) }
            }
            try app.expect(left.isEmpty, "nothing left on this Mac: \(left.map(\.path))")
            app.covered(.action(.moveEditsAndMetadata), via: .menu)

            // As the run had it.
            let photos = app.photos
            try app.main { model in
                model.showFolder(photos)
                model.showModule(.develop)
            }
            try app.wait("the photos folder again", timeout: 20) { $0.folder == photos && !$0.library.isListing }
        }

        /// 10,000 photos, each with a sidecar, in twenty folders of a root of their own: Move Edits and Metadata… from
        /// the root's menu, the time until the sheet is on screen with its numbers and until the disk is looked
        /// through, the move to Redlamp on this Mac and back, and the main thread throughout.
        static let performance = Scenario(
            "performance.move-edits",
            "Move Edits and Metadata… on a root of 10,000 photos with sidecars: the sheet's numbers, the move to "
                + "Redlamp on this Mac and back, and the main thread meanwhile",
            tiers: [.performance], claims: [],
        ) { app in
            var started = Date()
            let scratch = try MoveEditsPerformanceScratch(app)
            let included = try app.main { $0.library.includesSubfolders }
            defer { scratch.remove(app, includingSubfolders: included) }
            app.record("e2e-move-edits-copies-seconds", Date().timeIntervalSince(started))
            started = Date()
            _ = try scratch.show(app)
            app.record("e2e-move-edits-indexed-seconds", Date().timeIntervalSince(started))
            let row = "folders." + scratch.root.standardizedFileURL.path
            try app.main { model in model.expandedSidebarSections.insert(.folders) }
            try app.wait("the root's row in the Folders panel") { _ in
                Views.editorWindow.flatMap { Views.find(row, in: $0) } != nil
            }

            var phases: [(String, (summary: MainThreadMonitor.Summary?, seconds: Double))] = []
            var shown: [Double] = []
            var checked: [Double] = []
            for (name, goingTo) in [("there", "Redlamp on this Mac"), ("back", "Beside the photos")] {
                try app.rightClickRow(row, choosing: ShortcutAction.moveEditsAndMetadata.title)
                try app.waitForSheet("Move Edits and Metadata", timeout: 10)
                try app.wait("the sheet's numbers") { $0.moveEditsSheet?.shownAfter != nil }
                let opened = Date()
                let sheet = try app.main { $0.moveEditsSheet }
                let after = sheet?.shownAfter?.components ?? (seconds: 0, attoseconds: 0)
                shown.append(Double(after.seconds) * 1000 + Double(after.attoseconds) / 1e15)
                try app.expect(
                    sheet?.count.hasPrefix("10,000 photos have edits or metadata") == true && sheet?.goingTo == goingTo,
                    "the sheet says \(String(describing: sheet))",
                )
                try app.wait("the root looked through", timeout: 120) { $0.moveEditsSheet?.canMove == true }
                checked.append(Date().timeIntervalSince(opened) * 1000)
                let phase = try app.watchingMainThread(name) {
                    try app.clickInSheet("moveEdits.move")
                    try app.waitForNoSheet("Move Edits and Metadata", timeout: 900)
                }
                phases.append((name, phase))
            }
            let placed = scratch.sidecarsBeside()
            try app.expect(placed == MoveEditsPerformanceScratch.photos, "\(placed) sidecars back beside the photos")

            for (name, phase) in phases {
                app.record("e2e-move-edits-\(name)-seconds", phase.seconds)
                if let summary = phase.summary {
                    app.record("e2e-move-edits-\(name)-p99", summary.p99)
                    app.record("e2e-move-edits-\(name)-max", summary.max)
                }
            }
            app.record("e2e-move-edits-sheet-shown-ms", shown.max() ?? -1)
            app.record("e2e-move-edits-sheet-checked-ms", checked.max() ?? -1)
            let lines = phases.map { name, phase in
                String(
                    format: "%@: %.2f s, main thread p50 %.2f ms, p99 %.2f ms, max %.1f ms, over a frame %d", name,
                    phase.seconds, phase.summary?.p50 ?? -1, phase.summary?.p99 ?? -1, phase.summary?.max ?? -1,
                    phase.summary?.overFrame ?? -1,
                )
            } + [
                String(
                    format: "sheet on screen with its numbers: %@ ms; root looked through: %@ ms; load %@",
                    shown.map { String(format: "%.1f", $0) }.joined(separator: " and "),
                    checked.map { String(format: "%.0f", $0) }.joined(separator: " and "),
                    "\(ProcessInfo.processInfo.loadAverage)",
                ),
            ]
            try? (lines.joined(separator: "\n") + "\n").write(
                to: app.runDirectory.appending(path: "move-edits-performance.txt"), atomically: true, encoding: .utf8,
            )
            app.recorder.write("note", ["move-edits": lines.joined(separator: "; ")])
            for (name, phase) in phases {
                try app.expect(
                    (phase.summary?.p99 ?? 0) < 8.3,
                    "moving \(name): main thread p99 \(phase.summary?.p99 ?? 0) ms",
                )
            }
            try app.expect((shown.max() ?? .infinity) < 16.7, "the sheet's numbers took \(shown) ms")
        }
    }

    /// A sidecar's files by their path inside it, with their bytes; a single-file sidecar's under "".
    enum SidecarFiles {
        static func read(_ sidecar: URL) -> [String: Data]? {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: sidecar.path, isDirectory: &isDirectory) else { return nil }
            guard isDirectory.boolValue else { return (try? Data(contentsOf: sidecar)).map { ["": $0] } }
            var files: [String: Data] = [:]
            for path in FileManager.default.subpaths(atPath: sidecar.path) ?? [] {
                files[path] = try? Data(contentsOf: sidecar.appending(path: path))
            }
            return files
        }
    }

    /// A root of 10,000 copies of a JPEG in twenty folders, each copy a clone ending in bytes of its own so each has
    /// its own content key, each with a sidecar holding a rating and an edit: in a folder of its own where
    /// `REDLAMP_PERF_SCRATCH` says, `/Volumes/SSD/redlamp-tmp` by default, removed after.
    struct MoveEditsPerformanceScratch: Sendable {
        static let photos = 10000
        static let folders = 20

        let base: URL
        let root: URL

        init(_ app: RunningApp) throws {
            let scratch = ProcessInfo.processInfo.environment["REDLAMP_PERF_SCRATCH"]
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? URL(fileURLWithPath: "/Volumes/SSD/redlamp-tmp", isDirectory: true)
            base = scratch.appending(path: "move-edits-performance-\(UUID().uuidString)", directoryHint: .isDirectory)
            root = base.appending(path: "Shoot", directoryHint: .isDirectory)
            let source = base.appending(path: "Bitmap.jpg")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: app.photos.appending(path: "Bitmap.jpg"), to: source)
            let (root, perFolder) = (root, Self.photos / Self.folders)
            let failure = Failures()
            DispatchQueue.concurrentPerform(iterations: Self.folders) { number in
                do {
                    let folder = root.appending(
                        path: String(format: "Day %02d", number + 1),
                        directoryHint: .isDirectory,
                    )
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    for index in 0 ..< perFolder {
                        let serial = number * perFolder + index
                        let photo = folder.appending(path: String(format: "IMG_%05d.JPG", serial + 1))
                        try FileManager.default.copyItem(at: source, to: photo)
                        let handle = try FileHandle(forWritingTo: photo)
                        try handle.seekToEnd()
                        try handle.write(contentsOf: Data(count: 16 + serial))
                        try handle.close()
                        var recipe = EditRecipe()
                        recipe[.exposure] = Double(serial % 9) / 10
                        try SidecarStore().save(
                            Sidecar(recipe: recipe, metadata: PhotoMetadata(rating: serial % 5 + 1)), for: photo,
                        )
                    }
                } catch {
                    failure.note(error)
                }
            }
            if let error = failure.first {
                throw error
            }
        }

        /// Adds the root to Folders and shows its photos, its folders' included, in Library's grid, from the library.
        /// Returns whether Show Photos in Subfolders was on before, which `remove` puts back.
        func show(_ app: RunningApp) throws -> Bool {
            let root = root
            if try app.main({ $0.module != .develop }) {
                try app.press(.developModule)
            }
            let included = try app.main { model in
                let included = model.library.includesSubfolders
                model.open([root])
                if !included {
                    model.setIncludesSubfolders(true)
                }
                return included
            }
            try app.wait("10,000 photos indexed and shown from the library", timeout: 1800) { model in
                model.folder?.standardizedFileURL == root.standardizedFileURL && model.library.isShownFromLibrary
                    && model.items.count == Self.photos
            }
            try app.settle(timeout: 120)
            try app.press(.gridView)
            return included
        }

        /// How many of the photos have their sidecar beside them.
        func sidecarsBeside() -> Int {
            (FileManager.default.subpaths(atPath: root.path) ?? []).count { $0.hasSuffix(".JPG.redlamp") }
        }

        /// Takes the root out of Folders and away, puts Show Photos in Subfolders back as `included`, and opens the
        /// run's working photo again.
        func remove(_ app: RunningApp, includingSubfolders included: Bool) {
            let root = root
            try? app.main { model in
                if let added = model.library.root(containing: root) {
                    model.library.remove(added)
                }
                if model.library.includesSubfolders != included {
                    model.setIncludesSubfolders(included)
                }
            }
            try? FileManager.default.removeItem(at: base)
            try? app.openWorking()
        }
    }

    /// The first error from threads making copies.
    private final class Failures: Sendable {
        private let errors = Mutex<[any Error]>([])

        func note(_ error: any Error) {
            errors.withLock { $0.append(error) }
        }

        var first: (any Error)? {
            errors.withLock { $0.first }
        }
    }
#endif
