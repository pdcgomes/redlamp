import RedlampDesign
import SwiftUI

/// What the stage puts behind a scene. Components are judged on the surface they ship on.
enum StageBackground: String, CaseIterable, Identifiable {
    case panel = "Panel"
    case canvas = "Canvas"
    case black = "Black"

    var id: String {
        rawValue
    }

    /// The canvas surround stays neutral under every theme, since the photo sits on it.
    func color(appearance: ThemeAppearance) -> Color {
        switch self {
        case .panel: Palette.panelBackground.color
        case .canvas: RGBA(white: appearance == .dark ? 0.12 : 0.78).color
        case .black: .black
        }
    }
}

struct StageSettings {
    var background = HarnessLaunch.value(after: "--background")
        .flatMap { name in StageBackground.allCases.first { $0.rawValue.lowercased() == name } } ?? .panel
    var inspectorShown = !HarnessLaunch.stageOnly
    /// Setting it installs the theme's tokens straight away, before any view redraws, so
    /// views rebuilt for the change read the new colors when they are made.
    var theme = HarnessLaunch.themeSelection {
        didSet { Palette.current = theme.tokens }
    }

    init() {
        Palette.current = theme.tokens
    }
}

private struct StageIdentity: Hashable {
    let scene: String
    let theme: ThemeSelection
}

/// Presents one scene: its content on the chosen background, and its tuning inspector.
struct Stage: View {
    let scene: HarnessScene
    @Binding var settings: StageSettings

    var body: some View {
        Group {
            if scene.fillsStage {
                scene.content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    scene.content()
                        .padding(32)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .background(settings.background.color(appearance: settings.theme.appearance))
        .environment(\.themeSelection, settings.theme)
        .tint(Palette.current.nativeTint?.color)
        // AppKit views take their colors when they are made, so a theme change rebuilds them.
        .id(StageIdentity(scene: scene.id, theme: settings.theme))
        .navigationTitle(scene.title)
        .navigationSubtitle(scene.synopsis)
        .inspector(isPresented: Binding(
            get: { settings.inspectorShown && scene.inspector != nil },
            set: { settings.inspectorShown = $0 },
        )) {
            scene.inspector?()
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .toolbar { toolbar }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Picker("Background", selection: $settings.background) {
                ForEach(StageBackground.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("The surface behind the scene")
        }
        if scene.inspector != nil {
            ToolbarItem {
                Toggle(isOn: $settings.inspectorShown) {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help("Show the scene's tuning knobs")
            }
        }
    }
}
