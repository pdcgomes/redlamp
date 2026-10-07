#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import Carbon.HIToolbox
    import RedlampDocument
    import RedlampLibrary
    @_spi(Harness) import RedlampUI

    extension RunningApp {
        /// The Settings window, while it's open.
        @MainActor static var settingsWindow: NSWindow? {
            NSApp.windows.first { window in
                window.isVisible && !(window.windowController is EditorWindowController) && !window.isSheet
                    && window.level == .normal && window.toolbar != nil
            }
        }

        /// Opens Settings from the app menu, then its tab titled `tab` as a click on the tab's toolbar item
        /// chooses it.
        func openSettings(tab: String) throws {
            let title = try main { _ -> String in
                NSApp.mainMenu?.items.first?.submenu?.items.first { $0.title.hasPrefix("Settings") }?.title ?? ""
            }
            try expect(!title.isEmpty, "No Settings item in the app menu")
            try choose(title)
            try wait("the Settings window") { _ in Self.settingsWindow != nil }
            try main { _ in
                guard let window = Self.settingsWindow, let toolbar = window.toolbar else {
                    throw ScenarioFailure("Settings has no tabs")
                }
                guard let item = toolbar.items.first(where: { $0.label == tab }) else {
                    throw ScenarioFailure("Settings has no \(tab) tab: \(toolbar.items.map(\.label))")
                }
                if let action = item.action {
                    _ = NSApp.sendAction(action, to: item.target, from: item)
                } else {
                    toolbar.selectedItemIdentifier = item.itemIdentifier
                }
            }
            try wait("Settings › \(tab)") { _ in
                Self.settingsWindow?.toolbar?.selectedItemIdentifier.flatMap { selected in
                    Self.settingsWindow?.toolbar?.items.first { $0.itemIdentifier == selected }?.label
                } == tab
            }
        }

        /// Clicks the control carrying `identifier` in the Settings window, as a click on it does.
        func clickInSettings(_ identifier: String) throws {
            try main { _ in
                guard let window = Self.settingsWindow, let content = window.contentView else {
                    throw ScenarioFailure("Settings isn't open")
                }
                content.layoutSubtreeIfNeeded()
                if let control = Views.all(NSControl.self, in: content).first(where: {
                    $0.accessibilityIdentifier() == identifier
                }) {
                    control.performClick(nil)
                    return
                }
                guard let element = Self.element(identifier, in: content) else {
                    throw ScenarioFailure("Settings has no \(identifier): \(Self.identifiers(in: content))")
                }
                guard element.accessibilityPerformPress() else {
                    throw ScenarioFailure("\(identifier) in Settings didn't take the click")
                }
            }
            pause(0.1)
        }

        /// Presses Return in the sheet over the Settings window, as its default button's key.
        func confirmInSettings(_ what: @autoclosure () -> String) throws {
            let description = what()
            try wait("\(description) to ask") { _ in Self.settingsWindow?.attachedSheet != nil }
            try main { _ in
                guard let sheet = Self.settingsWindow?.attachedSheet,
                      let event = NSEvent.keyEvent(
                          with: .keyDown, location: .zero, modifierFlags: [],
                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber,
                          context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false,
                          keyCode: UInt16(kVK_Return),
                      )
                else { throw ScenarioFailure("No sheet over Settings") }
                if !sheet.performKeyEquivalent(with: event) {
                    sheet.sendEvent(event)
                }
            }
            try wait("\(description) to close") { _ in Self.settingsWindow?.attachedSheet == nil }
        }

        func closeSettings() throws {
            try main { _ in Self.settingsWindow?.close() }
            try wait("Settings to close") { _ in Self.settingsWindow == nil }
        }

        /// The accessibility element below `view` carrying `identifier`.
        @MainActor private static func element(_ identifier: String, in view: Any) -> NSAccessibilityProtocol? {
            guard let element = view as? NSAccessibilityProtocol else { return nil }
            if element.accessibilityIdentifier() == identifier {
                return element
            }
            for child in element.accessibilityChildren() ?? [] {
                if let found = self.element(identifier, in: child) {
                    return found
                }
            }
            return nil
        }

        @MainActor private static func identifiers(in view: Any) -> [String] {
            guard let element = view as? NSAccessibilityProtocol else { return [] }
            let own = element.accessibilityIdentifier().map { [$0] }?.filter { !$0.isEmpty } ?? []
            return own + (element.accessibilityChildren() ?? []).flatMap { identifiers(in: $0) }
        }

        /// The library's choices for other apps' metadata, once it's open.
        func xmpSettings() throws -> XMPSettings? {
            try main { $0.library.service?.xmpSettings }
        }

        /// Until the XMP syncs asked for so far are done.
        func waitXMPSynced(timeout: Double = 30) throws {
            let done = DoneFlag()
            post { model in
                Task {
                    await model.library.service?.xmpSynced()
                    done.set()
                }
            }
            try wait("the photos' .xmp to be synced", timeout: timeout) { _ in done.isSet }
        }

        /// What `photo`'s `.xmp` holds, as other apps read it; nil without one.
        static func xmpFields(of photo: URL) -> XMPFields? {
            (try? Data(contentsOf: xmpURL(of: photo))).flatMap { XMPSource(xmp: $0) }?.fields
        }

        static func xmpURL(of photo: URL) -> URL {
            photo.deletingPathExtension().appendingPathExtension("xmp")
        }

        /// Until `photo`'s `.xmp` holds what `holds` looks for.
        func waitInXMP(_ photo: URL, _ what: String, _ holds: @escaping @Sendable (XMPFields?) -> Bool) throws {
            try wait("\(photo.lastPathComponent)'s .xmp to hold \(what)", timeout: 20) { _ in
                holds(Self.xmpFields(of: photo))
            }
        }
    }

    /// Set once, from any thread.
    final class DoneFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        var isSet: Bool {
            lock.withLock { done }
        }

        func set() {
            lock.withLock { done = true }
        }
    }

    /// Metadata shared with other apps (LIB-24): Settings › Library's writing of `.xmp`, and the sync both ways.
    enum OtherAppsScenarios {
        static let all: [Scenario] = [xmp]

        static let xmp = Scenario(
            "library.xmp-sync",
            "Settings › Library writes .xmp for other apps once it's turned on and confirmed; then a rating in the "
                + "grid reaches the photo's .xmp, ⌘Z takes it back and ⇧⌘Z makes it again, and another app's later "
                + "change to the .xmp is taken into the .redlamp",
            claims: [
                .feature("workspace.settings"), .feature("library.ratings"), .feature("library.disk-changes"),
                .action(.undo), .action(.redo),
            ],
        ) { app in
            try app.openWorking()
            try app.wait("the library to open", timeout: 60) { $0.library.service?.isReady == true }
            try app.wait("the library's settings", timeout: 30) { $0.library.service?.xmpSettings != nil }
            try app.expect(try app.xmpSettings()?.writes == false, "Writing .xmp isn't off to begin with")
            try app.openSettings(tab: "Library")
            try app.clickInSettings("settings.library.xmp.write")
            try app.confirmInSettings("turning writing .xmp on")
            try app.wait("writing .xmp on") { $0.library.service?.xmpSettings?.writes == true }
            try app.closeSettings()
            app.covered(.feature("workspace.settings"), via: .mouse)

            var photo: URL?
            var sidecar: (url: URL, kept: URL?)?
            defer {
                // As it was: writing off, no .xmp, and the photo's .redlamp as it was before.
                try? app.main { model in
                    let service = model.library.service
                    Task { _ = await service?.setXMPSettings(XMPSettings()) }
                }
                try? app.wait("writing .xmp off") { $0.library.service?.xmpSettings?.writes == false }
                if let photo {
                    try? FileManager.default.removeItem(at: RunningApp.xmpURL(of: photo))
                    if let sidecar {
                        try? FileManager.default.removeItem(at: sidecar.url)
                        if let kept = sidecar.kept {
                            try? FileManager.default.moveItem(at: kept, to: sidecar.url)
                        }
                    }
                    try? app.main { $0.library.sidecarSaved(photo) }
                }
            }
            try app.withCulling { names in
                try app.click(.identifier("grid.\(names[2])"))
                try app.wait("\(names[2]) alone") { $0.selectedPhotos.map(\.lastPathComponent) == [names[2]] }
                let url = try app.main { model in model.items.first { $0.url.lastPathComponent == names[2] }?.url }
                guard let url else { throw ScenarioFailure("\(names[2]) isn't listed") }
                photo = url
                let store = try app.main { $0.library.sidecars.store(for: url) }
                let saved = store.locator.readURL(for: url)
                let kept = app.runDirectory.appending(path: "xmp-sync-kept.redlamp")
                try? FileManager.default.removeItem(at: kept)
                if FileManager.default.fileExists(atPath: saved.path) {
                    try FileManager.default.copyItem(at: saved, to: kept)
                    sidecar = (saved, kept)
                } else {
                    sidecar = (saved, nil)
                }
                let before = try app.shown(names[2]).rating
                let (stars, key): (Int, ShortcutAction) = before == 4 ? (3, .rating3) : (4, .rating4)

                try app.press(key)
                try app.waitWritten()
                try app.waitXMPSynced()
                try app.waitInXMP(url, "\(stars) stars") { ($0?.rating ?? 0) == stars }

                try app.press(.undo)
                try app.waitWritten()
                try app.waitXMPSynced()
                try app.waitInXMP(url, "\(before) stars, as Undo left the photo") { ($0?.rating ?? 0) == before }
                app.covered([.feature("library.ratings"), .action(.undo)], via: .key)
                try app.expectKeyBinding(.redo)
                try app.choose(.redo)
                try app.waitWritten()
                try app.waitXMPSynced()
                try app.waitInXMP(url, "\(stars) stars again") { ($0?.rating ?? 0) == stars }

                // Another app writes the .xmp afresh a moment later, as Lightroom Classic does: two stars,
                // the photo picked, and a keyword. Written by a process of its own, which change tracking sees.
                let other = """
                <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0">
                 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
                  <rdf:Description rdf:about=""
                    xmlns:xmp="http://ns.adobe.com/xap/1.0/"
                    xmlns:xmpDM="http://ns.adobe.com/xmp/1.0/DynamicMedia/"
                    xmlns:dc="http://purl.org/dc/elements/1.1/"
                   xmp:Rating="2"
                   xmpDM:good="True">
                   <dc:subject><rdf:Bag><rdf:li>E2E Gulls</rdf:li></rdf:Bag></dc:subject>
                  </rdf:Description>
                 </rdf:RDF>
                </x:xmpmeta>

                """
                let staged = app.runDirectory.appending(path: "xmp-sync-other.xmp")
                try Data(other.utf8).write(to: staged)
                app.pause(1.1)
                let copy = Process()
                copy.executableURL = URL(fileURLWithPath: "/bin/cp")
                copy.arguments = [staged.path, RunningApp.xmpURL(of: url).path]
                try copy.run()
                copy.waitUntilExit()
                try app.expect(copy.terminationStatus == 0, "cp couldn't write the other app's .xmp")
                try app.waitInSidecar(names[2], "the other app's two stars, pick and keyword") { metadata in
                    metadata.rating == 2 && metadata.flag == .pick && metadata.keywords == ["E2E Gulls"]
                }
                try app.wait("the grid to show the other app's two stars", timeout: 20) { model in
                    model.items.first { $0.url == url }?.metadata.rating == 2
                }
                app.covered(.feature("library.disk-changes"), via: .model)
                try app.click(.identifier("grid.\(names[0])"))
                try app.wait("\(names[0]) alone") { $0.selectedPhotos.map(\.lastPathComponent) == [names[0]] }
            }
        }
    }
#endif
