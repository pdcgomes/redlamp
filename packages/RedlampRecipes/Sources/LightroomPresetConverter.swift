import Foundation
import RedlampEngineAPI

extension LightroomPreset {
    /// Process 2012's version: earlier processes have other sliders.
    static let firstProcessVersion = [6, 7]

    static func convert(_ settings: CameraRawSettings, name: String?) throws -> LightroomPresetImport {
        // A profile is an XMP file of Camera Raw settings too, but not a preset.
        if settings.text("PresetType") == "Look" {
            throw LightroomPresetError.notAPreset
        }
        let processVersion = settings.text("ProcessVersion")
        if let processVersion, let numbers = versionNumbers(processVersion),
           numbers.lexicographicallyPrecedes(firstProcessVersion) {
            throw LightroomPresetError.unsupportedProcessVersion(processVersion)
        }
        guard orderedSettings(settings).contains(where: { $0.rule?.isMetadata != true }) else {
            throw LightroomPresetError.notAPreset
        }
        let converter = LightroomPresetConverter(settings)
        let recipe = Recipe(
            id: RecipeNamespace.newLocalID(),
            name: trimmed(name) ?? trimmed(settings.text("Name")) ?? "Lightroom Preset",
            group: trimmed(settings.text("Group")) ?? "Imported",
            summary: trimmed(settings.text("Description")),
            tags: ["lightroom"],
            includes: converter.includes,
            settings: converter.recipeSettings,
            created: Date(),
        )
        var result = LightroomPresetImport(
            recipe: recipe,
            report: LightroomImportReport(processVersion: processVersion, entries: converter.entries),
        )
        result.crop = LightroomCrop(settings)
        return result
    }

