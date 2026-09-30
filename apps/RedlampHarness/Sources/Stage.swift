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

    var color: Color {
        switch self {
        case .panel: Palette.panelBackground.color
        case .canvas: RGBA(white: 0.12).color
        case .black: .black
        }
    }
}

struct StageSettings {
    var background = HarnessLaunch.value(after: "--background")
        .flatMap { name in StageBackground.allCases.first { $0.rawValue.lowercased() == name } } ?? .panel
    var inspectorShown = true
}

/// Presents one scene: its content on the chosen background, and its tuning inspector.
struct Stage: View {
    let scene: HarnessScene
    @Binding var settings: StageSettings

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            scene.content()
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(settings.background.color)
        .id(scene.id)
        .navigationTitle(scene.title)
        .navigationSubtitle(scene.synopsis)
        .inspector(isPresented: Binding(
            get: { settings.inspectorShown && scene.inspector != nil },
            set: { settings.inspectorShown = $0 },
        )) {
            scene.inspector?()
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .toolbar {
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
}
