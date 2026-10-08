#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import RedlampLibrary
    @_spi(Harness) import RedlampUI

    /// The left panel's Collections section (LIB-23): sets and collections made from the File menu, ⌘N and a
    /// set's menu, renamed, moved into a set and deleted with Undo; the selection's photos put in a collection from
    /// the Photo menu and the palette and taken out of the one shown with ⌫; and the target collection.
    enum CollectionScenarios {
        static let all: [Scenario] = [collections, targetCollection]

        static let collections = Scenario(
            "library.collections",
            "Collections and sets made from the File menu, ⌘N and a set's menu, photos put in from the Photo menu and the "
                + "palette and taken out with ⌫, renamed, moved and deleted, with Undo",
            claims: [
                .action(.newCollection), .action(.newCollectionSet), .action(.addToCollection),
                .action(.removeFromCollection),
            ],
        ) { app in
            let scratch = try SourcesScratch(app, photos: ["A.jpg", "B.jpg", "C.jpg"])
            defer {
                app.removeCollectionsMade()
                scratch.remove(app)
            }
            try scratch.index(app)
            let (a, b, c) = (scratch.photo("A.jpg"), scratch.photo("B.jpg"), scratch.photo("C.jpg"))
            let tag = scratch.folder.lastPathComponent.suffix(8)
            let clients = "Clients \(tag)"

            // The File menu: a set.
            try app.choose(.newCollectionSet)
            try app.waitForSheet("New Collection Set")
            try app.replaceInSheet("collections.name", with: clients)
            try app.confirmSheet("New Collection Set")
            try app.wait("the set in the Collections panel", timeout: 30) { _ in
                app.sourceRowLabel("collections.\(clients)") != nil
            }

            // The set's menu: a collection inside it, with the two photos selected.
            try app.main { model in
                model.select(a)
                model.click(b, toggling: true)
            }
            try app.rightClick(.identifier("collections.\(clients)"), choosing: "New Collection Inside…")
            try app.waitForSheet("New Collection")
            try app.replaceInSheet("collections.name", with: "Selects")
            try app.confirmSheet("New Collection")
            let selects = "\(clients)/Selects"
            try app.wait("Selects with the two photos", timeout: 30) { _ in
                app.sourceRowLabel("collections.\(selects)") == "Selects, 2 photos"
            }

            // ⌘N: a collection at the top, without the photos selected.
            try app.press(.newCollection)
            try app.waitForSheet("New Collection")
            try app.replaceInSheet("collections.name", with: "Portfolio \(tag)")
            try app.pressInSheet("collections.include")
            try app.confirmSheet("New Collection")
            let portfolio = "Portfolio \(tag)"
            try app.wait("an empty Portfolio", timeout: 30) { _ in
                app.sourceRowLabel("collections.\(portfolio)") == "\(portfolio), 0 photos"
            }

            // The Photo menu, then the palette: photos into Portfolio.
            try app.main { $0.select(c) }
            try app.choose(.addToCollection)
            try app.waitForSheet("Add to a Collection")
            try app.chooseInCollectionSheet("collections.choice", portfolio)
            try app.confirmSheet("Add to a Collection")
            try app.wait("C in Portfolio", timeout: 30) { _ in
                app.sourceRowLabel("collections.\(portfolio)") == "\(portfolio), 1 photo"
            }
            try app.main { $0.select(b) }
            try app.runFromPalette(.addToCollection)
            try app.waitForSheet("Add to a Collection")
            try app.chooseInCollectionSheet("collections.choice", portfolio)
            try app.confirmSheet("Add to a Collection")
            try app.wait("B in Portfolio", timeout: 30) { _ in
                app.sourceRowLabel("collections.\(portfolio)") == "\(portfolio), 2 photos"
            }

            // Selects shown by a click on its row: ⌫ takes A out, and ⌘Z puts it back.
            try app.click(.identifier("collections.\(selects)"))
            try app.wait("Selects shown", timeout: 20) { model in
                !model.librarySources.isListing && Set(model.items.map(\.url)) == [a, b]
            }
            try app.main { $0.select(a) }
            try app.press(.removeFromCollection)
            try app.wait("A out of Selects", timeout: 30) { $0.items.map(\.url) == [b] }
            try app.press(.undo)
            try app.wait("A back in Selects", timeout: 30) { $0.items.count == 2 }

            // Its menu renames Portfolio, moves it into the set, and deletes the set; ⌘Z brings the set back.
            try app.rightClick(.identifier("collections.\(portfolio)"), choosing: "Rename…")
            try app.waitForSheet("Rename")
            let best = "Best \(tag)"
            try app.replaceInSheet("collections.name", with: best)
            try app.confirmSheet("Rename")
            try app.wait("Portfolio renamed", timeout: 30) { _ in
                app.sourceRowLabel("collections.\(best)") == "\(best), 2 photos"
            }
            try app.rightClickCollection("collections.\(best)", choosing: ["Move To", clients])
            try app.wait("Best inside the set", timeout: 30) { _ in
                app.sourceRowLabel("collections.\(clients)/\(best)") == "\(best), 2 photos"
            }
            try app.rightClick(.identifier("collections.\(clients)"), choosing: "Delete")
            try app.wait("the set deleted", timeout: 30) { _ in app.sourceRowLabel("collections.\(clients)") == nil }
            try app.press(.undo)
            try app.wait("the set back, with what was inside it", timeout: 30) { _ in
                app.sourceRowLabel("collections.\(selects)") == "Selects, 2 photos"
                    && app.sourceRowLabel("collections.\(clients)/\(best)") == "\(best), 2 photos"
            }
        }

        static let targetCollection = Scenario(
            "library.target-collection",
            "A collection made the target as it's made and from Marked's menu, marked + in the list, and Add to Target "
                + "Collection from the Photo menu and the palette",
            claims: [.action(.addToTargetCollection)],
        ) { app in
            let scratch = try SourcesScratch(app, photos: ["A.jpg", "B.jpg"])
            defer {
                app.removeCollectionsMade()
                scratch.remove(app)
            }
            try scratch.index(app)
            let (a, b) = (scratch.photo("A.jpg"), scratch.photo("B.jpg"))
            let picks = "Picks \(scratch.folder.lastPathComponent.suffix(8))"

            // ⌘N, the target as it's made.
            try app.main { $0.select(a) }
            try app.press(.newCollection)
            try app.waitForSheet("New Collection")
            try app.replaceInSheet("collections.name", with: picks)
            try app.pressInSheet("collections.include")
            try app.pressInSheet("collections.target")
            try app.confirmSheet("New Collection")
            try app.wait("the target, marked + in the list", timeout: 30) { _ in
                app.sourceRowLabel("collections.\(picks)") == "\(picks), 0 photos, target collection"
            }

            // The Photo menu, then the palette.
            try app.choose(.addToTargetCollection)
            try app.wait("A in the target", timeout: 30) { _ in
                app.sourceRowLabel("collections.\(picks)") == "\(picks), 1 photo, target collection"
            }
            try app.main { $0.select(b) }
            try app.runFromPalette(.addToTargetCollection)
            try app.wait("B in the target", timeout: 30) { _ in
                app.sourceRowLabel("collections.\(picks)") == "\(picks), 2 photos, target collection"
            }

            // Marked's menu makes it the target: the next photo is marked.
            try app.rightClick(.identifier("sources.marked"), choosing: "Set as Target Collection")
            try app.wait("Marked the target", timeout: 30) { model in
                model.librarySources.target == nil
                    && app.sourceRowLabel("collections.\(picks)") == "\(picks), 2 photos"
            }
            try app.main { $0.select(a) }
            try app.choose(.addToTargetCollection)
            try app.wait("A marked", timeout: 30) { model in
                model.library.item(for: a)?.metadata.mark == true
            }
        }
    }

    extension RunningApp {
        /// Chooses `title` in the pop-up `identifier` of the sheet in front, as a click in its menu does.
        func chooseInCollectionSheet(_ identifier: String, _ title: String) throws {
            try main { _ in
                guard let sheet = NSApp.modalWindow ?? Views.editorWindow?.attachedSheet,
                      let content = sheet.contentView,
                      let popUp = Views.all(NSPopUpButton.self, in: content)
                      .first(where: { $0.accessibilityIdentifier() == identifier }),
                      let item = popUp.item(withTitle: title)
                else { throw ScenarioFailure("\(identifier) in the sheet has no \(title)") }
                popUp.select(item)
            }
            pause(0.1)
        }

        /// Right-clicks the row carrying `identifier` and chooses the item `path` names in its menu, a submenu's
        /// title first ("Move To", then the set).
        func rightClickCollection(_ identifier: String, choosing path: [String]) throws {
            let frame = try frame(of: .identifier(identifier))
            let location = NSPoint(x: frame.midX, y: frame.midY)
            let opened = OpenedMenu()
            try main { _ in opened.watch() }
            defer { try? main { _ in opened.stop() } }
            post { _ in
                guard let window = Views.editorWindow else { return }
                for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
                    guard let event = NSEvent.mouseEvent(
                        with: type, location: location, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .rightMouseUp ? 0 : 1,
                    ) else { continue }
                    window.sendEvent(event)
                }
            }
            try wait("\(identifier)'s context menu to open") { _ in opened.menu != nil }
            try main { _ in
                guard let menu = opened.menu else { return }
                defer { menu.cancelTracking() }
                var current = menu
                for (step, title) in path.enumerated() {
                    guard let index = current.items.firstIndex(where: { $0.title == title }) else {
                        throw ScenarioFailure(
                            "\(identifier)'s menu has no \(path.prefix(step + 1).joined(separator: " › "))",
                        )
                    }
                    if step == path.count - 1 {
                        current.performActionForItem(at: index)
                    } else if let submenu = current.items[index].submenu {
                        current = submenu
                    }
                }
            }
            try wait("\(identifier)'s context menu to close") { _ in opened.closed }
        }

        /// Deletes every collection and set the scenarios made, which their names end with the scratch's tag.
        func removeCollectionsMade() {
            try? main { model in
                let sources = model.librarySources
                for place in sources.collections(inside: nil)
                    where ["Clients ", "Portfolio ", "Best ", "Picks "].contains(where: place.path.name.hasPrefix) {
                    sources.delete(place.path)
                }
            }
            try? run("the collections deleted", timeout: 30) { model in await model.libraryPanels.written() }
        }
    }
#endif
