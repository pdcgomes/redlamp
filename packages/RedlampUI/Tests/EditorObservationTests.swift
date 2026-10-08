import Foundation
import Observation
import RedlampEngineAPI
import Testing
@testable import RedlampUI

/// What the inspector's hosted SwiftUI controls observe (RESP-01): a slider's change leaves
/// the Lens checkboxes, Frame Style, Process and the Base Look menu's embedded look alone, and
/// a change to what one of them shows reaches it.
@MainActor
struct EditorObservationTests {
    enum Control: CaseIterable, CustomTestStringConvertible {
        case chromaticAberration, profileCorrections, frameStyle, processVersion, embeddedBaseLook

        var testDescription: String {
            "\(self)"
        }

        /// What the control reads to show itself.
        @MainActor func read(_ model: EditorModel) {
            switch self {
            case .chromaticAberration: _ = ParameterToggle.isOn(.lensRemoveChromaticAberration, in: model)
            case .profileCorrections: _ = ProfileCorrectionsToggle.isOn(in: model)
            case .frameStyle: _ = FrameStylePicker.style(in: model)
            case .processVersion: _ = ProcessVersion.version(in: model)
            case .embeddedBaseLook: _ = BaseLookMenu.embeddedLook(in: model)
            }
        }

        /// A change to what it shows.
        @MainActor func change(_ model: EditorModel) {
            switch self {
            case .chromaticAberration: model.setValue(.lensRemoveChromaticAberration, 1)
            case .profileCorrections: model.setValue(.lensProfile, model.value(.lensProfile) > 0.5 ? 0 : 1)
            case .frameStyle: model.setValue(.frameStyle, 1)
            case .processVersion, .embeddedBaseLook: model.setProcessVersion(1)
            }
        }
    }

    private final class Flag: @unchecked Sendable {
        var raised = false
    }

    private func openEditor() async throws -> (EditorModel, () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let engine = StubEngine()
        engine.embeddedBaseLook = (BaseLookReference(id: "local/embedded/stub", name: "Camera Profile"), 5)
        engine.lensCorrection = LensPanelTextTests.correction(.dng)
        let model = EditorModel(engine: engine)
        model.select(folder.appending(path: "IMG_0001.ARW"))
        for _ in 0 ..< 200 where model.info == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(model.info != nil)
        return (model, { try? FileManager.default.removeItem(at: folder) })
    }

    /// Whether `change` invalidates what `control` read.
    private func invalidates(_ control: Control, in model: EditorModel, _ change: () -> Void) -> Bool {
        let flag = Flag()
        withObservationTracking { control.read(model) } onChange: { flag.raised = true }
        change()
        return flag.raised
    }

    @Test(arguments: Control.allCases)
    func `a slider's change leaves a hosted control alone`(control: Control) async throws {
        let (model, cleanup) = try await openEditor()
        defer { cleanup() }
        let invalidated = invalidates(control, in: model) { model.setValue(.exposure, 1) }
        withKnownIssue("RESP-01: the hosted controls read the whole edit") {
            #expect(!invalidated)
        }
    }

    @Test(arguments: Control.allCases)
    func `a change to what a hosted control shows reaches it`(control: Control) async throws {
        let (model, cleanup) = try await openEditor()
        defer { cleanup() }
        #expect(invalidates(control, in: model) { control.change(model) })
    }
}
