import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampRecipes

extension LightroomImportReport {
    func outcome(_ setting: String) -> Outcome? {
        entries.first { $0.setting == setting }?.outcome
    }

    func note(_ setting: String) -> String? {
        entries.first { $0.setting == setting }?.note
    }
}

/// A synthetic preset per Lightroom panel, in both RDF forms, checked for its values and the
/// report's outcomes.
struct LightroomPresetMappingTests {
    private typealias Note = LightroomPreset.Note

    private func convert(
        _ settings: [(String, String)],
        form: PresetXMP.Form = .attributes,
        lists: [(String, [String])] = [],
        body: String = "",
    ) throws -> LightroomPresetImport {
        try LightroomPreset.convert(PresetXMP.preset(settings, form: form, lists: lists, body: body))
    }

    @Test(arguments: PresetXMP.Form.allCases)
    func `the Basic panel's tone and presence map one to one`(form: PresetXMP.Form) throws {
        let imported = try convert([
            ("ProcessVersion", "15.4"), ("Exposure2012", "+0.65"), ("Contrast2012", "+12"),
            ("Highlights2012", "-45"), ("Shadows2012", "+38"), ("Whites2012", "+7"), ("Blacks2012", "-15"),
            ("Texture", "+10"), ("Clarity2012", "+8"), ("Dehaze", "+4.5"), ("Vibrance", "+20"), ("Saturation", "-5"),
        ], form: form)
        #expect(imported.recipe.settings.values == [
            .exposure: 0.65, .contrast: 12, .highlights: -45, .shadows: 38, .whites: 7, .blacks: -15,
            .texture: 10, .clarity: 8, .dehaze: 4.5, .vibrance: 20, .saturation: -5,
        ])
        #expect(imported.recipe.includes == [.tone, .presence])
        #expect(imported.report.entries.map(\.setting) == [
            "Exposure2012", "Contrast2012", "Highlights2012", "Shadows2012", "Whites2012", "Blacks2012", "Texture",
            "Clarity2012", "Dehaze", "Vibrance", "Saturation",
        ])
        #expect(imported.report.entries.allSatisfy { $0.outcome == .mapped && $0.note == nil })
    }

    @Test(arguments: PresetXMP.Form.allCases)
    func `a raw preset's kelvin is a custom white balance, listed even at the default`(form: PresetXMP.Form) throws {
        let imported = try convert([("WhiteBalance", "Custom"), ("Temperature", "5500"), ("Tint", "+12")], form: form)
        #expect(imported.recipe.settings.whiteBalanceMode == .custom)
        #expect(imported.recipe.settings.values == [.temperature: 5500, .tint: 12])
        #expect(imported.recipe.includes == [.whiteBalance])
        #expect(imported.report.entries(.mapped).map(\.setting) == ["WhiteBalance", "Temperature", "Tint"])

        var photo = EditRecipe()
        photo[.temperature] = 3200
        let applied = imported.recipe.apply(to: photo)
        #expect(abs(applied[.temperature] - 5500) < 1e-6)
        #expect(applied[.tint] == 12)
        #expect(applied.whiteBalanceMode == .custom)
    }

    @Test(arguments: [
        ("As Shot", WhiteBalanceMode.asShot),
        ("Auto", .auto),
        ("Daylight", .daylight),
        ("Shade", .shade),
    ])
    func `a named white balance sets the mode, which decides the values`(name: String, mode: WhiteBalanceMode) throws {
        let imported = try convert([
            ("WhiteBalance", name), ("Temperature", "5500"), ("Tint", "+10"), ("IncrementalTemperature", "+5"),
        ])
        #expect(imported.recipe.settings.whiteBalanceMode == mode)
        #expect(imported.recipe.settings.values.isEmpty)
        #expect(imported.recipe.includes == [.whiteBalance])
        #expect(imported.report.outcome("WhiteBalance") == .mapped)
        for setting in ["Temperature", "Tint", "IncrementalTemperature"] {
            #expect(imported.report.outcome(setting) == .ignored)
            #expect(imported.report.note(setting) == "The white balance, \(mode.name), sets it.")
        }
    }

    @Test
    func `an unknown white balance is reported`() throws {
        let imported = try convert([("WhiteBalance", "Underwater"), ("Exposure2012", "+0.20")])
        #expect(imported.recipe.settings.whiteBalanceMode == nil)
        #expect(imported.report.note("WhiteBalance") == "Lightroom's white balance “Underwater” isn't one Redlamp has.")
    }

    @Test(arguments: PresetXMP.Form.allCases)
    func `a rendered photo's relative white balance becomes red and blue shifts`(form: PresetXMP.Form) throws {
        let imported = try convert(
            [("WhiteBalance", "Custom"), ("IncrementalTemperature", "+20"), ("IncrementalTint", "-5")], form: form,
        )
        #expect(imported.recipe.settings.values == [.wbShiftRed: 15, .wbShiftBlue: -25])
        #expect(imported.recipe.settings.whiteBalanceMode == nil)
        #expect(imported.recipe.includes == [.whiteBalance])
        #expect(imported.report.entries.allSatisfy { $0.outcome == .approximated })
        #expect(imported.report.note("IncrementalTemperature") == Note.incremental)
        #expect(imported.report.note("WhiteBalance") == Note.incrementalCustom)

        // Shifts alone leave the photo's own white balance as it is.
        var photo = EditRecipe()
        photo[.temperature] = 4000
        photo[.tint] = 5
        let applied = imported.recipe.apply(to: photo)
        #expect(applied[.temperature] == 4000)
        #expect(applied[.tint] == 5)
        #expect(applied[.wbShiftRed] == 15)
    }

    @Test
    func `relative white balance beyond the shifts' range is clamped, and kelvin wins over it`() throws {
        let strong = try convert([("IncrementalTemperature", "+90"), ("IncrementalTint", "+40")])
        #expect(strong.recipe.settings.values == [.wbShiftRed: 100, .wbShiftBlue: -50])
        #expect(strong.report.note("IncrementalTint") == Note.incremental + " " + Note.clamped("±100"))

        let both = try convert([("Temperature", "5000"), ("Tint", "+3"), ("IncrementalTemperature", "+20")])
        #expect(both.recipe.settings.values == [.temperature: 5000, .tint: 3])
        #expect(both.recipe.settings.whiteBalanceMode == .custom)
        #expect(both.report.outcome("IncrementalTemperature") == .ignored)
        #expect(both.report.note("IncrementalTemperature") == Note.kelvinUsed)
    }

    @Test(arguments: PresetXMP.Form.allCases)
    func `the tone curve keeps its points, parametric sliders and straight channel curves`(form: PresetXMP
        .Form) throws {
        let imported = try convert([
            ("ParametricShadows", "+10"), ("ParametricDarks", "-5"), ("ParametricLights", "+15"),
            ("ParametricHighlights", "-20"), ("ParametricShadowSplit", "30"), ("ParametricMidtoneSplit", "55"),
            ("ParametricHighlightSplit", "95"), ("ToneCurveName2012", "Custom"),
        ], form: form, lists: [
            ("ToneCurvePV2012", ["0, 20", "64, 56", "192, 200", "255, 245"]),
            ("ToneCurvePV2012Red", ["0, 0", "255, 255"]),
            ("ToneCurvePV2012Green", ["0, 0", "128, 140", "255, 255"]),
            ("ToneCurvePV2012Blue", ["0, 0", "255, 255"]),
        ])
        #expect(imported.recipe.settings.pointCurve == [
            CurvePoint(x: 0, y: 20 / 255), CurvePoint(x: 64 / 255, y: 56 / 255),
            CurvePoint(x: 192 / 255, y: 200 / 255), CurvePoint(x: 1, y: 245 / 255),
        ])
        #expect(imported.recipe.settings.values == [
            .curveShadows: 10, .curveDarks: -5, .curveLights: 15, .curveHighlights: -20, .curveSplitShadows: 30,
            .curveSplitMidtones: 55, .curveSplitHighlights: 90,
        ])
        #expect(imported.recipe.includes == [.toneCurve])
        let report = imported.report
        #expect(report.outcome("ToneCurvePV2012") == .mapped)
        #expect(report.outcome("ToneCurvePV2012Red") == .mapped)
        #expect(report.note("ToneCurvePV2012Red") == Note.straightChannelCurve)
        #expect(report.outcome("ToneCurvePV2012Green") == .ignored)
        #expect(report.note("ToneCurvePV2012Green") == Note.channelCurve)
        #expect(report.outcome("ParametricHighlightSplit") == .approximated)
        #expect(report.note("ParametricHighlightSplit") == Note.clamped("90"))
        #expect(report.outcome("ToneCurveName2012") == nil)
    }

    @Test
    func `a straight point curve leaves Redlamp's straight, and an unreadable one is reported`() throws {
        let straight = try convert([], lists: [("ToneCurvePV2012", ["0, 0", "128, 128", "255, 255"])])
        #expect(straight.recipe.settings.pointCurve == nil)
        #expect(straight.recipe.includes == [.toneCurve])
        #expect(straight.report.outcome("ToneCurvePV2012") == .mapped)

        let tooMany = (0 ... 64).map { "\($0 * 3), \($0 * 3)" }
        for points in [["0, 0", "300, 255"], ["128, 128"], ["0, 0", "dark"], tooMany] {
            let imported = try convert([("Exposure2012", "0")], lists: [("ToneCurvePV2012", points)])
            #expect(imported.report.outcome("ToneCurvePV2012") == .ignored)
            #expect(imported.recipe.includes == [.tone])
        }
    }

    @Test(arguments: PresetXMP.Form.allCases)
    func `the Color Mixer maps each band's hue, saturation and luminance`(form: PresetXMP.Form) throws {
        let settings = ColorBand.allCases.flatMap { band in
            let step = band.rawValue + 1
            return [
                ("HueAdjustment\(band.name)", "+\(step)"), ("SaturationAdjustment\(band.name)", "-\(step)"),
                ("LuminanceAdjustment\(band.name)", "+\(10 * step)"),
            ]
        }
        let imported = try convert(settings, form: form)
        for band in ColorBand.allCases {
            let step = Double(band.rawValue + 1)
            #expect(imported.recipe.settings[band.hueParameter] == step)
            #expect(imported.recipe.settings[band.saturationParameter] == -step)
            #expect(imported.recipe.settings[band.luminanceParameter] == 10 * step)
        }
        #expect(imported.recipe.includes == [.colorMixer])
        #expect(imported.report.entries.count == 24)
        #expect(imported.report.entries.allSatisfy { $0.outcome == .mapped })
    }

    @Test(arguments: PresetXMP.Form.allCases)
    func `black and white takes the B&W mix as the Color Mixer's luminance`(form: PresetXMP.Form) throws {
        let imported = try convert([
            ("ConvertToGrayscale", "True"), ("GrayMixerRed", "-10"), ("GrayMixerBlue", "-40"),
            ("LuminanceAdjustmentRed", "+30"), ("HueAdjustmentRed", "+5"),
        ], form: form)
        #expect(imported.recipe.settings.treatment == .blackAndWhite)
        #expect(imported.recipe.settings.values == [.luminanceRed: -10, .luminanceBlue: -40, .hueRed: 5])
        #expect(imported.recipe.includes == [.treatment, .colorMixer])
        #expect(imported.report.outcome("ConvertToGrayscale") == .mapped)
        #expect(imported.report.outcome("GrayMixerBlue") == .approximated)
        #expect(imported.report.note("GrayMixerBlue") == Note.grayMix)
        #expect(imported.report.outcome("LuminanceAdjustmentRed") == .ignored)
        #expect(imported.report.note("LuminanceAdjustmentRed") == Note.luminanceInBlackAndWhite)
    }

    @Test
    func `in colour the B&W mix is reported and HSL luminance maps`() throws {
        let imported = try convert([
            ("ConvertToGrayscale", "False"), ("GrayMixerRed", "-10"), ("LuminanceAdjustmentRed", "+30"),
        ])
        #expect(imported.recipe.settings.treatment == .color)
        #expect(imported.recipe.settings.values == [.luminanceRed: 30])
        #expect(imported.report.outcome("GrayMixerRed") == .ignored)
        #expect(imported.report.note("GrayMixerRed") == Note.grayMixInColor)
    }

    @Test(arguments: PresetXMP.Form.allCases)
    func `Color Grading maps every wheel, Blending and Balance`(form: PresetXMP.Form) throws {
        let imported = try convert([
            ("SplitToningShadowHue", "220"), ("SplitToningShadowSaturation", "15"), ("ColorGradeShadowLum", "-5"),
            ("ColorGradeMidtoneHue", "30"), ("ColorGradeMidtoneSat", "8"), ("ColorGradeMidtoneLum", "+3"),
            ("SplitToningHighlightHue", "45"), ("SplitToningHighlightSaturation", "20"),
            ("ColorGradeHighlightLum", "+4"), ("ColorGradeGlobalHue", "200"), ("ColorGradeGlobalSat", "6"),
            ("ColorGradeGlobalLum", "-2"), ("ColorGradeBlending", "70"), ("SplitToningBalance", "-25"),
        ], form: form)
        #expect(imported.recipe.settings.values == [
            .gradeShadowsHue: 220, .gradeShadowsSaturation: 15, .gradeShadowsLuminance: -5,
            .gradeMidtonesHue: 30, .gradeMidtonesSaturation: 8, .gradeMidtonesLuminance: 3,
            .gradeHighlightsHue: 45, .gradeHighlightsSaturation: 20, .gradeHighlightsLuminance: 4,
            .gradeGlobalHue: 200, .gradeGlobalSaturation: 6, .gradeGlobalLuminance: -2, .gradeBlending: 70,
            .gradeBalance: -25,
        ])
        #expect(imported.recipe.includes == [.colorGrading])
        #expect(imported.report.entries.count == 14)
        #expect(imported.report.entries.allSatisfy { $0.outcome == .mapped })
    }

    @Test
    func `a Split Toning preset renders with Blending at 100, as Lightroom renders one`() throws {
        let imported = try convert([
            ("SplitToningShadowHue", "220"), ("SplitToningShadowSaturation", "15"), ("SplitToningHighlightHue", "45"),
            ("SplitToningHighlightSaturation", "20"), ("SplitToningBalance", "+10"),
        ])
        #expect(imported.recipe.settings[.gradeBlending] == 100)
        #expect(imported.report.entries.map(\.setting) == [
            "SplitToningShadowHue", "SplitToningShadowSaturation", "SplitToningHighlightHue",
            "SplitToningHighlightSaturation", "SplitToningBalance", "ColorGradeBlending",
        ])
        #expect(imported.report.note("ColorGradeBlending") == Note.splitToningBlending)
    }

    @Test(arguments: PresetXMP.Form.allCases)
    func `the Detail panel maps one to one`(form: PresetXMP.Form) throws {
        let imported = try convert([
            ("Sharpness", "60"), ("SharpenRadius", "+1.2"), ("SharpenDetail", "30"), ("SharpenEdgeMasking", "20"),
            ("LuminanceSmoothing", "15"), ("LuminanceNoiseReductionDetail", "60"),
            ("LuminanceNoiseReductionContrast", "10"), ("ColorNoiseReduction", "30"),
            ("ColorNoiseReductionDetail", "55"), ("ColorNoiseReductionSmoothness", "65"),
        ], form: form)
        #expect(imported.recipe.settings.values == [
            .sharpenAmount: 60, .sharpenRadius: 1.2, .sharpenDetail: 30, .sharpenMasking: 20, .noiseLuminance: 15,
            .noiseLuminanceDetail: 60, .noiseLuminanceContrast: 10, .noiseColor: 30, .noiseColorDetail: 55,
            .noiseColorSmoothness: 65,
        ])
        #expect(imported.recipe.includes == [.detail])
        #expect(imported.report.entries.allSatisfy { $0.outcome == .mapped })
    }

    @Test(arguments: PresetXMP.Form.allCases)
    func `Effects map the post-crop vignette and grain`(form: PresetXMP.Form) throws {
        let imported = try convert([
            ("PostCropVignetteAmount", "-25"), ("PostCropVignetteMidpoint", "40"), ("PostCropVignetteRoundness", "+10"),
            ("PostCropVignetteFeather", "60"), ("PostCropVignetteHighlightContrast", "20"),
            ("PostCropVignetteStyle", "1"), ("GrainAmount", "25"), ("GrainSize", "30"), ("GrainFrequency", "60"),
        ], form: form)
        #expect(imported.recipe.settings.values == [
            .vignetteAmount: -25, .vignetteMidpoint: 40, .vignetteRoundness: 10, .vignetteFeather: 60,
            .vignetteHighlights: 20, .grainAmount: 25, .grainSize: 30, .grainRoughness: 60,
        ])
        #expect(imported.recipe.includes == [.effects])
        #expect(imported.report.entries.allSatisfy { $0.outcome == .mapped })
    }

    @Test(arguments: ["2", "3"])
    func `vignette styles other than Highlight Priority are approximated`(style: String) throws {
        let imported = try convert([("PostCropVignetteAmount", "-25"), ("PostCropVignetteStyle", style)])
        #expect(imported.report.outcome("PostCropVignetteStyle") == .approximated)
        #expect(imported.report.note("PostCropVignetteStyle") == Note.vignetteStyle)
        #expect(imported.recipe.includes == [.effects])
    }

    @Test(arguments: PresetXMP.Form.allCases)
    func `lens corrections, Transform and calibration stay with each photo`(form: PresetXMP.Form) throws {
        let imported = try convert([
            ("LensProfileEnable", "1"), ("LensProfileSetup", "LensDefaults"), ("LensProfileName", "Example 35mm"),
            ("LensProfileDistortionScale", "100"), ("LensProfileDigest", "0A1B"), ("AutoLateralCA", "1"),
            ("DefringePurpleAmount", "2"), ("LensManualDistortionAmount", "-5"), ("VignetteAmount", "+10"),
            ("PerspectiveUpright", "1"), ("UprightVersion", "151388160"), ("UprightTransform_0", "1,0,0,0,1,0,0,0,1"),
            ("PerspectiveVertical", "-10"), ("PerspectiveScale", "100"), ("ShadowTint", "+5"), ("RedHue", "+10"),
            ("BlueSaturation", "+30"),
        ], form: form)
        #expect(imported.recipe.settings.values.isEmpty)
        #expect(imported.recipe.includes.isEmpty)
        #expect(imported.report.entries.allSatisfy { $0.outcome == .ignored })
        #expect(imported.report.note("LensProfileEnable") == Note.lensProfileOn)
        for setting in [
            "LensProfileSetup",
            "LensProfileName",
            "LensProfileDistortionScale",
            "AutoLateralCA",
            "DefringePurpleAmount",
            "LensManualDistortionAmount",
            "VignetteAmount",
        ] {
            #expect(imported.report.note(setting) == Note.lens)
        }
        #expect(imported.report.note("PerspectiveUpright") == Note.upright)
        #expect(imported.report.note("UprightVersion") == Note.upright)
        #expect(imported.report.note("PerspectiveVertical") == Note.transform)
        #expect(imported.report.note("RedHue") == Note.calibration)
        #expect(imported.report.outcome("LensProfileDigest") == nil)
        #expect(imported.report.outcome("UprightTransform_0") == nil)

        let off = try convert([("LensProfileEnable", "0"), ("Exposure2012", "0")])
        #expect(off.report.note("LensProfileEnable") == Note.lensProfileOff)
    }

    @Test
    func `profiles, masks, spots and features Redlamp lacks are reported`() throws {
        let imported = try convert([
            ("CameraProfile", "Camera Standard"), ("AutoTone", "True"), ("HDREditMode", "1"), ("SDRBrightness", "+10"),
            ("CameraModelRestriction", "Example Camera"), ("OverrideLookVignette", "True"),
        ], body: """
           <crs:Look>
            <rdf:Description crs:Name="Studio Look" crs:Amount="1"/>
           </crs:Look>
           <crs:MaskGroupBasedCorrections>
            <rdf:Seq><rdf:li rdf:parseType="Resource"><crs:What>Correction</crs:What></rdf:li></rdf:Seq>
           </crs:MaskGroupBasedCorrections>
           <crs:RetouchAreas>
            <rdf:Seq><rdf:li rdf:parseType="Resource"><crs:SpotType>heal</crs:SpotType></rdf:li></rdf:Seq>
           </crs:RetouchAreas>
           <crs:RedEyeInfo><rdf:Seq><rdf:li>0, 0.5, 0.5</rdf:li></rdf:Seq></crs:RedEyeInfo>
           <crs:LensBlur rdf:parseType="Resource"><crs:Active>true</crs:Active></crs:LensBlur>
           <crs:PointColors><rdf:Seq><rdf:li>0.5, 0.2</rdf:li></rdf:Seq></crs:PointColors>
        """)
        let report = imported.report
        #expect(imported.recipe.includes.isEmpty)
        #expect(report.entries.allSatisfy { $0.outcome == .ignored })
        #expect(report.note("Look") == Note.look("Studio Look"))
        #expect(report.note("CameraProfile") == Note.profile)
        #expect(report.note("OverrideLookVignette") == Note.profile)
        #expect(report.note("AutoTone") == Note.auto)
        #expect(report.note("HDREditMode") == Note.hdr)
        #expect(report.note("SDRBrightness") == Note.hdr)
        #expect(report.note("CameraModelRestriction") == Note.camera)
        #expect(report.note("MaskGroupBasedCorrections") == Note.masks)
        #expect(report.note("RetouchAreas") == Note.spots)
        #expect(report.note("RedEyeInfo") == Note.redEye)
        #expect(report.note("LensBlur") == Note.lensBlur)
        #expect(report.note("PointColors") == Note.pointColor)
    }

    @Test
    func `features that are off, and blank fields, aren't reported`() throws {
        let imported = try convert([
            ("AutoTone", "False"), ("HDREditMode", "0"), ("SDRBrightness", "0"), ("OverrideLookVignette", "False"),
            ("CameraModelRestriction", ""), ("Exposure2012", "+0.50"),
        ])
        #expect(imported.report.entries.map(\.setting) == ["Exposure2012"])
    }

    @Test
    func `unknown settings, values out of range and unreadable values are reported`() throws {
        let imported = try convert([
            ("Exposure2012", "+6.50"), ("Contrast2012", "lots"), ("FutureSlider", "+5"), ("Temperature", "60000"),
        ])
        let report = imported.report
        #expect(imported.recipe.settings.values == [.exposure: 5, .temperature: 50000])
        #expect(report.outcome("Exposure2012") == .approximated)
        #expect(report.note("Exposure2012") == Note.clamped("+5.00"))
        #expect(report.note("Temperature") == Note.clamped("50000"))
        #expect(report.outcome("Contrast2012") == .ignored)
        #expect(report.note("Contrast2012") == Note.unreadable)
        #expect(report.entries.last == LightroomImportReport.Entry(
            setting: "FutureSlider", outcome: .ignored, note: Note.unknown,
        ))
    }

    @Test
    func `a preset includes only the groups it carries, and leaves the rest of a photo alone`() throws {
        let imported = try convert([("Exposure2012", "+1.00"), ("GrainAmount", "20"), ("RedHue", "+10")])
        #expect(imported.recipe.includes == [.tone, .effects])

        var photo = EditRecipe()
        photo.treatment = .blackAndWhite
        photo[.temperature] = 4000
        photo[.contrast] = 30
        photo[.clarity] = 25
        photo[.saturationRed] = 10
        photo[.vignetteAmount] = -10
        photo[.sharpenAmount] = 70
        photo[.calibrationRedHue] = -20
        let applied = imported.recipe.apply(to: photo)
        #expect(applied[.exposure] == 1)
        #expect(applied[.contrast] == 0)
        #expect(applied[.grainAmount] == 20)
        #expect(applied[.vignetteAmount] == 0)
        #expect(applied[.clarity] == 25)
        #expect(applied[.saturationRed] == 10)
        #expect(applied[.sharpenAmount] == 70)
        #expect(applied[.calibrationRedHue] == -20)
        #expect(applied[.temperature] == 4000)
        #expect(applied.treatment == .blackAndWhite)
    }

    @Test
    func `the recipe takes the preset's name, group and description, or the name it's given`() throws {
        let data = PresetXMP.preset([("Vibrance", "+10")], name: "Golden Hour", group: "Warm", body: """
           <crs:Description>
            <rdf:Alt><rdf:li xml:lang="x-default">Warm light, soft shadows.</rdf:li></rdf:Alt>
           </crs:Description>
        """)
        let imported = try LightroomPreset.convert(data)
        #expect(imported.recipe.name == "Golden Hour")
        #expect(imported.recipe.group == "Warm")
        #expect(imported.recipe.summary == "Warm light, soft shadows.")
        #expect(imported.recipe.tags == ["lightroom"])
        #expect(imported.recipe.isLocal)
        #expect(RecipeNamespace.isValid(imported.recipe.id))
        #expect(imported.recipe.processVersion == EditRecipe.currentProcessVersion)
        #expect(try LightroomPreset.convert(data, name: "Renamed").recipe.name == "Renamed")

        let anonymous = try LightroomPreset.convert(PresetXMP.preset([("Vibrance", "+10")], name: nil))
        #expect(anonymous.recipe.name == "Lightroom Preset")
        #expect(anonymous.recipe.group == "Imported")
        #expect(anonymous.recipe.summary == nil)
    }

    @Test
    func `the mapping table names each Lightroom setting once, and only recipe parameters`() {
        let keys = LightroomPreset.rules.map(\.key)
        #expect(Set(keys).count == keys.count)
        var parameters: [ParameterID] = []
        for (key, rule) in LightroomPreset.rules {
            guard case let .parameter(parameter) = rule else { continue }
            #expect(RecipeSettingGroup(parameter: parameter) != nil, "\(key) maps to \(parameter.rawValue)")
            parameters.append(parameter)
        }
        #expect(Set(parameters).count == parameters.count)
    }
}

