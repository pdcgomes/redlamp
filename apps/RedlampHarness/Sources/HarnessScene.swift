import SwiftUI

/// Where a scene sits in the sidebar.
enum HarnessSection: String, CaseIterable, Identifiable {
    case foundations = "Foundations"
    case controls = "Controls"
    case panels = "Panels"
    case parity = "Parity"
    case performance = "Performance"
    case recipes = "Recipes"

    var id: String {
        rawValue
    }

    var symbol: String {
        switch self {
        case .foundations: "paintpalette"
        case .controls: "slider.horizontal.3"
        case .panels: "rectangle.split.1x2"
        case .parity: "square.on.square.dashed"
        case .performance: "gauge.with.dots.needle.67percent"
        case .recipes: "wand.and.stars"
        }
    }
}

/// One entry in the harness: a component or pattern in the states worth reviewing.
struct HarnessScene: Identifiable {
    let id: String
    let title: String
    let symbol: String
    /// One line on what to look at, shown under the window title.
    let synopsis: String
    let section: HarnessSection
    /// Built on demand, so a scene that isn't selected costs nothing.
    let content: @MainActor () -> AnyView
    /// An optional tuning pane, shown as the trailing inspector.
    let inspector: (@MainActor () -> AnyView)?
    /// Whole-window tools (the Recipe Lab) fill the stage instead of sitting in its scroll view.
    var fillsStage = false

    init(
        id: String, title: String, symbol: String, synopsis: String, section: HarnessSection,
        @ViewBuilder content: @escaping @MainActor () -> some View,
    ) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.synopsis = synopsis
        self.section = section
        self.content = { AnyView(content()) }
        inspector = nil
    }

    init(
        id: String, title: String, symbol: String, synopsis: String, section: HarnessSection,
        @ViewBuilder content: @escaping @MainActor () -> some View,
        @ViewBuilder inspector: @escaping @MainActor () -> some View,
    ) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.synopsis = synopsis
        self.section = section
        self.content = { AnyView(content()) }
        self.inspector = { AnyView(inspector()) }
    }
}

/// The ordered list of scenes. Built once and stored: scenes capture their tuning models,
/// which must survive SwiftUI re-creating the views that reference them.
struct HarnessCatalog {
    private(set) var scenes: [HarnessScene] = []

    @MainActor static let shared = BuiltInScenes.catalog()

    mutating func register(_ scene: HarnessScene) {
        precondition(!scenes.contains { $0.id == scene.id }, "Duplicate harness scene id \(scene.id)")
        scenes.append(scene)
    }

    var sections: [HarnessSection] {
        HarnessSection.allCases.filter { section in scenes.contains { $0.section == section } }
    }

    func scenes(in section: HarnessSection) -> [HarnessScene] {
        scenes.filter { $0.section == section }
    }

    func scene(id: String?) -> HarnessScene? {
        scenes.first { $0.id == id }
    }
}
