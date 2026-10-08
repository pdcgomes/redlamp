import Foundation
import RedlampEngine
import RedlampLab
import RedlampUI
import SwiftUI
@preconcurrency import UserNotifications

extension HarnessScene {
    static var recipeLab: HarnessScene {
        var scene = HarnessScene(
            id: "recipe-lab",
            title: "Recipe Lab",
            symbol: "wand.and.stars",
            synopsis: "Every recipe, Base Look and LUT on the look-dev set and the lint chart: "
                + "compare, inspect, lint, create, and review agent runs",
            section: .recipes,
        ) {
            RecipeLabView(
                model: HarnessLab.model,
                tab: HarnessLaunch.value(after: "--lab-tab").flatMap { name in
                    RecipeLabView.Tab.allCases.first { $0.rawValue.lowercased() == name.lowercased() }
                } ?? .compare,
                showsGallery: !HarnessLaunch.arguments.contains("--lab-hide-gallery"),
            )
        }
        scene.fillsStage = true
        return scene
    }
}

/// The Lab renders on its own engine, so its gallery never disturbs the editor's photo; its
/// creator edits through the shared harness editor.
@MainActor
enum HarnessLab {
    static let model: RecipeLabModel = {
        guard let engine = try? RedlampEngine() else {
            fatalError("The harness needs a Metal GPU")
        }
        let model = RecipeLabModel(engine: engine, editor: HarnessEditor.model, root: repositoryRoot)
        // For scripted screenshots: `--lab-select <recipe id>` and `--lab-compare <recipe id>`
        // pick A and B, `--lab-mode <split|beforeAfter|sideBySide|flicker|acrossSet>` the
        // comparison, `--lab-image <camera>` the photo, `--lab-tab <tab>` and
        // `--lab-hide-gallery` the layout, and `--lab-run <run>` the studio run.
        if let id = HarnessLaunch.value(after: "--lab-select") {
            model.selectedID = model.allItems.first { $0.recipe.id == id }?.id
        }
        if let id = HarnessLaunch.value(after: "--lab-compare") {
            model.compareID = model.allItems.first { $0.recipe.id == id }?.id
        }
        if let name = HarnessLaunch.value(after: "--lab-mode"),
           let mode = LabCompareMode.allCases.first(where: { "\($0)".lowercased() == name.lowercased() }) {
            model.compareMode = mode
        }
        if let name = HarnessLaunch.value(after: "--lab-image"),
           let image = model.images.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
            model.selectedImage = image
        }
        model.preferredRun = HarnessLaunch.value(after: "--lab-run")
        return model
    }()

    /// Look references that reach the hub are fitted as they arrive, and a notification says
    /// when their candidates are ready to evaluate.
    static func connectBench() {
        let looks = model.looks
        LabBench.shared.onArrival = { looks.arrived($0) }
        looks.notify = { text in
            let center = UNUserNotificationCenter.current()
            center.requestAuthorization(options: [.alert]) { granted, _ in
                guard granted else { return }
                let content = UNMutableNotificationContent()
                content.title = "Ready to evaluate"
                content.body = text
                center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            }
        }
    }

    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}
