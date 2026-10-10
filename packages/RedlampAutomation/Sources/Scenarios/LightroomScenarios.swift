#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import RedlampDocument
    import RedlampLibrary
    @_spi(Harness) import RedlampUI

    /// Lightroom Classic catalogs (LIB-29), from a catalog the run makes of photos of its own: never one Lightroom
    /// made, and never the run's working folder.
    enum LightroomScenarios {
        static let all: [Scenario] = [importCatalog]

        static let importCatalog = Scenario(
            "library.lightroom",
            "File › Import from Lightroom Classic… reports a catalog of a folder the library doesn't have, Import adds "
                + "the folder and brings its ratings, picks, labels, keywords, title and collections into the photos' "
                + "sidecars, and Undo Import takes them back",
            claims: [.action(.importFromLightroom)],
        ) { app in
            let scratch = try SourcesScratch(
                app, photos: ["Shoot/LR_0001.jpg", "Shoot/LR_0002.jpg", "Shoot/LR_0003.jpg"],
            )
            let tag = String(scratch.folder.lastPathComponent.suffix(8))
            let catalog = try LightroomScratchCatalog.make(of: scratch.folder, tag: tag)
            defer {
                try? app.main { _ in LightroomWindowController.current?.close() }
                scratch.remove(app)
                try? FileManager.default.removeItem(at: catalog.deletingLastPathComponent())
            }
            try app.main { model in model.showLibrary(.grid) }
            try app.choose(.importFromLightroom)
            try app.wait("the Lightroom Classic window", timeout: 30) { _ in
                LightroomWindowController.current?.window?.isVisible == true
            }
            // Choose…'s open panel can't be driven: the catalog it would pick is handed to the window.
            try app.inLightroomWindow { $0.choose(catalog: catalog) }
            try app.wait("the catalog's report", timeout: 60) { _ in
                LightroomWindowController.current?.isReported == true
            }
            let report = try app.inLightroomWindow { $0.report }
            try app.expect(
                report?.photos == 3 && report?.waiting == 3 && report?.roots.first?.state == .notInLibrary,
                "the report: \(report.map { $0.lines().joined(separator: " / ") } ?? "none")",
            )
            try app.expect(report?.smartMapped.count == 1 && report?.smartLeft.count == 1, "the smart collections")
            let sidecars = SidecarStore(locator: .besidePhotos)
            let photos = scratch.names.map(scratch.photo)
            try app.expect(photos.allSatisfy { sidecars.load(for: $0) == nil }, "the report wrote nothing")

            try app.clickInLightroomWindow("lightroom.import")
            try app.wait("the import", timeout: 180) { _ in LightroomWindowController.current?.isImported == true }
            let outcome = try app.inLightroomWindow { window in
                window.outcome.map { "\($0.record.photos) \($0.skipped.count)" } ?? (window.problem ?? "nothing")
            }
            try app.expect(outcome == "3 0", "imported: \(outcome)")
            try app.expect(
                try app.main { model in model.library.root(containing: scratch.folder) != nil },
                "the catalog's root folder is in Folders",
            )
            let first = sidecars.load(for: photos[0])?.metadata
            try app.expect(
                first?.rating == 5 && first?.flag == .pick && first?.label == .red && first?.title == "Tram \(tag)"
                    && first?.keywords == ["Places \(tag)/Lisbon"] && first?.collections == ["Lightroom \(tag)/Trip"],
                "the first photo's sidecar: \(String(describing: first))",
            )
            let second = sidecars.load(for: photos[1])?.metadata
            try app.expect(
                second?.flag == .reject && second?.customLabel == "Client \(tag)",
                "the second photo's sidecar: \(String(describing: second))",
            )
            try app.expect(sidecars.load(for: photos[2])?.metadata?.mark == true, "the Quick Collection is the mark")
            try app.wait("the import's keyword in the Keyword List", timeout: 30) { model in
                model.libraryPanels.refreshKeywords()
                return model.libraryPanels.keywordList?.keywords[KeywordPath("Places \(tag)/Lisbon")!]?.photos == 1
            }

            try app.clickInLightroomWindow("lightroom.undo")
            try app.wait("the import taken back", timeout: 120) { _ in
                LightroomWindowController.current?.isUndone == true
            }
            for photo in photos {
                let metadata = sidecars.load(for: photo)?.metadata
                try app.expect(
                    metadata == nil || metadata?.isEmpty == true,
                    "\(photo.lastPathComponent)'s sidecar after Undo: \(String(describing: metadata))",
                )
            }
            app.covered(.action(.importFromLightroom), via: .menu)
        }
    }

    /// A Lightroom Classic catalog of a folder, made by the run with the tables the import reads: three photos
    /// rated, picked, rejected and labelled, one in the Quick Collection, a keyword with a synonym, a title, a
    /// collection in a set, and two smart collections, one whose rule maps and one whose doesn't.
    enum LightroomScratchCatalog {
        static func make(of folder: URL, tag: String) throws -> URL {
            let url = folder.deletingLastPathComponent()
                .appending(path: "lightroom-\(tag)/Lightroom Catalog.lrcat")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            let database = try SQLiteDatabase(path: url.path)
            let root = folder.standardizedFileURL.path + "/"
            func text(_ value: String) -> String {
                "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
            }
            let title = "Tram \(tag)"
            let packet = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
            <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/">\
            <dc:title><rdf:Alt><rdf:li xml:lang="x-default">\(title)</rdf:li></rdf:Alt></dc:title>\
            </rdf:Description></rdf:RDF></x:xmpmeta>
            """
            try database.execute("""
            CREATE TABLE Adobe_variablesTable (id_local INTEGER PRIMARY KEY, id_global UNIQUE NOT NULL, name, value);
            CREATE TABLE AgLibraryRootFolder (id_local INTEGER PRIMARY KEY, id_global UNIQUE NOT NULL,
              absolutePath UNIQUE NOT NULL DEFAULT '', name NOT NULL DEFAULT '', relativePathFromCatalog);
            CREATE TABLE AgLibraryFolder (id_local INTEGER PRIMARY KEY, id_global UNIQUE NOT NULL, parentId INTEGER,
              pathFromRoot NOT NULL DEFAULT '', rootFolder INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE AgLibraryFile (id_local INTEGER PRIMARY KEY, id_global UNIQUE NOT NULL,
              baseName NOT NULL DEFAULT '', extension NOT NULL DEFAULT '', folder INTEGER NOT NULL DEFAULT 0,
              idx_filename NOT NULL DEFAULT '', sidecarExtensions);
            CREATE TABLE Adobe_images (id_local INTEGER PRIMARY KEY, id_global UNIQUE NOT NULL,
              colorLabels NOT NULL DEFAULT '', copyName, masterImage INTEGER, pick NOT NULL DEFAULT 0, rating,
              rootFile INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE AgLibraryKeyword (id_local INTEGER PRIMARY KEY, id_global UNIQUE NOT NULL,
              includeOnExport INTEGER NOT NULL DEFAULT 1, includeParents INTEGER NOT NULL DEFAULT 1,
              includeSynonyms INTEGER NOT NULL DEFAULT 1, keywordType, lc_name, name, parent INTEGER);
            CREATE TABLE AgLibraryKeywordImage (id_local INTEGER PRIMARY KEY, image INTEGER NOT NULL DEFAULT 0,
              tag INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE AgLibraryKeywordSynonym (id_local INTEGER PRIMARY KEY, keyword INTEGER NOT NULL DEFAULT 0,
              lc_name, name);
            CREATE TABLE AgLibraryCollection (id_local INTEGER PRIMARY KEY, creationId NOT NULL DEFAULT '',
              name NOT NULL DEFAULT '', parent INTEGER, systemOnly NOT NULL DEFAULT '');
            CREATE TABLE AgLibraryCollectionImage (id_local INTEGER PRIMARY KEY, collection INTEGER NOT NULL DEFAULT 0,
              image INTEGER NOT NULL DEFAULT 0, positionInCollection);
            CREATE TABLE AgLibraryCollectionContent (id_local INTEGER PRIMARY KEY,
              collection INTEGER NOT NULL DEFAULT 0, content, owningModule);
            CREATE TABLE AgLibraryIPTC (id_local INTEGER PRIMARY KEY, caption, copyright, image INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE Adobe_AdditionalMetadata (id_local INTEGER PRIMARY KEY, id_global UNIQUE NOT NULL, image INTEGER,
              xmp NOT NULL DEFAULT '');
            INSERT INTO Adobe_variablesTable VALUES (1, 'v', 'Adobe_DBVersion', '1300025');
            INSERT INTO AgLibraryRootFolder VALUES (2, 'r', \(text(root)), \(text(folder.lastPathComponent)), NULL);
            INSERT INTO AgLibraryFolder VALUES (3, 'f', NULL, 'Shoot/', 2);
            INSERT INTO AgLibraryFile VALUES (11, 'a', 'LR_0001', 'jpg', 3, 'LR_0001.jpg', NULL),
              (12, 'b', 'LR_0002', 'jpg', 3, 'LR_0002.jpg', NULL), (13, 'c', 'LR_0003', 'jpg', 3, 'LR_0003.jpg', NULL);
            INSERT INTO Adobe_images VALUES (21, 'i1', 'Red', NULL, NULL, 1, 5, 11),
              (22, 'i2', \(text("Client \(tag)")), NULL, NULL, -1, 2, 12), (23, 'i3', '', NULL, NULL, 0, NULL, 13),
              (24, 'i4', '', 'Copy 1', 21, 0, 4, 11);
            INSERT INTO AgLibraryKeyword VALUES (30, 'k0', 1, 1, 1, NULL, NULL, NULL, NULL),
              (31, 'k1', 1, 1, 1, NULL, \(text("places \(tag)")), \(text("Places \(tag)")), 30),
              (32, 'k2', 1, 1, 1, NULL, 'lisbon', 'Lisbon', 31);
            INSERT INTO AgLibraryKeywordSynonym VALUES (40, 32, 'lisboa', 'Lisboa');
            INSERT INTO AgLibraryKeywordImage VALUES (41, 21, 32);
            INSERT INTO AgLibraryCollection VALUES (50, 'com.adobe.ag.library.group', \(
                text("Lightroom \(tag)")
            ), NULL, ''),
              (51, 'com.adobe.ag.library.collection', 'Trip', 50, ''),
              (52, 'com.adobe.ag.library.collection', 'Quick Collection', NULL, '1'),
              (53, 'com.adobe.ag.library.smart_collection', 'Five stars', 50, ''),
              (54, 'com.adobe.ag.library.smart_collection', 'Edited this week', 50, '');
            INSERT INTO AgLibraryCollectionImage VALUES (60, 51, 21, 'a'), (61, 52, 23, 'a');
            INSERT INTO AgLibraryCollectionContent VALUES
              (70, 53, 's = { { criteria = "rating", operation = "==", value = 5, value2 = 0, }, combine = "intersect", }',
               'ag.library.smart_collection'),
              (71, 54, 's = { { criteria = "touchTime", operation = "inLast", value = 7, value2 = "days", }, '
               || 'combine = "intersect", }', 'ag.library.smart_collection');
            INSERT INTO Adobe_AdditionalMetadata VALUES (80, 'x1', 21, \(text(packet)));
            """)
            return url
        }
    }

    extension RunningApp {
        /// Runs `body` on the main thread with the Lightroom Classic window open now.
        @discardableResult
        func inLightroomWindow<T: Sendable>(_ body: @escaping @MainActor (LightroomWindowController) throws -> T)
            throws -> T {
            try main { _ in
                guard let window = LightroomWindowController.current else {
                    throw ScenarioFailure("The Lightroom Classic window isn't open")
                }
                return try body(window)
            }
        }

        /// Clicks the button carrying `identifier` in the Lightroom Classic window through the window, as the mouse
        /// does.
        func clickInLightroomWindow(_ identifier: String) throws {
            let location = try inLightroomWindow { controller -> NSPoint in
                guard let window = controller.window, let content = window.contentView,
                      let control = Self.lightroomView(identifier, in: content)
                else { throw ScenarioFailure("\(identifier) isn't in the Lightroom Classic window") }
                guard control.isHiddenOrHasHiddenAncestor == false, (control as? NSControl)?.isEnabled != false else {
                    throw ScenarioFailure("\(identifier) is hidden or disabled: \(controller.statusText)")
                }
                window.makeKeyAndOrderFront(nil)
                let frame = control.convert(control.bounds, to: nil)
                return NSPoint(x: frame.midX, y: frame.midY)
            }
            post { _ in
                guard let window = LightroomWindowController.current?.window else { return }
                let events = [NSEvent.EventType.leftMouseDown, .leftMouseUp].compactMap { type in
                    NSEvent.mouseEvent(
                        with: type, location: location, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1,
                    )
                }
                guard events.count == 2 else { return }
                // The button tracks the press, and takes the release from the queue as the mouse's.
                NSApp.postEvent(events[1], atStart: false)
                window.sendEvent(events[0])
            }
            pause(0.2)
        }

        @MainActor private static func lightroomView(_ identifier: String, in view: NSView) -> NSView? {
            if view.accessibilityIdentifier() == identifier {
                return view
            }
            for subview in view.subviews {
                if let found = lightroomView(identifier, in: subview) {
                    return found
                }
            }
            return nil
        }
    }
#endif
