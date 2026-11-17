import AppKit
import RedlampDocument
import RedlampLibrary

/// The library's sheets and windows, which the harness opens over its own window, on a library of its own, to review
/// their layout in each state (LIB-49).
@_spi(Harness) public enum LibrarySurface: String, CaseIterable, Identifiable, Sendable {
    case importPhotos = "import-photos"
    case lightroom
    case applePhotos = "apple-photos"
    case newCollection = "new-collection"
    case newCollectionSet = "new-collection-set"
    case renameCollection = "rename-collection"
    case addToCollection = "add-to-collection"
    case newSmartCollection = "new-smart-collection"
    case editSmartCollection = "edit-smart-collection"
    case customLabels = "custom-labels"
    case editKeyword = "edit-keyword"
    case createKeyword = "create-keyword"
    case mergeKeyword = "merge-keyword"
    case codeReplacements = "code-replacements"
    case editCaptureTime = "edit-capture-time"
    case metadataPresets = "metadata-presets"
    case renamePhotos = "rename-photos"
    case duplicates
    case moveEdits = "move-edits"
    case moveToFolder = "move-to-folder"

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .importPhotos: ShortcutAction.importPhotos.title
        case .lightroom: ShortcutAction.importFromLightroom.title
        case .applePhotos: ShortcutAction.importFromApplePhotos.title
        case .newCollection: ShortcutAction.newCollection.title
        case .newCollectionSet: ShortcutAction.newCollectionSet.title
        case .renameCollection: "Rename Collection…"
        case .addToCollection: ShortcutAction.addToCollection.title
        case .newSmartCollection: ShortcutAction.newSmartCollection.title
        case .editSmartCollection: "Edit Smart Collection…"
        case .customLabels: "Custom Labels…"
        case .editKeyword: "Edit Keyword…"
        case .createKeyword: "Create Keyword…"
        case .mergeKeyword: "Merge Keyword…"
        case .codeReplacements: "Code Replacements…"
        case .editCaptureTime: ShortcutAction.editCaptureTime.title
        case .metadataPresets: "Metadata Presets…"
        case .renamePhotos: ShortcutAction.renamePhotos.title
        case .duplicates: "Accept Health Proposals… (Exact Duplicates)"
        case .moveEdits: ShortcutAction.moveEditsAndMetadata.title
        case .moveToFolder: ShortcutAction.moveToFolder.title
        }
    }
}

/// What the harness's library holds, for the surfaces that need more than the photos selected.
@_spi(Harness) public struct LibraryHarnessFixture: Sendable {
    public var photos: URL
    public var card: URL
    public var destination: URL
    public var backup: URL
    public var catalog: URL?
    /// A simulated Photos library's folder, with a manifest for each access: `manifest-authorized.json` and the rest.
    public var applePhotos: URL?
    /// The access the Apple Photos window finds.
    public var applePhotosAccess = ApplePhotosAccess.authorized

    public init(photos: URL, card: URL, destination: URL, backup: URL, catalog: URL?, applePhotos: URL? = nil) {
        self.photos = photos
        self.card = card
        self.destination = destination
        self.backup = backup
        self.catalog = catalog
        self.applePhotos = applePhotos
    }

    public static let collectionSet = "Travel"
    public static let collection = "Portfolio, the photos for the website and the printed book"
    public static let smartCollection = "Picks and three stars"
    public static let smartQuery = "flag:pick rating>=3 (label:red OR label:green) -keyword:Private"
    public static let keywords = "Places > Portugal > Lisbon > Alfama, Street, People, Market"
    public static let customLabel = "Second pass"
}

@_spi(Harness) public extension EditorModel {
    /// No photo active or selected, as after the last photo shown went to the Trash: where the regression suite's ⌘A
    /// starts from (#543).
    func selectNoPhoto() {
        letGoOfActivePhoto()
    }

