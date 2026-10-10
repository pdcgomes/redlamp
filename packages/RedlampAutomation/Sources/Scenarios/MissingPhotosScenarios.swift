#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import Foundation
    import RedlampLibrary
    @_spi(Harness) import RedlampUI

    /// Library Health's Missing check (DEC-59), on photos of the run's own in the external disk's scratch folder: a
    /// photo
    /// deleted outside Redlamp leaves its folder's list for Missing Photos, chosen in the Library panel; Remove from
    /// Library from its menu, taken back by ⌘Z; and Locate… from the Photo menu relinking a photo to a copy with its
    /// content, and the other found beside it, taken back by ⌘Z.
    enum MissingPhotosScenarios {
        static let all: [Scenario] = [missing]

        static let missing = Scenario(
            "library.missing-photos",
            "A photo deleted outside Redlamp leaves its folder for Library Health's Missing Photos; Remove from Library "
                + "from its menu takes it out and ⌘Z puts it back; Locate… from the Photo menu relinks two photos to "
                + "copies with their content, and ⌘Z takes it back",
            claims: [.action(.locateMissingPhoto), .action(.removeMissingPhotos)],
        ) { app in
            let scratch = try SourcesScratch(app, photos: ["A.jpg", "B.jpg", "C.jpg", "D.jpg"])
            let folders = app.photos
            defer {
                try? app.main { _ in EditorModel.answerLocate(with: nil) }
                scratch.remove(app)
                try? app.main { model in
                    model.showFolder(folders)
                    model.showModule(.develop)
                }
            }
            try scratch.index(app)
            let root = scratch.folder.standardizedFileURL.path + "/"
            @MainActor func shown() -> [String] {
                app.model.items.filter { $0.url.standardizedFileURL.path.hasPrefix(root) }.map(\.name).sorted()
            }
            try app.wait("the folder's photos", timeout: 30) { _ in shown() == ["A.jpg", "B.jpg", "C.jpg", "D.jpg"] }

            // Deleted outside Redlamp: the folder's list leaves it, and Missing Photos lists it.
            app.step("a photo deleted outside Redlamp")
            try FileManager.default.removeItem(at: scratch.photo("B.jpg"))
            try app.wait("the folder without it", timeout: 60) { _ in shown() == ["A.jpg", "C.jpg", "D.jpg"] }
            let row = "sources.health." + HealthCheck.Kind.missing.rawValue
            try app.wait("Missing Photos in the Library panel", timeout: 60) { _ in app.sourceRowLabel(row) != nil }
            try app.clickSourceRow(row)
            try app.waitForSource("the photo under Missing Photos", timeout: 30) { model in
                model.librarySources.shown == .health(.missing) && shown() == ["B.jpg"]
            }

            // Remove from Library from its menu takes it out; ⌘Z puts it back, missing.
            app.step("Remove from Library from the photo's menu")
            try app.click(.identifier("grid.B.jpg"))
            try app.wait("B selected, its finding read", timeout: 20) { $0.canPerform(.removeMissingPhotos) }
            try app.rightClick(.identifier("grid.B.jpg"), choosing: ShortcutAction.removeMissingPhotos.title)
            try app.wait("Missing Photos empty", timeout: 30) { _ in shown().isEmpty }
            app.covered(.action(.removeMissingPhotos), via: .mouse)
            try app
                .wait("the removal on Library's Undo", timeout: 10) { $0.healthUndoCount > 0 && $0.canPerform(.undo) }
            try app.press(.undo)
            try app.wait("the photo missing again", timeout: 30) { _ in shown() == ["B.jpg"] }

            // Copies of C and D in a folder of the library, the originals deleted: Locate… from the Photo menu relinks
            // C to
            // its copy, and D found beside it; ⌘Z makes them missing again.
            app.step("Locate… from the Photo menu")
            let found = scratch.folder.appending(path: "Found", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: found, withIntermediateDirectories: true)
            for name in ["C.jpg", "D.jpg"] {
                try FileManager.default.copyItem(at: scratch.photo(name), to: found.appending(path: name))
                try FileManager.default.removeItem(at: scratch.photo(name))
            }
            try app.wait("C and D under Missing Photos", timeout: 60) { _ in shown() == ["B.jpg", "C.jpg", "D.jpg"] }
            try app.main { model in
                model.select(scratch.photo("C.jpg"))
                EditorModel.answerLocate(with: found.appending(path: "C.jpg"), relinkingOthers: true)
            }
            try app.wait("Locate… offered for C", timeout: 20) { $0.canPerform(.locateMissingPhoto) }
            try app.choose(.locateMissingPhoto)
            try app.wait("C and D relinked, B still missing", timeout: 30) { _ in shown() == ["B.jpg"] }
            app.covered(.action(.locateMissingPhoto), via: .menu)
            try app.wait("the relink on Library's Undo", timeout: 10) { $0.healthUndoCount > 0 && $0.canPerform(.undo) }
            try app.press(.undo)
            try app.wait("C and D missing again", timeout: 30) { _ in shown() == ["B.jpg", "C.jpg", "D.jpg"] }
        }
    }
#endif