    private static func versionNumbers(_ version: String) -> [Int]? {
        let numbers = version.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil }) else { return nil }
        return numbers.compactMap(\.self)
    }

    private static func trimmed(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

/// A preset's settings carried over to a recipe's one Camera Raw setting at a time, with the
/// report of how each was.
struct LightroomPresetConverter {
    private typealias Note = LightroomPreset.Note
    private typealias Entry = LightroomImportReport.Entry

    let settings: CameraRawSettings
    private(set) var values: [ParameterID: Double] = [:]
    private(set) var includes: Set<RecipeSettingGroup> = []
    private(set) var treatment: Treatment?
    private(set) var whiteBalanceMode: WhiteBalanceMode?
    private(set) var pointCurve: [CurvePoint]?
    private(set) var entries: [LightroomImportReport.Entry] = []

    init(_ settings: CameraRawSettings) {
        self.settings = settings
        for (key, rule) in LightroomPreset.orderedSettings(settings) {
            apply(rule ?? .ignored(Note.unknown), to: key)
        }
        setSplitToningBlending()
    }

    var recipeSettings: RecipeSettings {
        RecipeSettings(values: values, treatment: treatment, whiteBalanceMode: whiteBalanceMode, pointCurve: pointCurve)
    }

    private var isBlackAndWhite: Bool {
        settings.flag("ConvertToGrayscale") == true
    }

    private mutating func apply(_ rule: LightroomRule, to key: String) {
        switch rule {
        case .metadata:
            break
        case let .ignored(note):
            ignore(key, note)
        case let .unlessOff(note, switchKey):
            if settings.flag(switchKey ?? key) != false {
                ignore(key, note)
            }
        case let .parameter(parameter):
            setNumber(key, parameter)
        case let .colorLuminance(band):
            if isBlackAndWhite {
                ignore(key, Note.luminanceInBlackAndWhite)
            } else {
                setNumber(key, band.luminanceParameter)
            }
        case let .grayMix(band):
            if isBlackAndWhite {
                setNumber(key, band.luminanceParameter, approximated: Note.grayMix)
            } else {
                ignore(key, Note.grayMixInColor)
            }
        case .treatment:
            setTreatment(key)
        case .whiteBalance:
            setWhiteBalance(key)
        case let .kelvin(parameter):
            setKelvin(key, parameter)
        case .incremental:
            setIncremental(key)
        case .pointCurve:
            setPointCurve(key)
        case .channelCurve:
            setChannelCurve(key)
        case .vignetteStyle:
            setVignetteStyle(key)
        case .lensProfile:
            ignore(key, settings.flag(key) == false ? Note.lensProfileOff : Note.lensProfileOn)
        case .look:
            ignore(key, lookNote)
        }
    }

    // MARK: - Treatment and white balance

    private static let whiteBalanceModes: [String: WhiteBalanceMode] = [
        "As Shot": .asShot, "Auto": .auto, "Daylight": .daylight, "Cloudy": .cloudy, "Shade": .shade,
        "Tungsten": .tungsten, "Fluorescent": .fluorescent, "Flash": .flash, "Custom": .custom,
    ]

    private mutating func setTreatment(_ key: String) {
        guard let blackAndWhite = settings.flag(key) else { return ignore(key, Note.unreadable) }
        treatment = blackAndWhite ? .blackAndWhite : .color
        includes.insert(.treatment)
        report(key, .mapped)
    }

    /// The white balance the preset sets by name; nil for Custom, which its values set.
    private var namedWhiteBalance: WhiteBalanceMode? {
        guard let mode = settings.text("WhiteBalance").flatMap({ Self.whiteBalanceModes[$0] }), mode != .custom
        else { return nil }
        return mode
    }

    private var hasKelvin: Bool {
        settings.number("Temperature") != nil || settings.number("Tint") != nil
    }

    private var hasIncremental: Bool {
        settings.number("IncrementalTemperature") != nil || settings.number("IncrementalTint") != nil
    }

    private mutating func setWhiteBalance(_ key: String) {
        guard let name = settings.text(key) else { return ignore(key, Note.unreadable) }
        guard let mode = Self.whiteBalanceModes[name] else { return ignore(key, Note.unknownWhiteBalance(name)) }
        if mode != .custom || hasKelvin {
            whiteBalanceMode = mode
            includes.insert(.whiteBalance)
            report(key, .mapped)
        } else if hasIncremental {
            report(key, .approximated, Note.incrementalCustom)
        } else {
            ignore(key, Note.customWithoutValues)
        }
    }

    /// Temperature or Tint, for raw photos, unless the preset names a white balance.
    private mutating func setKelvin(_ key: String, _ parameter: ParameterID) {
        if let mode = namedWhiteBalance {
            return ignore(key, Note.setByMode(mode))
        }
        guard let value = settings.number(key) else { return ignore(key, Note.unreadable) }
        whiteBalanceMode = .custom
        // A custom white balance takes a temperature or tint it doesn't list from the photo.
        set(parameter, value, key: key, keepingDefault: true)
    }

    /// Lightroom's relative white balance for rendered photos, as Red and Blue Shift when the
    /// preset has no Temperature or Tint.
    private mutating func setIncremental(_ key: String) {
        if let mode = namedWhiteBalance {
            return ignore(key, Note.setByMode(mode))
        }
        if hasKelvin {
            return ignore(key, Note.kelvinUsed)
        }
        guard settings.number(key) != nil else { return ignore(key, Note.unreadable) }
        let temperature = settings.number("IncrementalTemperature") ?? 0
        let tint = settings.number("IncrementalTint") ?? 0
        // Warmer is more red and less blue; a magenta tint is more of both.
        let shifts: [ParameterID: Double] = [.wbShiftRed: temperature + tint, .wbShiftBlue: tint - temperature]
        for (parameter, shift) in shifts {
            store(parameter, parameter.spec.clamp(shift))
        }
        let clamped = shifts.values.contains { abs($0) > 100 }
        report(key, .approximated, clamped ? Note.incremental + " " + Note.clamped("±100") : Note.incremental)
    }

    // MARK: - Tone curve and effects

    private mutating func setPointCurve(_ key: String) {
        guard let curve = curve(key) else { return ignore(key, Note.unreadable) }
        guard curve.count <= 64 else { return ignore(key, Note.pointCurveSize) }
        pointCurve = Self.isStraight(curve) ? nil : curve
        includes.insert(.toneCurve)
        report(key, .mapped)
    }

    private mutating func setChannelCurve(_ key: String) {
        guard let curve = curve(key) else { return ignore(key, Note.unreadable) }
        guard Self.isStraight(curve) else { return ignore(key, Note.channelCurve) }
        includes.insert(.toneCurve)
        report(key, .mapped, Note.straightChannelCurve)
    }

    /// A point curve's `x, y` pairs on Lightroom's 0…255 scale, as 0…1, in order.
    private func curve(_ key: String) -> [CurvePoint]? {
        guard case let .list(items) = settings[key], items.count >= 2 else { return nil }
        var points: [CurvePoint] = []
        for item in items {
            let coordinates = item.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard coordinates.count == 2, coordinates.allSatisfy({ (0 ... 255).contains($0) }) else { return nil }
            points.append(CurvePoint(x: coordinates[0] / 255, y: coordinates[1] / 255))
        }
        return points.sorted { $0.x < $1.x }
    }

    private static func isStraight(_ curve: [CurvePoint]) -> Bool {
        curve.first == CurvePoint(x: 0, y: 0) && curve.last == CurvePoint(x: 1, y: 1)
            && curve.allSatisfy { $0.x == $0.y }
    }

    private mutating func setVignetteStyle(_ key: String) {
        guard let style = settings.number(key) else { return ignore(key, Note.unreadable) }
        includes.insert(.effects)
        if style == 1 {
            report(key, .mapped)
        } else {
            report(key, .approximated, Note.vignetteStyle)
        }
    }

    /// A Split Toning preset, from before Color Grading, renders as Lightroom renders one: with
    /// Blending at 100 (Adobe, "Introducing Color Grading", 2020).
    private mutating func setSplitToningBlending() {
        let keys = settings.values.keys
        guard keys.contains(where: { $0.hasPrefix("SplitToning") }),
              !keys.contains(where: { $0.hasPrefix("ColorGrade") })
        else { return }
        store(.gradeBlending, 100)
        let after = entries.lastIndex { $0.setting.hasPrefix("SplitToning") }.map { $0 + 1 } ?? entries.endIndex
        entries.insert(
            Entry(setting: "ColorGradeBlending", outcome: .mapped, note: Note.splitToningBlending),
            at: after,
        )
    }

    private var lookNote: String {
        guard case let .structure(fields) = settings["Look"], let name = fields["Name"], !name.isEmpty else {
            return Note.profile
        }
        return Note.look(name)
    }

    // MARK: - Values and the report

    private mutating func setNumber(_ key: String, _ parameter: ParameterID, approximated note: String? = nil) {
        guard let value = settings.number(key) else { return ignore(key, Note.unreadable) }
        set(parameter, value, key: key, note: note)
    }

    private mutating func set(
        _ parameter: ParameterID,
        _ value: Double,
        key: String,
        note: String? = nil,
        keepingDefault: Bool = false,
    ) {
        let spec = parameter.spec
        let clamped = spec.clamp(value)
        store(parameter, clamped, keepingDefault: keepingDefault)
        if clamped != value {
            report(
                key,
                .approximated,
                [note, Note.clamped(spec.formatted(clamped))].compactMap(\.self).joined(separator: " "),
            )
        } else {
            report(key, note == nil ? .mapped : .approximated, note)
        }
    }

    /// Lists a value unless it is the default, which an included group's unlisted values take.
    private mutating func store(_ parameter: ParameterID, _ value: Double, keepingDefault: Bool = false) {
        if let group = RecipeSettingGroup(parameter: parameter) {
            includes.insert(group)
        }
        values[parameter] = keepingDefault || abs(value - parameter.spec.defaultValue) > 1e-9 ? value : nil
    }

    private mutating func report(_ key: String, _ outcome: LightroomImportReport.Outcome, _ note: String? = nil) {
        entries.append(Entry(setting: key, outcome: outcome, note: note))
    }

    private mutating func ignore(_ key: String, _ note: String) {
        report(key, .ignored, note)
    }
}
