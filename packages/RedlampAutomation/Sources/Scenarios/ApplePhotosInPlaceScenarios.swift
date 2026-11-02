#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import RedlampDocument
    import RedlampEngineAPI
    @_spi(Harness) import RedlampLibrary
    @_spi(Harness) import RedlampUI

    /// Albums kept in place from Apple Photos (LIB-62), on the simulated Photos library `ApplePhotosScratch` makes:
    /// an album kept through Add Albums from Apple Photos… and worked in the Apple Photos section as a folder's photos
    /// are; originals downloaded from iCloud as Download Originals, Develop and export need them (LIB-60); and Photos'
    /// changes followed while Redlamp is open (LIB-61), favourites as picks among them (LIB-65).
    enum ApplePhotosInPlaceScenarios {
        static let all: [Scenario] = [inPlace, download, changes, export]

        static let inPlace = Scenario(
            "library.apple-photos-in-place",
            "Add Albums from Apple Photos… keeps an album in place, its photos shown from Photos' thumbnails with the "
                + "one only in iCloud left there; they're culled and keyworded as a folder's photos are, and "
                + "source:photos in All Photographs finds them; Show in Photos opens Photos; ⌫ and the photo's "
                + "Remove from Library… take a photo out of the lists, and ⌘Z brings it back with its culling; the "
                + "album's Remove from Library… stops keeping it",
            claims: [
                .action(.importFromApplePhotos), .action(.showInFinder), .action(.moveToTrash),
                .feature("library.ratings"), .feature("library.keywords"), .feature("library.filter"),
            ],
        ) { app in
            try app.openWorking()
            let photos = try ApplePhotosScratch(app)
            defer {
                try? app.main { _ in
                    if let opener = Self.opener {
                        ApplePhotosActions.openPhotos = opener
                    }
                    Self.opener = nil
                }
                photos.stopKeeping(app, "album-selects")
                photos.remove(app)
            }
            try photos.simulate(app, [0: ["album-selects"], 1: ["album-selects"], 2: ["album-selects"]])
            try app.main { model in
                Self.opener = ApplePhotosActions.openPhotos
                Self.openings = 0
                ApplePhotosActions.openPhotos = { Self.openings += 1 }
                model.showLibrary(.grid)
            }
            let urls = try photos.keep(app, "album-selects", listing: [0, 1, 2])
            let names = photos.scratch.names

            // Shown from Photos' thumbnails, the third's too, its original left in iCloud.
            try app.wait("the album's thumbnails from Photos", timeout: 30) { model in
                model.items.count == 3 && model.items.allSatisfy { model.thumbnailLoader.hasThumbnail($0) }
            }
            try app.expect(try app.main { $0.library.needsDownload(urls[2]) }, "\(names[2]) downloaded to be shown")

            // Culled and keyworded as a folder's photos are, its sidecar in Redlamp's store on this Mac.
            try app.click(.identifier("grid.\(names[1])"))
            try app.wait("\(names[1]) alone") { $0.selectedPhotos == [urls[1]] }
            try app.press(.flagPick)
            try app.press(.rating3)
            try app.wait("\(names[1]) a pick of 3 stars") { model in
                Self.culled(urls[1], in: model) == Culling(flag: .pick, rating: 3)
            }
            try app.waitWritten()
            try app.wait("its sidecar holding them", timeout: 15) { model in
                let metadata = model.library.sidecars.store(for: urls[1]).summary(for: urls[1])?.metadata
                return metadata?.flag == .pick && metadata?.rating == 3
            }
            app.covered(.feature("library.ratings"), via: .key)
            guard let keyword = KeywordPath("E2E Kept in Photos") else { throw ScenarioFailure("No keyword path") }
            try app.typeInField("keywording.entry", keyword.text)
            try app.wait("\(keyword.text) on \(names[1])") { model in
                model.libraryPanels.selection.hasEverywhere(keyword) == true
            }
            app.covered(.feature("library.keywords"), via: .key)
            // The entry keeps the keyboard for another keyword, and would type the \ below: a click in the grid takes
            // it, as the Library panel's rows don't.
            try app.click(.identifier("grid.\(names[1])"))
            try app.wait("the grid to take the keyboard") { _ in
                Views.editorWindow?.firstResponder.map { "\(Swift.type(of: $0))" } == "LibraryGridContentView"
            }

            // source:photos in All Photographs finds the album's photos, and source:folders leaves them out.
            try app.clickSourceRow("sources.all-photographs")
            try app.waitForSource("All Photographs", timeout: 60) { model in
                model.librarySources.shown == .allPhotographs && !model.librarySources.isListing
                    && Set(urls).isSubset(of: model.items.map(\.url))
            }
            if try !app.main({ $0.libraryFilters?.isBarShown ?? false }) {
                try app.press(.toggleFilterBar)
            }
            try app.wait("the filter bar's text to take the keyboard") { _ in
                (Views.editorWindow?.firstResponder as? NSTextView)?.delegate is NSTextField
            }
            try app.typeQuery("source:photos ")
            try app.waitForSource("source:photos, the album's photos alone", timeout: 30) { model in
                Set(model.items.map(\.url)) == Set(urls)
            }
            try app.main { _ in Views.editorWindow.map { LibraryFilterBars.clear(in: $0) } }
            try app.typeQuery("source:folders ")
            try app.waitForSource("source:folders, the folders' photos without them", timeout: 30) { model in
                !model.items.isEmpty && model.items.allSatisfy { !urls.contains($0.url) }
            }
            app.covered(.feature("library.filter"), via: .key)
            try app.main { model in
                model.libraryFilters?.setFilter(LibraryFilter())
                model.libraryFilters?.setBarShown(false)
            }

            // Show in Photos, from ⌘R and from the photo's menu, opens Photos.
            try app.clickSourceRow("apple-photos.album-selects")
            try app.waitForSource("E2E Selects again", timeout: 30) { model in
                model.librarySources.shown == .applePhotos("album-selects") && !model.librarySources.isListing
                    && Set(model.items.map(\.url)) == Set(urls)
            }
            try app.click(.identifier("grid.\(names[0])"))
            try app.wait("\(names[0]) alone") { $0.selectedPhotos == [urls[0]] }
            try app.press(.showInFinder)
            try app.wait("Photos opened") { _ in Self.openings == 1 }
            try app.rightClick(.identifier("grid.\(names[0])"), choosing: "Show in Photos")
            try app.wait("Photos opened from the photo's menu") { _ in Self.openings == 2 }

            // ⌫ offers Remove from Library, which takes the photo out of the lists; ⌘Z brings it back as it was.
            try app.main { _ in ApplePhotosRemoval.answer = true }
            try app.click(.identifier("grid.\(names[1])"))
            try app.wait("\(names[1]) alone again") { $0.selectedPhotos == [urls[1]] }
            try app.press(KeyCombo(.delete))
            try app.waitForSource("\(names[1]) out of the album's list", timeout: 30) { model in
                Set(model.items.map(\.url)) == [urls[0], urls[2]]
            }
            app.covered(.action(.moveToTrash), via: .key)
            try app.wait("the removal on Library's Undo", timeout: 10) { $0.canPerform(.undo) }
            try app.press(.undo)
            try app.waitForSource("\(names[1]) back, a pick of 3 stars", timeout: 30) { model in
                Set(model.items.map(\.url)) == Set(urls)
                    && Self.culled(urls[1], in: model) == Culling(flag: .pick, rating: 3)
            }

            // So does the photo's Remove from Library….
            try app.rightClick(.identifier("grid.\(names[2])"), choosing: "Remove from Library…")
            try app.waitForSource("\(names[2]) out of the album's list", timeout: 30) { model in
                Set(model.items.map(\.url)) == [urls[0], urls[1]]
            }
            try app.wait("its removal on Library's Undo", timeout: 10) { $0.canPerform(.undo) }
            try app.press(.undo)
            try app.waitForSource("\(names[2]) back", timeout: 30) { Set($0.items.map(\.url)) == Set(urls) }

            // The album's Remove from Library… stops keeping it, and the section goes.
            try app.rightClickSourceRow("apple-photos.album-selects", choosing: "Remove from Library…")
            try app.wait("E2E Selects no longer kept", timeout: 30) { !$0.librarySources.keepsApplePhotos }
            try app.wait("the Apple Photos section gone") { _ in
                app.sourceRowLabel("apple-photos.album-selects") == nil
            }
        }

        static let download = Scenario(
            "library.apple-photos-download",
            "Download Originals in a photo's menu downloads its original from iCloud, the filmstrip counting it; "
                + "Develop on a photo only in iCloud shows the download over its preview, Cancel leaves it there with "
                + "Download Again, and Report a Bug says Apple Photos, in iCloud only, naming no album; offline, "
                + "Download Again says so with Try Again, which opens the photo once iCloud is back",
            claims: [.action(.downloadOriginals), .action(.developModule)],
        ) { app in
            try app.openWorking()
            let photos = try ApplePhotosScratch(app)
            defer {
                try? app.main { model in model.showLibrary(.grid) }
                photos.stopKeeping(app, "album-selects")
                photos.remove(app)
            }
            let library = try photos.simulate(
                app, [0: ["album-selects"], 1: ["album-selects"], 2: ["album-selects"]], inCloud: [1, 2],
            )
            library.network = SimulatedPhotosLibrary.Network(latency: .seconds(1))
            try app.main { model in model.showLibrary(.grid) }
            let urls = try photos.keep(app, "album-selects", listing: [0, 1, 2])
            let names = photos.scratch.names

            // Download Originals in the photo's menu: the filmstrip counts the download until it's on this Mac.
            try app.click(.identifier("grid.\(names[1])"))
            try app.wait("\(names[1]) alone") { $0.selectedPhotos == [urls[1]] }
            try app.rightClick(.identifier("grid.\(names[1])"), choosing: ShortcutAction.downloadOriginals.title)
            try app.wait("the filmstrip counting it", timeout: 10) { $0.downloads.statuses[urls[1]] != nil }
            try app.wait("\(names[1]) on this Mac", timeout: 30) { model in
                !model.library.needsDownload(urls[1]) && model.downloads.statuses.isEmpty
            }
            app.covered(.action(.downloadOriginals), via: .mouse)

            // Develop on the photo only in iCloud shows the download over its preview, with Cancel.
            library.network = SimulatedPhotosLibrary.Network(latency: .seconds(60))
            try app.click(.identifier("grid.\(names[2])"))
            try app.wait("\(names[2]) alone") { $0.selectedPhotos == [urls[2]] }
            try app.press(.developModule)
            try app.wait("Develop downloading \(names[2])", timeout: 30) { model in
                model.module == .develop && model.download?.url == urls[2] && model.download?.isDownloading == true
                    && model.info == nil
            }
            try app.expect(
                try app.main { $0.download?.text } == "Downloading from iCloud", "what Develop says of the download",
            )
            try app.click(.identifier("develop.download.cancel"))
            try app.wait("Cancel leaving it on its preview", timeout: 10) { model in
                model.download?.state == .cancelled && model.info == nil && model.downloads.statuses.isEmpty
            }
            try app.expect(
                try app.main { $0.download?.text } == "Not downloaded: this photo's original is only in iCloud",
                "what Develop says once it's cancelled",
            )

            // Report a Bug's This photo: Apple Photos, in iCloud only, and no album, identifier or name of Photos'.
            try app.run("Report a Bug's report on it", timeout: 30) { model in
                Self.reported = await FeedbackActions.makeSheet(model: model).previewBody
            }
            let body = try app.main { _ in Self.reported } ?? ""
            try app.expect(body.contains("| Disk | Apple Photos, in iCloud only |"), "This photo's Disk:\n\(body)")
            for named in ["E2E Selects", photos.asset(2), names[2]] {
                try app.expect(!body.contains(named), "The report names \(named):\n\(body)")
            }

            // Offline, Download Again says so with Try Again; once iCloud is back, Try Again opens the photo.
            library.network = SimulatedPhotosLibrary.Network(offline: true)
            try app.click(.identifier("develop.download.again"))
            try app.wait("offline, said with Try Again", timeout: 10) { $0.download?.state == .failed(.offline) }
            try app.expect(
                try app
                    .main { $0.download?.text } == "iCloud can't be reached: this photo's original isn't on this Mac",
                "what Develop says offline",
            )
            library.network = SimulatedPhotosLibrary.Network(latency: .milliseconds(300))
            try app.click(.identifier("develop.download.again"))
            try app.wait("\(names[2]) open in Develop", timeout: 30) { model in
                model.info?.url.standardizedFileURL.path == urls[2].standardizedFileURL.path && model.download == nil
            }
            try app.expect(try !app.main { $0.library.needsDownload(urls[2]) }, "\(names[2]) on this Mac")
            try app.press(.gridView)
            try app.wait("the grid again") { $0.module == .library }
        }

        static let changes = Scenario(
            "library.apple-photos-changes",
            "Photos' changes reach an album kept in place while Redlamp is open: its favourite is a pick, which U "
                + "clears and Photos changing the photo leaves clear, a photo Photos favourites becomes a pick, and ⌘Z "
                + "gives the first its pick back; a photo added to the album is listed, one deleted from Photos goes "
                + "to Library Health's Missing Photos, which removes it and offers no Locate…, and an album renamed "
                + "in Photos is renamed in the Apple Photos section",
            claims: [.feature("library.disk-changes"), .action(.unflag), .action(.removeMissingPhotos)],
        ) { app in
            try app.openWorking()
            let photos = try ApplePhotosScratch(app)
            defer {
                photos.stopKeeping(app, "album-selects")
                photos.remove(app)
            }
            let library = try photos.simulate(app, [0: ["album-selects"], 1: ["album-selects"], 2: []])
            try app.main { model in model.showLibrary(.grid) }
            let urls = try photos.keep(app, "album-selects", listing: [0, 1])
            let names = photos.scratch.names

            // The favourite is a pick; U clears it, and Photos changing the photo leaves it clear, while the photo
            // Photos favourites becomes a pick. ⌘Z gives the first its pick back.
            try app.wait("the favourite a pick", timeout: 30) { Self.culled(urls[0], in: $0).flag == .pick }
            try app.click(.identifier("grid.\(names[0])"))
            try app.wait("\(names[0]) alone") { $0.selectedPhotos == [urls[0]] }
            try app.press(.unflag)
            try app.wait("U clearing it") { Self.culled(urls[0], in: $0).flag == nil }
            try app.waitWritten()
            library.update(photos.asset(0)) { $0.created = Date(timeIntervalSinceReferenceDate: 800_000_000) }
            library.update(photos.asset(1)) { $0.isFavorite = true }
            try app
                .wait("the photo Photos favourites a pick", timeout: 30) { Self.culled(urls[1], in: $0).flag == .pick }
            try app.expect(
                try app.main { Self.culled(urls[0], in: $0).flag } == nil, "\(names[0])'s pick back from Photos",
            )
            try app.press(.undo)
            try app.wait("⌘Z giving \(names[0]) its pick back") { Self.culled(urls[0], in: $0).flag == .pick }

            // A photo added to the album in Photos is listed.
            library.setAlbums(of: photos.asset(2), to: ["album-selects"])
            let added = try photos.listed(app, "album-selects", [0, 1, 2])
            app.covered(.feature("library.disk-changes"), via: .model)

            // A photo deleted from Photos leaves the album for Library Health's Missing Photos, which removes it and
            // offers no Locate… for it.
            library.delete([photos.asset(1)])
            try app.waitForSource("\(names[1]) out of the album", timeout: 30) { model in
                Set(model.items.map(\.url)) == [added[0], added[2]]
            }
            let missing = "sources.health." + HealthCheck.Kind.missing.rawValue
            try app.wait("Missing Photos in the Library panel", timeout: 60) { _ in app.sourceRowLabel(missing) != nil }
            try app.clickSourceRow(missing)
            try app.waitForSource("\(names[1]) under Missing Photos", timeout: 30) { model in
                model.librarySources.shown == .health(.missing) && model.items.contains { $0.url == urls[1] }
            }
            try app.click(.identifier("grid.\(names[1])"))
            try app.wait("\(names[1]) selected, its finding read", timeout: 20) { model in
                model.selectedPhotos == [urls[1]] && model.canPerform(.removeMissingPhotos)
            }
            let offered = try app.rightClick(
                .identifier("grid.\(names[1])"), choosing: ShortcutAction.removeMissingPhotos.title,
            )
            try app.expect(
                !offered.contains { $0.title == ShortcutAction.locateMissingPhoto.title },
                "Locate… offered for a photo deleted from Photos: \(offered.map(\.title))",
            )
            try app.waitForSource("\(names[1]) removed", timeout: 30) { model in
                !model.items.contains { $0.url == urls[1] }
            }
            app.covered(.action(.removeMissingPhotos), via: .mouse)

            // An album renamed in Photos is renamed in the section.
            library.add(ApplePhotosCollection(id: "album-selects", title: "E2E Picks", kind: .album))
            try app.wait("E2E Selects renamed E2E Picks", timeout: 30) { _ in
                app.sourceRowLabel("apple-photos.album-selects")?.hasPrefix("E2E Picks") == true
            }
        }

        static let export = Scenario(
            "export.apple-photos",
            "Export… on photos kept in Apple Photos writes each to the folder chosen, downloading the original only "
                + "in iCloud first, which the filmstrip counts",
            claims: [.feature("export.batch")],
        ) { app in
            guard let host = app.host else { throw ScenarioSkip("needs the app's export settings") }
            try app.openWorking()
            let photos = try ApplePhotosScratch(app)
            let before = try app.main { _ in (host.exports.initialSettings, host.exports.initialPresetID) }
            defer {
                try? app.main { _ in host.exports.recordExport(before.0, presetID: before.1) }
                photos.stopKeeping(app, "album-selects")
                photos.remove(app)
            }
            let library = try photos.simulate(app, [0: ["album-selects"], 1: ["album-selects"], 2: ["album-selects"]])
            library.network = SimulatedPhotosLibrary.Network(latency: .seconds(1))
            try app.main { model in model.showLibrary(.grid) }
            let urls = try photos.keep(app, "album-selects", listing: [0, 1, 2])
            // The dialog's folder panel can't be driven: the dialog opens on the folder, as after an export there.
            let folder = photos.destination.appending(path: "Exports", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try app.main { _ in
                var settings = host.exports.initialSettings
                settings.destinationFolder = folder
                settings.revealInFinder = false
                host.exports.recordExport(settings, presetID: nil)
            }

            try app.choose(Menus.title(of: .selectAllPhotos))
            try app.wait("the album's photos selected", timeout: 30) { $0.selectedCount == 3 }
            try app.choose(Menus.title(of: .export))
            try app.waitForSheet("the Export dialog for 3 photos")
            app.pause(0.5)
            try app.expect(
                try app.pressInSheet(KeyCombo(.character("\r"))),
                "The Export dialog's Export button didn't take Return",
            )
            try app.waitForNoSheet("the Export dialog")
            try app.wait("the filmstrip counting the downloads", timeout: 30) { $0.batchExport.downloads != nil }
            @Sendable func written() -> [String] {
                ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                    .filter { !$0.hasPrefix(".") && !$0.hasSuffix(".redlamp") }.sorted()
            }
            try app.wait("the three exports", timeout: 120) { model in
                model.batchExport.progress == nil && written().count >= 3
            }
            try app.expect(written().count == 3, "The export wrote \(written())")
            for file in written() {
                try app.expect(app.imageProperties(folder.appending(path: file)) != nil, "\(file) doesn't decode")
            }
            let summary = try app.main { $0.batchExport.summary }
            try app.expect(summary == "Exported 3 photos", "The filmstrip says \(summary ?? "nothing")")
            try app.expect(
                try !app.main { $0.library.needsDownload(urls[2]) }, "\(photos.scratch.names[2]) downloaded for it",
            )
            app.covered(.feature("export.batch"), via: .menu)
        }

        /// Show in Photos' openings of Photos while `inPlace` counts them, and what it replaced.
        @MainActor private static var openings = 0
        @MainActor private static var opener: (@MainActor () -> Void)?
        /// The issue Report a Bug would open, as `download` read it.
        @MainActor private static var reported: String?

        struct Culling: Equatable {
            var flag: PhotoFlag?
            var rating: Int?
        }

        /// The photo at `url`'s flag and rating as the grid shows them.
        @MainActor static func culled(_ url: URL, in model: EditorModel) -> Culling {
            let metadata = model.items.first { $0.url == url }?.metadata
            return Culling(flag: metadata?.flag, rating: metadata?.rating)
        }
    }

    extension ApplePhotosScratch {
        /// Keeps `album` in place through Add Albums from Apple Photos…, its box and Add Albums clicked, and waits for
        /// the grid to show it with the photos `numbers` names; their URLs, in that order.
        @discardableResult
        func keep(_ app: RunningApp, _ album: String, listing numbers: [Int]) throws -> [URL] {
            try app.choose(.importFromApplePhotos)
            try app.waitInPhotosWindow("the albums", timeout: 30) { $0.phase == "choosing" && $0.way == "keep" }
            try app.clickInPhotosWindow("photos.album.\(album)")
            try app.waitInPhotosWindow("\(album) chosen") { $0.chosen == [album] }
            try app.clickInPhotosWindow("photos.addAlbums")
            try app.wait("the Apple Photos window closed") { _ in
                ApplePhotosWindowController.current?.window?.isVisible != true
            }
            return try listed(app, album, numbers)
        }

        /// Waits for the grid to show `album` with the photos `numbers` names; their URLs, in that order.
        func listed(_ app: RunningApp, _ album: String, _ numbers: [Int]) throws -> [URL] {
            let names = numbers.map { scratch.names[$0] }
            try app.waitForSource("\(album) listing \(names.joined(separator: ", "))", timeout: 60) { model in
                model.librarySources.shown == .applePhotos(album) && !model.librarySources.isListing
                    && Set(model.items.map(\.name)) == Set(names)
            }
            return try app.main { model in
                try names.map { name in
                    guard let item = model.items.first(where: { $0.name == name }) else {
                        throw ScenarioFailure("\(name) isn't listed in \(album)")
                    }
                    return item.url
                }
            }
        }

        /// Stops keeping `album` in place, as its row's Remove from Library… does once answered: a scenario's cleanup.
        func stopKeeping(_ app: RunningApp, _ album: String) {
            try? app.main { model in
                ApplePhotosRemoval.answer = true
                _ = model.librarySources.removeApplePhotos(album)
            }
            try? app.wait("\(album) no longer kept", timeout: 30) { !$0.librarySources.keepsApplePhotos }
            try? app.main { _ in ApplePhotosRemoval.answer = nil }
        }
    }
#endif