/// A preset laid out as Lightroom Classic writes one, with every panel, a profile, a mask and the
/// metadata around them; the values are made up.
struct LightroomPresetRealWorldTests {
    static let preset = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0-c000 1.000000, 0000/00/00-00:00:00        ">
     <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about=""
        xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
       crs:PresetType="Normal"
       crs:Cluster=""
       crs:UUID="5C2A7E1B9D0F4E3A8B6C1D2E3F4A5B6C"
       crs:SupportsAmount="True"
       crs:SupportsColor="True"
       crs:SupportsMonochrome="True"
       crs:SupportsHighDynamicRange="True"
       crs:SupportsNormalDynamicRange="True"
       crs:SupportsSceneReferred="True"
       crs:SupportsOutputReferred="True"
       crs:CameraModelRestriction=""
       crs:Copyright=""
       crs:ContactInfo=""
       crs:Version="15.4"
       crs:ProcessVersion="15.4"
       crs:WhiteBalance="Custom"
       crs:Temperature="5900"
       crs:Tint="+8"
       crs:Exposure2012="+0.35"
       crs:Contrast2012="-12"
       crs:Highlights2012="-60"
       crs:Shadows2012="+45"
       crs:Whites2012="+10"
       crs:Blacks2012="-20"
       crs:Texture="+8"
       crs:Clarity2012="+6"
       crs:Dehaze="+3"
       crs:Vibrance="+15"
       crs:Saturation="-8"
       crs:ParametricShadows="0"
       crs:ParametricDarks="+6"
       crs:ParametricLights="-4"
       crs:ParametricHighlights="-10"
       crs:ParametricShadowSplit="25"
       crs:ParametricMidtoneSplit="50"
       crs:ParametricHighlightSplit="75"
       crs:Sharpness="40"
       crs:SharpenRadius="+1.0"
       crs:SharpenDetail="25"
       crs:SharpenEdgeMasking="0"
       crs:LuminanceSmoothing="0"
       crs:ColorNoiseReduction="25"
       crs:ColorNoiseReductionDetail="50"
       crs:ColorNoiseReductionSmoothness="50"
       crs:HueAdjustmentRed="0"
       crs:HueAdjustmentOrange="-4"
       crs:HueAdjustmentYellow="-10"
       crs:HueAdjustmentGreen="+20"
       crs:HueAdjustmentAqua="0"
       crs:HueAdjustmentBlue="-6"
       crs:HueAdjustmentPurple="0"
       crs:HueAdjustmentMagenta="0"
       crs:SaturationAdjustmentRed="0"
       crs:SaturationAdjustmentOrange="+5"
       crs:SaturationAdjustmentYellow="-20"
       crs:SaturationAdjustmentGreen="-35"
       crs:SaturationAdjustmentAqua="+10"
       crs:SaturationAdjustmentBlue="+12"
       crs:SaturationAdjustmentPurple="0"
       crs:SaturationAdjustmentMagenta="0"
       crs:LuminanceAdjustmentRed="0"
       crs:LuminanceAdjustmentOrange="+8"
       crs:LuminanceAdjustmentYellow="0"
       crs:LuminanceAdjustmentGreen="-10"
       crs:LuminanceAdjustmentAqua="0"
       crs:LuminanceAdjustmentBlue="-12"
       crs:LuminanceAdjustmentPurple="0"
       crs:LuminanceAdjustmentMagenta="0"
       crs:SplitToningShadowHue="205"
       crs:SplitToningShadowSaturation="18"
       crs:SplitToningHighlightHue="38"
       crs:SplitToningHighlightSaturation="22"
       crs:SplitToningBalance="+15"
       crs:ColorGradeMidtoneHue="0"
       crs:ColorGradeMidtoneSat="0"
       crs:ColorGradeShadowLum="-4"
       crs:ColorGradeMidtoneLum="0"
       crs:ColorGradeHighlightLum="+3"
       crs:ColorGradeBlending="60"
       crs:ColorGradeGlobalHue="0"
       crs:ColorGradeGlobalSat="0"
       crs:ColorGradeGlobalLum="0"
       crs:AutoLateralCA="1"
       crs:LensProfileEnable="1"
       crs:LensManualDistortionAmount="0"
       crs:VignetteAmount="0"
       crs:DefringePurpleAmount="0"
       crs:DefringePurpleHueLo="30"
       crs:DefringePurpleHueHi="70"
       crs:DefringeGreenAmount="0"
       crs:DefringeGreenHueLo="40"
       crs:DefringeGreenHueHi="60"
       crs:PerspectiveUpright="0"
       crs:PerspectiveVertical="0"
       crs:PerspectiveHorizontal="0"
       crs:PerspectiveRotate="0.0"
       crs:PerspectiveAspect="0"
       crs:PerspectiveScale="100"
       crs:PerspectiveX="0.00"
       crs:PerspectiveY="0.00"
       crs:PostCropVignetteAmount="-18"
       crs:PostCropVignetteMidpoint="45"
       crs:PostCropVignetteFeather="55"
       crs:PostCropVignetteRoundness="0"
       crs:PostCropVignetteStyle="1"
       crs:PostCropVignetteHighlightContrast="0"
       crs:GrainAmount="12"
       crs:GrainSize="25"
       crs:GrainFrequency="50"
       crs:ShadowTint="0"
       crs:RedHue="0"
       crs:RedSaturation="0"
       crs:GreenHue="0"
       crs:GreenSaturation="0"
       crs:BlueHue="-8"
       crs:BlueSaturation="+15"
       crs:ConvertToGrayscale="False"
       crs:OverrideLookVignette="False"
       crs:ToneCurveName2012="Custom"
       crs:CameraProfile="Adobe Standard"
       crs:HasSettings="True">
       <crs:Name>
        <rdf:Alt>
         <rdf:li xml:lang="x-default">Teal Evening</rdf:li>
        </rdf:Alt>
       </crs:Name>
       <crs:ShortName>
        <rdf:Alt>
         <rdf:li xml:lang="x-default"/>
        </rdf:Alt>
       </crs:ShortName>
       <crs:SortName>
        <rdf:Alt>
         <rdf:li xml:lang="x-default"/>
        </rdf:Alt>
       </crs:SortName>
       <crs:Group>
        <rdf:Alt>
         <rdf:li xml:lang="x-default">Evening</rdf:li>
        </rdf:Alt>
       </crs:Group>
       <crs:Description>
        <rdf:Alt>
         <rdf:li xml:lang="x-default">Cool shadows, warm highlights.</rdf:li>
        </rdf:Alt>
       </crs:Description>
       <crs:Look>
        <rdf:Description
         crs:Name="Studio Look"
         crs:Amount="1"
         crs:UUID="0F1E2D3C4B5A69788796A5B4C3D2E1F0"
         crs:SupportsAmount="false"
         crs:SupportsMonochrome="false"
         crs:SupportsOutputReferred="false">
         <crs:Group>
          <rdf:Alt>
           <rdf:li xml:lang="x-default">Profiles</rdf:li>
          </rdf:Alt>
         </crs:Group>
         <crs:Parameters>
          <rdf:Description
           crs:Version="15.4"
           crs:ProcessVersion="11.0"
           crs:ConvertToGrayscale="True">
           <crs:ToneCurvePV2012>
            <rdf:Seq>
             <rdf:li>0, 0</rdf:li>
             <rdf:li>60, 50</rdf:li>
             <rdf:li>190, 200</rdf:li>
             <rdf:li>255, 255</rdf:li>
            </rdf:Seq>
           </crs:ToneCurvePV2012>
          </rdf:Description>
         </crs:Parameters>
        </rdf:Description>
       </crs:Look>
       <crs:ToneCurvePV2012>
        <rdf:Seq>
         <rdf:li>0, 0</rdf:li>
         <rdf:li>64, 58</rdf:li>
         <rdf:li>128, 128</rdf:li>
         <rdf:li>192, 200</rdf:li>
         <rdf:li>255, 255</rdf:li>
        </rdf:Seq>
       </crs:ToneCurvePV2012>
       <crs:ToneCurvePV2012Red>
        <rdf:Seq>
         <rdf:li>0, 0</rdf:li>
         <rdf:li>255, 255</rdf:li>
        </rdf:Seq>
       </crs:ToneCurvePV2012Red>
       <crs:ToneCurvePV2012Green>
        <rdf:Seq>
         <rdf:li>0, 0</rdf:li>
         <rdf:li>255, 255</rdf:li>
        </rdf:Seq>
       </crs:ToneCurvePV2012Green>
       <crs:ToneCurvePV2012Blue>
        <rdf:Seq>
         <rdf:li>0, 0</rdf:li>
         <rdf:li>255, 255</rdf:li>
        </rdf:Seq>
       </crs:ToneCurvePV2012Blue>
       <crs:MaskGroupBasedCorrections>
        <rdf:Seq>
         <rdf:li>
          <rdf:Description
           crs:What="Correction"
           crs:CorrectionAmount="1"
           crs:CorrectionActive="true"
           crs:LocalExposure2012="+0.20">
           <crs:CorrectionMasks>
            <rdf:Seq>
             <rdf:li
              crs:What="Mask/Image"
              crs:MaskActive="true"
              crs:MaskName="Subject"
              crs:MaskSubType="1"/>
            </rdf:Seq>
           </crs:CorrectionMasks>
          </rdf:Description>
         </rdf:li>
        </rdf:Seq>
       </crs:MaskGroupBasedCorrections>
      </rdf:Description>
     </rdf:RDF>
    </x:xmpmeta>
    """

    @Test func `every panel converts with the right values, groups and outcomes`() throws {
        let imported = try LightroomPreset.convert(Data(Self.preset.utf8))
        let recipe = imported.recipe
        #expect(recipe.name == "Teal Evening")
        #expect(recipe.group == "Evening")
        #expect(recipe.summary == "Cool shadows, warm highlights.")
        #expect(imported.report.processVersion == "15.4")
        #expect(recipe.includes == [
            .treatment, .whiteBalance, .tone, .presence, .toneCurve, .colorMixer, .colorGrading, .effects, .detail,
        ])
        #expect(recipe.settings.treatment == .color)
        #expect(recipe.settings.whiteBalanceMode == .custom)
        #expect(recipe.settings[.temperature] == 5900)
        #expect(recipe.settings[.tint] == 8)
        #expect(recipe.settings[.exposure] == 0.35)
        #expect(recipe.settings[.highlights] == -60)
        #expect(recipe.settings[.curveDarks] == 6)
        #expect(recipe.settings[.hueGreen] == 20)
        #expect(recipe.settings[.saturationGreen] == -35)
        #expect(recipe.settings[.luminanceBlue] == -12)
        #expect(recipe.settings[.gradeShadowsHue] == 205)
        #expect(recipe.settings[.gradeBlending] == 60)
        #expect(recipe.settings[.gradeBalance] == 15)
        #expect(recipe.settings[.vignetteAmount] == -18)
        #expect(recipe.settings[.grainAmount] == 12)
        #expect(recipe.settings.pointCurve?.count == 5)
        // Values at Redlamp's defaults aren't listed; the included groups take them.
        #expect(recipe.settings.values[.sharpenAmount] == nil)
        #expect(recipe.settings.values[.hueRed] == nil)

        let ignored = Set(imported.report.entries(.ignored).map(\.setting))
        #expect(ignored == [
            "CameraProfile", "Look", "AutoLateralCA", "LensProfileEnable", "LensManualDistortionAmount",
            "VignetteAmount", "DefringePurpleAmount", "DefringePurpleHueLo", "DefringePurpleHueHi",
            "DefringeGreenAmount", "DefringeGreenHueLo", "DefringeGreenHueHi", "PerspectiveUpright",
            "PerspectiveVertical", "PerspectiveHorizontal", "PerspectiveRotate", "PerspectiveAspect",
            "PerspectiveScale", "PerspectiveX", "PerspectiveY", "ShadowTint", "RedHue", "RedSaturation", "GreenHue",
            "GreenSaturation", "BlueHue", "BlueSaturation", "MaskGroupBasedCorrections",
        ])
        #expect(imported.report.entries(.approximated).isEmpty)
        #expect(imported.report.entries(.mapped).count == 81)
        #expect(imported.report.note("Look") == LightroomPreset.Note.look("Studio Look"))
        #expect(imported.crop == nil)
    }

    @Test func `the converted recipe passes validation and survives a recipe file unchanged`() throws {
        let recipe = try LightroomPreset.convert(Data(Self.preset.utf8)).recipe
        let (decoded, issues) = try RecipeValidator.decode(RecipeFile.encode(recipe))
        #expect(issues.isEmpty)
        #expect(decoded.includes == recipe.includes)
        #expect(decoded.settings == recipe.settings)
        #expect(decoded.name == recipe.name)
    }
}
