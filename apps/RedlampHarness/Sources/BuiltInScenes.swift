/// The harness's table of contents. Add a scene here to put it in the sidebar.
enum BuiltInScenes {
    @MainActor
    static func catalog() -> HarnessCatalog {
        var catalog = HarnessCatalog()
        catalog.register(.tokens)
        catalog.register(.themeGallery)
        catalog.register(.sliderRows)
        catalog.register(.panelChrome)
        catalog.register(.notices)
        catalog.register(.basicPanel)
        catalog.register(.history)
        catalog.register(.folders)
        catalog.register(.sliderRowParity)
        catalog.register(.basicPanelParity)
        catalog.register(.toneCurveParity)
        catalog.register(.histogramParity)
        HarnessScene.referencePanelParity.forEach { catalog.register($0) }
        catalog.register(.panelPerformance)
        catalog.register(.recipeLab)
        catalog.register(.commandPalette)
        catalog.register(.commandPaletteStates)
        catalog.register(.exportLive)
        catalog.register(.exportStates)
        return catalog
    }
}
