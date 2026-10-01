import AppKit
import Foundation
import RedlampEngineAPI
import RedlampRecipes

/// The slider bar: arrow-key steps gathered into one history step, the neighbouring
/// sliders, and typed values.
extension CommandPaletteModel {
    func nudge(_ parameter: ParameterID, by direction: Double, _ modifiers: PaletteModifiers) {
        guard isLive(parameter) else {
            report(.unavailable(.slider(parameter)))
            return
        }
        let spec = parameter.spec
        let step = modifiers.contains(.shift) ? spec.step * 10
            : modifiers.contains(.option) ? max(spec.step / 10, Self.resolution(spec)) : spec.step
        if burstParameter != parameter {
            endBurst()
            editor.beginEdit(parameter)
            burstParameter = parameter
        }
        editor.setSliderValue(parameter, spec.clamp(editor.sliderValue(parameter) + direction * step))
        report(.nudged(parameter, to: editor.sliderValue(parameter), modifiers))
        burstEnd?.cancel()
        burstEnd = Task { [weak self] in
            try? await Task.sleep(for: Self.burstGap)
            guard !Task.isCancelled else { return }
            self?.endBurst()
        }
    }

    /// The smallest change the slider's value shows.
    static func resolution(_ spec: ParameterSpec) -> Double {
        switch spec.format {
        case .signedInteger, .integer: 1
        case .kelvin: 50
        case let .signedDecimal(digits), let .decimal(digits): pow(10, -Double(digits))
        }
    }

    /// Records the arrow presses so far as one history step. Undo calls it first, so ⌘Z
    /// right after a burst undoes all of it.
    @_spi(Harness) public func endBurst() {
        burstEnd?.cancel()
        burstEnd = nil
        guard burstParameter != nil else { return }
        burstParameter = nil
        recordingStep { editor.endEdit() }
    }

    func step(from parameter: ParameterID, by offset: Int) {
        let (previous, next) = neighbours(of: parameter)
        guard let target = offset < 0 ? previous : next else { return }
        endBurst()
        replaceTop(.slider(target, typed: ""))
        typedIsInvalid = false
        revealText(selectAll: false)
        if !isSpecimen {
            editor.focusedParameter = target
        }
        report(.steppedSlider(target))
    }

    func commitTyped(_ typed: String, to parameter: ParameterID) {
        guard isLive(parameter), let value = parameter.spec.parse(typed, current: editor.sliderValue(parameter)) else {
            typedIsInvalid = true
            report(.invalidValue(typed))
            if !isSpecimen {
                NSSound.beep()
            }
            return
        }
        endBurst()
        recordingStep { editor.setSliderValue(parameter, value) }
        replaceTop(.slider(parameter, typed: ""))
        revealText(selectAll: false)
        report(.setValue(parameter, editor.sliderValue(parameter)))
    }
}