    /// Returns once the library is open and lists the photos folder, or after a minute.
    func waitForHarnessLibrary(_ fixture: LibraryHarnessFixture) async {
        showModule(.library)
        open([fixture.photos])
        for _ in 0 ..< 600 {
            if library.service?.isReady == true, !items.isEmpty {
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Gives the library what the sheets show: a set holding a collection, a smart collection, keywords and a custom
    /// label on the photos, once; then selects every photo.
    func prepareHarnessLibrary() async {
        let sources = librarySources
        selectAllPhotos()
        for _ in 0 ..< 100 where libraryPanels.selection.ids.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if sources.collections.isEmpty {
            let set = CollectionPath(names: [LibraryHarnessFixture.collectionSet])
            sources.create(.set, named: LibraryHarnessFixture.collectionSet)
            sources.create(.collection, named: LibraryHarnessFixture.collection, inside: set, adding: true)
            sources.saveSmart(
                LibraryHarnessFixture.smartQuery,
                named: LibraryHarnessFixture.smartCollection,
                inside: nil,
            )
            libraryPanels.addKeywords(LibraryHarnessFixture.keywords)
            _ = giveCustomLabel(LibraryHarnessFixture.customLabel, color: .green)
        }
        for _ in 0 ..< 100 where sources.collections.isEmpty || libraryPanels.keywordList?.ordered.isEmpty != false {
            try? await Task.sleep(for: .milliseconds(100))
        }
        selectAllPhotos()
    }

    /// Opens `surface` over the key window, as its menu item does; false when it couldn't.
    @discardableResult
    func openHarnessSurface(_ surface: LibrarySurface, fixture: LibraryHarnessFixture) async -> Bool {
        guard !isModalDialogOpen else { return false }
        let sources = librarySources
        let collection = sources.collections.values.first { $0.kind == .collection && $0.query == nil }?.path
        let smart = sources.collections.values.first { $0.query != nil }?.path
        let keyword = libraryPanels.keywordList?.ordered.last?.path
        switch surface {
        case .importPhotos:
            guard ImportActions.open(model: self), let window = await shown({ ImportWindowController.current })
            else { return false }
            window.prepare(
                destination: fixture.destination,
                backup: fixture.backup,
                folders: "{date:yyyy}/{date:yyyy-MM-dd}",
                names: "{name}",
            )
            try? await window.add(card: fixture.card)
            return true
        case .lightroom:
            guard LightroomActions.open(model: self) else { return false }
            if let catalog = fixture.catalog {
                await shown { LightroomWindowController.current }?.choose(catalog: catalog)
            }
            return true
        case .applePhotos:
            guard let folder = fixture.applePhotos, let library = try? SimulatedPhotosLibrary(
                manifest: folder.appending(path: "manifest-\(fixture.applePhotosAccess.rawValue).json"),
            ) else { return false }
            simulateApplePhotos(library)
            guard ApplePhotosActions.open(model: self),
                  let window = await shown({ ApplePhotosWindowController.current })
            else { return false }
            window.prepare(destination: fixture.destination, folders: "{album}", names: "{name}")
            return true
        case .newCollection: return CollectionSheets.create(.collection, model: self)
        case .newCollectionSet: return CollectionSheets.create(.set, model: self)
        case .renameCollection: return collection.map { CollectionSheets.rename($0, model: self) } ?? false
        case .addToCollection: return perform(.addToCollection)
        case .newSmartCollection: return SmartCollectionSheet.create(model: self)
        case .editSmartCollection: return smart.map { SmartCollectionSheet.edit($0, model: self) } ?? false
        case .customLabels: return CustomLabelsSheet.present(editor: self)
        case .editKeyword, .createKeyword, .mergeKeyword:
            guard let keyword else { return false }
            switch surface {
            case .editKeyword: KeywordSheets.edit(keyword, panels: libraryPanels, model: self)
            case .createKeyword: KeywordSheets.create(inside: keyword, panels: libraryPanels, model: self)
            default: KeywordSheets.merge(keyword, panels: libraryPanels, model: self)
            }
            return isModalDialogOpen
        case .codeReplacements:
            PanelSheets.editCodeReplacements(model: self)
            return isModalDialogOpen
        case .editCaptureTime: return PanelSheets.editCaptureTime(model: self)
        case .metadataPresets:
            PanelSheets.editPresets(model: self, starting: nil)
            return isModalDialogOpen
        case .renamePhotos: return renamePhotos()
        case .duplicates:
            guard sources.show(.health(.duplicates)) else { return false }
            for _ in 0 ..< 300 where !canAcceptHealthProposals {
                try? await Task.sleep(for: .milliseconds(100))
            }
            return acceptHealthProposals()
        case .moveEdits: return perform(.moveEditsAndMetadata)
        case .moveToFolder: return perform(.moveToFolder)
        }
    }

    /// Takes the albums of Apple Photos kept in place out of the library (LIB-62), as their Remove from Library does,
    /// so a state starts with none kept; returns once the Apple Photos section has gone.
    func stopKeepingHarnessApplePhotos() async {
        let kept = librarySources.applePhotos.collections.map(\.id)
        guard !kept.isEmpty, await (try? library.service?.stopKeepingApplePhotos(kept)) == true else { return }
        for _ in 0 ..< 100 where librarySources.keepsApplePhotos {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Closes the sheet over `window` with its Cancel button, and the import, Lightroom Classic and Apple Photos
    /// windows.
    func closeHarnessSurface(over window: NSWindow?) {
        if let sheet = window?.attachedSheet, let content = sheet.contentView,
           let cancel = Self.button(keyEquivalent: "\u{1B}", in: content) {
            cancel.performClick(nil)
        }
        ImportWindowController.current?.close()
        LightroomWindowController.current?.close()
        ApplePhotosWindowController.current?.close()
    }

    private static func button(keyEquivalent: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.keyEquivalent == keyEquivalent {
            return button
        }
        return view.subviews.lazy.compactMap { button(keyEquivalent: keyEquivalent, in: $0) }.first
    }

    private func shown<Controller: NSWindowController>(_ current: () -> Controller?) async -> Controller? {
        for _ in 0 ..< 50 {
            if let controller = current(), controller.window?.isVisible == true {
                return controller
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }
}
