#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import RedlampDesign
    import RedlampDocument
    import RedlampEngineAPI
    @_spi(Harness) import RedlampUI

    /// The import window (LIB-27), opened from its menu item; never this Mac's volumes, which the window
    /// is told to leave alone.
    enum ImportScenarios {
        static let all: [Scenario] = [opens]

        static let opens = Scenario(
            "import.window", "Import Photos… opens the import window", claims: [.action(.importPhotos)],
        ) { app in
            try app.openWorking()
            try app.main { _ in ImportWindowController.ignoresVolumes = true }
            // ⇧⌘I: synthetic events don't reach SwiftUI's handling of ⇧⌘ keys, so its item runs from the menu.
            try app.expectKeyBinding(.importPhotos)
            try app.choose(.importPhotos)
            try app.wait("the import window", timeout: 30) { _ in
                ImportWindowController.current?.window?.isVisible == true
            }
            try app.main { _ in
                ImportWindowController.current?.close()
                ImportWindowController.ignoresVolumes = false
            }
        }
    }
#endif
