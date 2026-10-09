#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import Foundation
    import RedlampLibrary
    @_spi(Harness) import RedlampUI

    /// Library Health in the app (LIB-40): each check's proposals drawn in the grid, a check's batch confirmed in its
    /// sheet and taken back by ⌘Z, and Keep Anyway and List Again, through the grid's menu, the Library and Photo
    /// menus, the palette and the sheet.
    enum HealthScenarios {
        static let all: [Scenario] = [health]

        /// Three copies of one JPEG, a raw and its JPEG, an empty file and a HEIC named .jpg, copies made in the
        /// external disk's scratch folder: the duplicates confirmed in the background; each check's marks in the grid;
        /// Keep Anyway from a copy's menu, taken back by ⌘Z and made again by ⇧⌘Z; List Again from Kept Anyway's list;
        /// a copy rated, left out of the batch; the duplicates' batch from the Library menu, its sheet's words read,
        /// accepted, and taken back by ⌘Z; the pairs' batch from the palette, cancelled; and Keep Anyway from the Photo
        /// menu. What goes to the Trash is put back, and anything left there is removed.
        static let health = Scenario(
            "library.health",
            "Library Health's proposals in the grid; Keep Anyway from a photo's menu with ⌘Z and ⇧⌘Z, and from the "
                + "Photo menu; List Again from Kept Anyway's; a batch confirmed in its sheet from the Library menu and "
                + "taken back by ⌘Z, and one from the palette cancelled",
            claims: [
                .action(.acceptHealthProposals), .action(.keepAnyway), .action(.listAgain), .feature("library.health"),
            ],
        ) { app in
            let scratch = try SourcesScratch(app, photos: [], empty: ["Empty.jpg"])
            let service = try app.main { $0.library.service }
            guard let service else { throw ScenarioSkip("the library is off") }
            let folders = app.photos
            defer {
                try? app.run("emptying what's left in the Trash", timeout: 30) { model in
                    model.librarySources.setPairRule(.keepBoth)
                    for place in await service.trashedPlaces() {
                        try? FileManager.default.removeItem(atPath: place)
                    }
                }
                scratch.remove(app)
                try? app.main { model in
                    model.showFolder(folders)
                    model.showModule(.develop)
                }
            }
            let copy = try SourcesScratch.jpeg(number: 3)
            let copies = ["Copy 1.jpg", "Copy 2.jpg", "Copy 3.jpg"]
            for name in copies {
                try copy.write(to: scratch.photo(name))
            }
            // Each its own, so none is a copy of the run's photos, which a batch would then act on.
            let names = try FileManager.default.contentsOfDirectory(atPath: folders.path).sorted()
            let raw = ["NEF", "ARW", "DNG"].lazy.compactMap { kind in
                names.first { ($0 as NSString).pathExtension.uppercased() == kind }
            }.first
            guard let raw else { throw ScenarioSkip("the run's photos have no TIFF-based raw") }
            let pair = "Pair." + (raw as NSString).pathExtension
            try (Data(contentsOf: folders.appending(path: raw)) + Self.freeBox).write(to: scratch.photo(pair))
            try Self.commented(Data(contentsOf: folders.appending(path: "Bitmap.jpg")), "Redlamp health pair")
                .write(to: scratch.photo("Pair.jpg"))
            try (Data(contentsOf: folders.appending(path: "Bitmap.heic")) + Self.freeBox)
                .write(to: scratch.photo("Wrong.jpg"))
            try scratch.index(app)
            let root = scratch.folder.standardizedFileURL.path + "/"
            @MainActor func shown() -> [String] {
                app.model.items.filter { $0.url.standardizedFileURL.path.hasPrefix(root) }.map(\.name).sorted()
            }
            @MainActor func marks() -> [String: String] {
                guard let window = Views.editorWindow, let grid = LibraryGridViews.grid(in: window) else { return [:] }
                return LibraryGridViews.proposals(in: grid)
            }
            func show(_ source: LibrarySource, _ names: [String], _ what: String) throws {
                let row = switch source {
                case let .health(kind): "sources.health." + kind.rawValue
                default: "sources.kept-anyway"
                }
                try app.wait("\(what)'s row", timeout: 60) { _ in app.sourceRowLabel(row) != nil }
                try app.clickSourceRow(row)
                try app.waitForSource(what, timeout: 30) { model in
                    model.librarySources.shown == source && Set(names).isSubset(of: Set(shown()))
                }
            }

            // The copies are read whole in the background, and Exact Duplicates shows them, each copy's proposal drawn:
            // one kept, the others to the Trash, framed.
            app.step("Exact Duplicates")
            try show(.health(.duplicates), copies, "the three copies under Exact Duplicates")
            try app.wait("each copy's proposal in the grid", timeout: 20) { _ in
                let shown = marks()
                return copies.allSatisfy { shown[$0] != nil }
            }
            let drawn = try app.main { _ in marks() }
            let keeper = copies.first { drawn[$0] == "Keep" }
            let thrown = copies.filter { drawn[$0] == "To Trash (framed)" }
            try app.expect(keeper != nil && thrown.count == 2, "the copies' proposals drawn: \(drawn)")
            app.covered(.feature("library.health"), via: .mouse)

            // Keep Anyway from a copy's menu: the group leaves the check. ⌘Z lists it again, ⇧⌘Z keeps it again.
            app.step("Keep Anyway from a copy's menu")
            try app.rightClick(.identifier("grid.\(thrown[0])"), choosing: ShortcutAction.keepAnyway.title)
            try app.wait("the copies out of Exact Duplicates", timeout: 20) { _ in shown().isEmpty }
            app.covered(.action(.keepAnyway), via: .mouse)
            try app.wait("Keep Anyway on Library's Undo", timeout: 10) { $0.healthUndoCount > 0 }
            try app.press(.undo)
            try app.waitForSource("the copies listed again", timeout: 20) { _ in shown() == copies }
            try app.choose(.redo)
            try app.wait("the copies kept anyway again", timeout: 20) { _ in shown().isEmpty }

            // List Again from Kept Anyway's list.
            app.step("List Again from Kept Anyway")
            try show(.keptAnyway, copies, "the copies under Kept Anyway")
            try app.rightClick(.identifier("grid.\(copies[0])"), choosing: ShortcutAction.listAgain.title)
            try app.wait("the copies out of Kept Anyway", timeout: 20) { _ in shown().isEmpty }
            app.covered(.action(.listAgain), via: .mouse)

            // Two copies rated: the review keeps one of them, and the other is left out of the batch unless it's chosen
            // in the sheet; the copy kept before goes.
            app.step("two copies rated, one left out")
            try show(.health(.duplicates), copies, "the copies under Exact Duplicates again")
            try app.main { model in
                model.select(scratch.photo(thrown[0]))
                model.click(scratch.photo(thrown[1]), toggling: true)
            }
            try app.press(.rating2)
            let unrated = keeper ?? copies[0]
            try app.wait("a rated copy kept, the other left out, the unrated one to the Trash", timeout: 20) { _ in
                let shown = marks()
                return Set([shown[thrown[0]], shown[thrown[1]]]) == ["Keep", "Left Out"]
                    && shown[unrated] == "To Trash (framed)"
            }

            // The Library menu's Accept Health Proposals…: the sheet says what happens, and Move to Trash moves the
            // copy
            // proposed, the rated ones staying.
            app.step("the duplicates' batch from the Library menu")
            try app.choose(.acceptHealthProposals)
            try app.wait("the sheet with its plan", timeout: 30) { $0.healthSheet?.canAccept == true }
            let sheet = try app.main { $0.healthSheet }
            try app.expect(
                sheet?.heading == "Move 1 copy to the Trash?",
                "the sheet asks \(sheet?.heading ?? "nothing")",
            )
            try app.expect(sheet?.choice != nil, "the sheet offers the selected copy left out")
            try app.expect(sheet?.leftOut.hasPrefix("1 stays where it is") == true, "left out: \(sheet?.leftOut ?? "")")
            app.recorder.write("note", [
                "health-sheet": [sheet?.heading, sheet?.count, sheet?.what, sheet?.undo, sheet?.leftOut, sheet?.choice]
                    .compactMap(\.self).joined(separator: " | "),
            ])
            try app.clickInSheet("health.accept")
            try app.waitForNoSheet("the sheet", timeout: 30)
            try app.wait("the copy proposed in the Trash, the rated ones still here", timeout: 30) { _ in
                !FileManager.default.fileExists(atPath: scratch.photo(unrated).path)
                    && thrown.allSatisfy { FileManager.default.fileExists(atPath: scratch.photo($0).path) }
            }

            // ⌘Z brings it back.
            try app.wait("the batch on Library's Undo", timeout: 10) { $0.healthUndoCount > 0 && $0.canPerform(.undo) }
            try app.press(.undo)
            try app.wait("the copy back where it was", timeout: 30) { _ in
                FileManager.default.fileExists(atPath: scratch.photo(unrated).path)
            }

            // The pairs under Keep the Raw: the JPEG to the Trash, framed. The palette's Accept Health Proposals… asks,
            // and Cancel leaves it.
            app.step("the pairs' batch from the palette, cancelled")
            try app.main { $0.librarySources.setPairRule(.keepRaw) }
            try show(.health(.pairs), ["Pair.jpg"], "the JPEG under Raw and JPEG Pairs")
            try app
                .wait("the JPEG's proposal in the grid", timeout: 20) { _ in
                    marks()["Pair.jpg"] == "To Trash (framed)"
                }
            try app.runFromPalette(.acceptHealthProposals)
            try app.wait("the pairs' sheet with its plan", timeout: 30) { $0.healthSheet?.canAccept == true }
            let pairs = try app.main { $0.healthSheet?.heading }
            try app.expect(pairs == "Move 1 JPEG to the Trash?", "the pairs' sheet asks \(pairs ?? "nothing")")
            try app.pressInSheet(KeyCombo(.escape))
            try app.waitForNoSheet("the pairs' sheet")
            try app.expect(
                FileManager.default.fileExists(atPath: scratch.photo("Pair.jpg").path), "Cancel moved the JPEG",
            )

            // Damaged Files: the empty file, framed for the Trash; Keep Anyway from the Photo menu, then ⌘Z.
            app.step("Keep Anyway from the Photo menu")
            try show(.health(.damaged), ["Empty.jpg"], "the empty file under Damaged Files")
            try app
                .wait("the empty file's proposal in the grid", timeout: 20) { _ in
                    marks()["Empty.jpg"] == "Empty (framed)"
                }
            try app.main { $0.select(scratch.photo("Empty.jpg")) }
            try app.choose(.keepAnyway)
            try app.wait("the empty file kept anyway", timeout: 20) { _ in !shown().contains("Empty.jpg") }
            try app.press(.undo)
            try app.wait("the empty file listed again", timeout: 20) { _ in shown().contains("Empty.jpg") }

            // Wrong Extensions: the HEIC named .jpg, framed for its rename.
            try show(.health(.extensions), ["Wrong.jpg"], "the HEIC under Wrong Extensions")
            try app
                .wait("the HEIC's proposal in the grid", timeout: 20) { _ in
                    marks()["Wrong.jpg"] == "→ .heic (framed)"
                }
        }

        /// An empty `free` box, which ISO base media files and TIFF-based raws read past: a file it ends is one of its
        /// own.
        static let freeBox = Data([0, 0, 0, 16]) + Data("free".utf8) + Data(count: 8)

        /// `jpeg` with a comment holding `text` after its start of image: a file of its own that reads the same.
        static func commented(_ jpeg: Data, _ text: String) -> Data {
            let comment = Data(text.utf8)
            let length = comment.count + 2
            return jpeg.prefix(2) + Data([0xFF, 0xFE, UInt8(length >> 8), UInt8(length & 0xFF)]) + comment
                + jpeg.dropFirst(2)
        }
    }
#endif
