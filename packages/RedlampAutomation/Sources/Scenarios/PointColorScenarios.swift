#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import RedlampDesign
    import RedlampEngineAPI
    @_spi(Harness) import RedlampUI

    /// Point Color (TON-29): in the Color Mixer, and in masks.
    enum PointColorScenarios {
        static let all: [Scenario] = [colorMixer, masks]

        static let colorMixer = Scenario(
            "develop.point-color",
            "Point Color: a swatch picked on the photo, each of its sliders, Visualize Range, and delete",
            claims: [.feature("develop.point-color")] + ParameterID.pointColorParameters.map { Claim.parameter($0) },
        ) { app in
            try app.openWorking()
            try app.main { $0.pointColorEyedropperActive = true }
            try app.click(.canvas)
            try app.wait("a Point Color swatch") { !$0.recipe.pointColor.isEmpty && !$0.pointColorEyedropperActive }
            app.covered(.feature("develop.point-color"), via: .mouse)
            for parameter in ParameterID.pointColorParameters {
                try app.set(parameter, parameter.spec.defaultValue == 0 ? 40 : 70)
                app.covered(.parameter(parameter), via: .model)
            }
            try app.expectRenders("Visualize Range") {
                try app.main { $0.visualizePointColorRange = true }
            }
            try app.main { model in
                model.visualizePointColorRange = false
                if let swatch = model.selectedPointColorSwatch {
                    model.deletePointColorSwatch(swatch.id)
                }
            }
            try app.wait("the swatch deleted") { $0.recipe.pointColor.isEmpty }
        }

        static let masks = Scenario(
            "masking.point-color",
            "Point Color in a mask: a swatch picked under it, one of the mask's own colour, a slider and Visualize Range",
            claims: [.feature("masking.point-color")],
        ) { app in
            try app.openWorking()
            try app.drawGradient(.radial)
            try app.main { $0.pointColorEyedropperActive = true }
            if try app.focus() {
                try app.click(.canvas)
                app.covered(.feature("masking.point-color"), via: .mouse)
            } else {
                try app.main { $0.samplePointColor(atImage: ImagePoint(x: 0.5, y: 0.5), radius: 0) }
                app.covered(.feature("masking.point-color"), via: .model)
            }
            try app.wait("a swatch in the mask") { $0.selectedMask?.pointColor.isEmpty == false }
            try app.main { $0.addMaskColorSwatch() }
            try app.wait("a swatch of the mask's own colour") {
                $0.selectedMask?.pointColor.contains { $0.color == .mask } == true
            }
            try app.set(.pointColorHueUniformity, 50)
            try app.expectRenders("Visualize Range on the mask's swatch") {
                try app.main { $0.visualizePointColorRange = true }
            }
            try app.main { model in
                model.visualizePointColorRange = false
                model.deleteAllMasks()
            }
        }
    }
#endif
