import AppKit
import Observation
import RedlampDocument
import RedlampEngineAPI
@_spi(Harness) import RedlampUI
import SwiftUI

extension HarnessScene {
    static var history: HarnessScene {
        HarnessScene(
            id: "history",
            title: "History",
            symbol: "clock.arrow.circlepath",
            synopsis: "The sidebar's History on the live editor: every kind of step, an earlier session, and the list keeping its place",
            section: .panels,
        ) {
            HistoryScene()
        } inspector: {
            HistoryInspector()
        }
    }
}

@MainActor @Observable
final class HistorySceneState {
    static let shared = HistorySceneState()

    var height: CGFloat = HarnessLaunch.value(after: "--history-height").flatMap(Double.init).map { CGFloat($0) } ?? 620
    var revision = 0
    var status = "Playing the steps…"
    @ObservationIgnored var lists: [NSView] = []
    @ObservationIgnored private var played = false

    /// The first time the scene shows: a session of every kind of step, saved, then the photo
    /// opened again with a few more, so History has an earlier session to show.
    func prepare() async {
        guard !played else { return }
        played = true
        await HistoryScript.playEveryStep()
        await HistoryScript.reopen()
        await HistoryScript.playFewSteps()
        status = "This session's steps, then the earlier session, expanded"
        await reveal(expandingSessions: true)
    }

    /// Scrolls the lists to History once they've reloaded with the latest steps.
    func reveal(expandingSessions: Bool = false) async {
        try? await Task.sleep(for: .milliseconds(150))
        for list in lists {
            if expandingSessions {
                SidebarListViews.expandEarlierSessions(in: list)
            }
            SidebarListViews.reveal("History", in: list)
        }
    }
}

/// Edits the harness's photo through the editor's own methods, one of each kind of step.
@MainActor
enum HistoryScript {
    private static var model: EditorModel {
        HarnessEditor.model
    }

    static func waitForPhoto() async {
        while model.info == nil, model.errorMessage == nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    static func playEveryStep() async {
        await waitForPhoto()
        model.setValue(.exposure, 0.35)
        model.setValue(.contrast, 18)
        model.setValue(ColorBand.orange.saturationParameter, -12)
        model.setTreatment(.blackAndWhite)
        model.setTreatment(.color)
        model.setBaseLook(BuiltInBaseLook.vivid.reference)
        model.setWhiteBalanceMode(.daylight)
        model.setValue(.sharpenAmount, 60)
        model.setValue(.vignetteAmount, -20)
        model.setCropAspect(.sixteenByNine)
        model.straighten(from: .zero, to: CGPoint(x: 100, y: 4))
        model.rotate(clockwise: true)
        model.rotate(clockwise: false)
        model.applyDebugCommand("radial", "0.5:0.5:0.2:0.15")
        model.setSliderValue(.localExposure, 0.4)
        if let mask = model.selectedMaskID {
            model.renameMask(mask, to: "Sky")
        }
        model.createSnapshot()
        model.setValue(.highlights, -40)
        if let snapshot = model.snapshots.last {
            model.applySnapshot(snapshot)
        }
        if let recipe = model.recipes.all.first {
            model.applyRecipe(recipe)
        }
        model.copySettings()
        model.reset(.contrast)
        model.pasteSettings()
        model.setPointCurve([CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.58), CurvePoint(x: 1, y: 1)])
        model.resetPointCurve()
        try? await Task.sleep(for: .milliseconds(300))
    }

    static func playFewSteps() async {
        await waitForPhoto()
        model.setValue(.shadows, 25)
        model.setValue(.whites, 10)
        model.setValue(.vibrance, 15)
        model.setValue(.clarity, 12)
        model.undo()
    }

    /// Leaves the photo, so its session is saved, and opens it again.
    static func reopen() async {
        await HarnessEditor.show(.none)
        try? await Task.sleep(for: .milliseconds(300))
        await HarnessEditor.show(.raw)
        await waitForPhoto()
        while model.earlierSessions.isEmpty {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

private struct HistoryScene: View {
    @State private var state = HistorySceneState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button("Start a New Session") {
                    Task {
                        await HistoryScript.reopen()
                        await state.reveal()
                    }
                }
                Button("Play Every Kind of Step") {
                    Task {
                        await HistoryScript.playEveryStep()
                        await state.reveal()
                    }
                }
                Button("Clear History") { HarnessEditor.model.clearHistory() }
                Button("Show History") { Task { await state.reveal(expandingSessions: true) } }
            }
            Text(state.status).font(.callout).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 32) {
                list(width: 250, caption: "250 pt, the sidebar's width")
                list(width: 220, caption: "220 pt, the narrowest sidebar")
            }
        }
        .task { await state.prepare() }
    }

    private func list(width: CGFloat, caption: String) -> some View {
        Specimen(caption: caption) {
            AppKitSpecimen(width: width, revision: state.revision) {
                let list = SidebarListViews.make(model: HarnessEditor.model)
                state.lists.append(list)
                return FixedHeightView(list, height: state.height)
            }
        }
    }
}

private struct HistoryInspector: View {
    @State private var state = HistorySceneState.shared

    var body: some View {
        Form {
            Section("Stage") {
                Knob("height", $state.height, 320 ... 900, step: 10)
                Button("Rebuild Lists") {
                    state.lists = []
                    state.revision += 1
                }
            }
            Section("Editor") {
                LabeledContent("Steps this session", value: "\(HarnessEditor.model.history.count)")
                LabeledContent("Earlier sessions", value: "\(HarnessEditor.model.earlierSessions.count)")
            }
        }
        .formStyle(.grouped)
    }
}
