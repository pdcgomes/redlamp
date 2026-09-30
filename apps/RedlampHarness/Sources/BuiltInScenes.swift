/// The harness's table of contents. Add a scene here to put it in the sidebar.
enum BuiltInScenes {
    @MainActor
    static func catalog() -> HarnessCatalog {
        var catalog = HarnessCatalog()
        catalog.register(.tokens)
        catalog.register(.sliderRows)
        catalog.register(.panelChrome)
        catalog.register(.basicPanel)
        catalog.register(.sliderRowParity)
        catalog.register(.basicPanelParity)
        catalog.register(.toneCurveParity)
        catalog.register(.histogramParity)
        catalog.register(.panelPerformance)
        return catalog
    }
}
