import AppKit
import Observation
import RedlampEngineAPI
@_spi(Harness) import RedlampUI
import SwiftUI

/// The Masks panel (`docs/plans/2026-10-07-masks-panel-design.md`): Live on the real editor with
/// the design's checklist, and States.
extension HarnessScene {
    static var masksPanel: HarnessScene {
        var scene = HarnessScene(
            id: "masks-panel",
            title: "Live",
            symbol: "circle.dashed.inset.filled",
            synopsis: "The new Masks panel beside the sample photo on the real editor; the checklist holds "
                + "the design's fourteen tasks, ticked as the edit shows them done",
            section: .masks,
        ) {
            MasksLiveScene()
        } inspector: {
            MasksChecklist()
        }
        scene.fillsStage = true
        return scene
    }

    static var masksPanelStates: HarnessScene {
        HarnessScene(
            id: "masks-panel-states",
            title: "States",
            symbol: "square.grid.2x2",
            synopsis: "The picker for a new mask and for a mask's component, and the People and Landscape pickers",
            section: .masks,
        ) {
            MasksStatesScene()
        }
    }
}

// MARK: - Live

private struct MasksLiveScene: View {
    @State private var theme = ThemeSettings(defaults: UserDefaults(suiteName: "redlamp-harness-masks") ?? .standard)

    var body: some View {
        let model = HarnessEditor.model
        HStack(spacing: 0) {
            CanvasArea(onOpen: {})
            ScrollView {
                MasksPanel()
            }
            .frame(width: 316)
        }
        .environment(model)
        .environment(theme)
        .onAppear { model.activeTool = .masking }
    }
}

// MARK: - Checklist

/// The audit's fourteen tasks, each with the steps the design gives it. Those the edit itself
/// shows done tick on their own; tick the rest as they're tried.
private struct MasksChecklist: View {
    @Bindable private var state = ChecklistState.shared

