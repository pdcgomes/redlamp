import SwiftUI

struct HarnessRootView: View {
    private let catalog = HarnessCatalog.shared
    @State private var selection: String? = HarnessLaunch.value(after: "--scene") ?? HarnessCatalog.shared.scenes.first?
        .id
    @State private var settings = StageSettings()

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(catalog.sections) { section in
                    Section {
                        ForEach(catalog.scenes(in: section)) { scene in
                            Label(scene.title, systemImage: scene.symbol).tag(scene.id)
                        }
                    } header: {
                        Label(section.rawValue, systemImage: section.symbol)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { SidebarThemeControls(theme: $settings.theme) }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            if let scene = catalog.scene(id: selection) {
                Stage(scene: scene, settings: $settings)
            } else {
                ContentUnavailableView("Choose a scene", systemImage: "square.grid.2x2")
            }
        }
        .preferredColorScheme(settings.theme.appearance == .dark ? .dark : .light)
        .task { MetricsProbe.runIfRequested() }
    }
}
