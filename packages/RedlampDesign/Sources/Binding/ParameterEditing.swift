import RedlampEngineAPI

/// What a slider needs from the editor. `EditorModel` conforms; the harness supplies a
/// stand-in so components can be exercised without an engine.
///
/// Reads must go through `@Observable` state so `Tracker` sees them.
@MainActor
public protocol ParameterEditing: AnyObject {
    func sliderValue(_ parameter: ParameterID) -> Double
    func setSliderValue(_ parameter: ParameterID, _ value: Double)
    func isEdited(_ parameter: ParameterID) -> Bool
    func resetSlider(_ parameter: ParameterID)
    func resetParameters(_ parameters: [ParameterID], name: String)

    /// A continuous edit (a drag) records one history step when it ends.
    func beginEdit(_ parameter: ParameterID?)
    func endEdit(name: String?)

    /// Option-dragging a tone slider previews clipping, as in Lightroom.
    func setTemporaryClipping(_ on: Bool)

    /// The slider `,` `.` select and `-` `=` nudge; highlighted in the panels.
    var focusedParameter: ParameterID? { get set }
    /// Holding Option turns group titles into "Reset …" buttons.
    var optionKeyHeld: Bool { get }
}