    var body: some View {
        let model = HarnessEditor.model
        Form {
            Section(
                "Tasks (\(MasksTask.all.count(where: { state.isDone($0, model: model) })) of \(MasksTask.all.count))",
            ) {
                ForEach(MasksTask.all) { task in
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(isOn: Binding(
                            get: { state.isDone(task, model: model) },
                            set: { state.ticked[task.id] = $0 },
                        )) {
                            Text("\(task.id). \(task.title)")
                        }
                        Text(task.steps)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let row = task.row {
                            Text(row)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            Section("Conditions") {
                Button("Delete All Masks") { model.deleteAllMasks() }
                    .disabled(model.masks.isEmpty)
                Button("Untick Everything") { state.ticked = [:] }
            }
        }
        .formStyle(.grouped)
    }
}

@MainActor
@Observable
private final class ChecklistState {
    static let shared = ChecklistState()
    var ticked: [Int: Bool] = [:]

    func isDone(_ task: MasksTask, model: EditorModel) -> Bool {
        ticked[task.id] ?? task.shown?(model.masks) ?? false
    }
}

private struct MasksTask: Identifiable, Sendable {
    let id: Int
    let title: String
    /// The design's steps.
    let steps: String
    /// The row that brings it, while it isn't built yet.
    var row: String?
    /// Whether the edit shows it done.
    var shown: (@Sendable ([MaskLayer]) -> Bool)?

    static let all: [MasksTask] = [
        MasksTask(
            id: 1, title: "Darken a sky", steps: "New Mask ▸ Sky, then Exposure",
            shown: { masks in masks.contains { has(.sky, in: $0) && $0[.localExposure] < 0 } },
        ),
        MasksTask(
            id: 2, title: "Brighten one face of three", steps: "New Mask ▸ People: tick one person and Face Skin",
            shown: { masks in
                masks.contains { mask in
                    mask.components.count(where: { person(in: $0)?.part == .faceSkin }) == 1
                        && mask[.localExposure] > 0
                }
            },
        ),
        MasksTask(
            id: 3, title: "Take a person out of a sky", steps: "Select the sky, Subtract ▸ People",
            shown: { masks in
                masks.contains { mask in
                    has(.sky, in: mask) && mask.components
                        .contains { $0.operation == .subtract && $0.shape.kind == .people }
                }
            },
        ),
        MasksTask(
            id: 4, title: "Fix a missed strand", steps: "Refine Edge Brush under the AI component, paint",
            shown: { masks in
                masks.contains { mask in
                    mask.components.contains { component in
                        if case let .ai(ai) = component.shape {
                            !(ai.refinements ?? []).isEmpty
                        } else {
                            false
                        }
                    }
                }
            },
        ),
        MasksTask(
            id: 5, title: "Find which mask changed an area", steps: "Pointer over the rows; pins inside each mask",
        ),
        MasksTask(id: 6, title: "Change a component to Subtract", steps: "Click its operation icon"),
        MasksTask(id: 7, title: "Invert a mask", steps: "Invert at the top of the mask"),
        MasksTask(
            id: 8, title: "Make a mask from an existing one", steps: "Add ▸ Existing Mask in the picker, or Duplicate",
            shown: { masks in
                masks.contains { mask in
                    mask.components.contains {
                        if case .maskReference = $0.shape {
                            true
                        } else {
                            false
                        }
                    }
                }
            },
        ),
        MasksTask(id: 9, title: "Apply a mask preset to several photos", steps: "Presets with the photos selected"),
        MasksTask(
            id: 10, title: "Hide every mask but one", steps: "Option-click its eye",
            shown: { masks in masks.count > 1 && masks.count(where: \.isVisible) == 1 },
        ),
        MasksTask(
            id: 11, title: "Brush with Auto Mask", steps: "New Mask ▸ Brush, Auto Mask on, paint",
            shown: { masks in
                masks.contains { mask in
                    mask.components.contains {
                        if case let .brush(brush) = $0.shape {
                            brush.strokes.contains(where: \.autoMask)
                        } else {
                            false
                        }
                    }
                }
            },
        ),
        MasksTask(id: 12, title: "Undo a wrong click", steps: "⌘Z"),
        MasksTask(
            id: 13, title: "A mask for each person", steps: "New Mask ▸ People: Separate masks",
            shown: { masks in
                let people = masks.compactMap { mask -> Int? in
                    let instances = Set(mask.components.compactMap { person(in: $0)?.instance })
                    return instances.count == 1 ? instances.first : nil
                }
                return Set(people).count > 1
            },
        ),
        MasksTask(
            id: 14, title: "Water and vegetation", steps: "New Mask ▸ Landscape: tick both",
            shown: { masks in
                Set(masks.flatMap(\.components).compactMap(landscape(in:))).isSuperset(of: [.water, .vegetation])
            },
        ),
    ]

    private static func has(_ kind: MaskKind, in mask: MaskLayer) -> Bool {
        mask.components.contains { $0.shape.kind == kind }
    }

    /// A Landscape component's class.
    private static func landscape(in component: MaskComponent) -> LandscapeClass? {
        guard case let .ai(ai) = component.shape, ai.kind == .landscape else { return nil }
        return ai.part.flatMap(LandscapeClass.init(rawValue:))
    }

    /// A People component's part and person.
    private static func person(in component: MaskComponent) -> (part: PersonPart, instance: Int?)? {
        guard case let .ai(ai) = component.shape, ai.kind == .people else { return nil }
        return (ai.part.flatMap(PersonPart.init(rawValue:)) ?? .entirePerson, ai.instance)
    }
}

// MARK: - States

private struct MasksStatesScene: View {
    var body: some View {
        let model = HarnessEditor.model
        HStack(alignment: .top, spacing: 24) {
            specimen("New Mask") {
                MaskPicker(mode: .new)
            }
            if let mask = model.maskOutlines.first {
                specimen("Subtract from a mask") {
                    MaskPicker(mode: .component(.subtract, target: mask.id))
                }
            } else {
                specimen("Subtract from a mask") {
                    Text("Make a mask in Live to see the component picker.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 300)
                }
            }
            VStack(alignment: .leading, spacing: 24) {
                specimen("People, three found") {
                    PeoplePickerSpecimen(people: 3)
                }
                specimen("People, nobody found") {
                    PeoplePickerSpecimen(people: 0)
                }
            }
            VStack(alignment: .leading, spacing: 24) {
                specimen("Landscape, four regions found") {
                    LandscapePickerSpecimen()
                }
                specimen("Landscape, none found") {
                    LandscapePickerSpecimen(found: false)
                }
            }
        }
        .environment(model)
    }

    private func specimen(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
                .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
        }
    }
}
