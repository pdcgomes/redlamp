import Foundation

public enum Treatment: String, Codable, Sendable, Hashable, CaseIterable {
    case color
    case blackAndWhite

    public var name: String {
        switch self {
        case .color: "Color"
        case .blackAndWhite: "B&W"
        }
    }
}

/// A point on the point tone curve, both coordinates in 0...1 (display-referred).
public struct CurvePoint: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A point curve's channel, as Lightroom's are: RGB for all three channels, then red, green and
/// blue, each with a curve of its own after the RGB one.
public enum CurveChannel: String, CaseIterable, Sendable {
    case rgb, red, green, blue

    /// The channels with a curve of their own after the RGB curve.
    public static let colors: [CurveChannel] = [.red, .green, .blue]

    public var name: String {
        switch self {
        case .rgb: "RGB"
        case .red: "Red"
        case .green: "Green"
        case .blue: "Blue"
        }
    }
}

/// Which shared recipe an edit came from. Provenance only: rendering never reads it.
public struct AppliedRecipe: Codable, Sendable, Hashable {
    public var id: String
    public var version: Int
    public var name: String
    /// The recipe's Amount when it was applied, in percent.
    public var amount: Double
    /// Fields written by a newer Redlamp, written back unchanged.
    public var unknownFields: [String: JSONValue] = [:]

    public init(id: String, version: Int, name: String, amount: Double = 100) {
        self.id = id
        self.version = version
        self.name = name
        self.amount = amount
    }
}

/// The complete, non-destructive description of an edit.
///
/// Scalar parameters are stored sparsely: only values that differ from their schema
/// default are kept, which keeps sidecars small and lets new parameters be added
/// without migrating old files.
///
/// Two versions describe an edit. `formatVersion` is the file syntax and can be migrated
/// silently. `processVersion` is the rendering behavior the edit was made with: an edit
/// must keep rendering the same way, so it is only ever changed by an explicit update.
public struct EditRecipe: Sendable, Hashable {
    /// Version 2 renamed `profile` to `baseLook` and namespaced built-in look ids. Version 3
    /// added brush, range and AI mask components, whose bitmaps live in a sidecar package.
    public static let formatVersion = 3
    /// Bumped whenever a change to rendering math would make existing edits look different.
    /// 2: grain is sized to the frame rather than the sensor's pixels, and is strongest in the
    /// low midtones and shadows, as film's is.
    /// 3: a bitmap (JPEG, HEIC, PNG, TIFF) renders as the file at default settings, and halation
    /// boosts only small clipped lights, not a clipped sky.
    /// 4: a DNG's embedded camera profile corrects its colour with the profile's HueSatMap.
    /// 5: the lens correction the file carries (DNG opcodes, Sony's tags) applies by default, and
    /// a DNG's ProfileGainTableMap (Apple ProRAW's local tone mapping) applies with its embedded look.
    /// 6: Fujifilm's lens corrections apply too.
    /// 7: Highlights and Shadows are edge-aware: they move each region by its brightness and keep
    /// the detail inside it (`ToneBase`), instead of a curve on each pixel's own brightness.
    /// 8: Dehaze's haze map follows the photo's edges (`Haze.Refined`), so the sky
    /// beside a tree or a ridge is dehazed as much as the rest of it.
    /// 9: Clarity is edge-aware (`ClarityBase`): a strong edge isn't its detail, so it puts no
    /// bright and dark bands along it.
    /// 10: a retouched photo's maps (Highlights and Shadows', Clarity's, Dehaze's and glow's) are
    /// made from it (`RetouchStage.Maps`), so a removed object leaves no trace where they're used.
    /// 11: Texture, Clarity and sharpening work on one band split of the noise-reduced luminance
    /// (`DetailStage.Ladder`): Texture boosts medium detail and holds back an edge's step, so it
    /// makes no halos; sharpening restores detail above the noise and leaves flat noise alone.
    /// 12: a Remove spot's fill copies from none of the edit's other Remove spots and none of the
    /// spots after it (`RetouchStage.FillVersion`), so removing several things at once doesn't
    /// copy one into another's hole.
    /// 13: AI masks coarser than masks are stored at have their edges refined at the size drawn
    /// (`MaskEdges`), and a mask's Whites and Blacks move the white and black points where it covers.
    /// 14: a Sky mask's per-pixel adjustments reach only the sky's share of an edge pixel's light
    /// (`MaskColors`), so twigs and leaves keep their own colour and brightness; an AI mask's
    /// Feather and Edge shape its body and keep its stray hairs and wisps (`GrayMask.shaped`).
    /// 15: highlights the camera clipped in one or two colours are rebuilt with the colour around
    /// them, and areas clipped in every colour fade to neutral (`RawRevision.second`), so a sky
    /// clipped in green and blue no longer turns lilac when pulled below white.
    /// 16: a raw's values below black are kept through the demosaic and noise reduction, and clamped
    /// after the detail stage (`RawRevision.third`), so deep shadows at high ISO keep their level.
    /// 17: a lens profile made on another body than the photo's, found in Camera Raw's folders, or
    /// made for a fisheye, corrects a raw that carries no correction
    /// (`LCPProfileLibrary.widerMatchingProcess`).
    /// 18: negative Dehaze adds haze where the haze map finds haze (`Haze.added`, the dark channel
    /// at its minimum over a patch and blurred over a tenth of the frame), toward the airlight tinted
    /// as scattered light is (`Haze.veil`), instead of an even grey blend, so the far distance and
    /// bright unsaturated things fog over while texture and dark saturated things nearby keep their
    /// own, and the result reads as haze rather than a white layer.
    /// A new version records its references for the process-stability gate (`ProcessStabilityTests`).
    public static let currentProcessVersion = 18
    public static let linearPointCurve = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]

    /// Sidecars written before process versions existed are version 1.
    public var processVersion = EditRecipe.currentProcessVersion
    public var treatment: Treatment = .color
    public var baseLook: BaseLookReference = BuiltInBaseLook.color.reference
    public var whiteBalanceMode: WhiteBalanceMode = .asShot
    public var pointCurve: [CurvePoint] = EditRecipe.linearPointCurve {
        didSet {
            if pointCurve != oldValue {
                turnOn(.toneCurve)
            }
        }
    }

    /// Red's, green's and blue's own point curves, applied after `pointCurve` to their channel
    /// alone; a channel is missing while its curve is straight. Set through `self[curve:]`.
    public private(set) var channelCurves: [CurveChannel: [CurvePoint]] = [:]

    public private(set) var values: [ParameterID: Double] = [:]
    /// Point Color's swatches, right after the Color Mixer.
    public var pointColor: [PointColorSwatch] = [] {
        didSet {
            if pointColor != oldValue {
                turnOn(.colorMixer)
            }
        }
    }

    /// The panels switched off (UX-30), which render as `rendered` says. Changing a setting of a
    /// panel that's off turns it back on.
    public var panelsOff: Set<SwitchablePanel> = []
    /// Switched-off panels a newer Redlamp named, written back unchanged.
    public private(set) var unknownPanelsOff: [String] = []
    /// Local adjustments, applied in order on top of the global edit.
    public var masks: [MaskLayer] = []
    /// Heal and Clone spots, applied in order before everything else.
    public var spots: [RetouchSpot] = []
    /// The shared recipe this edit was last built from.
    public var appliedRecipe: AppliedRecipe?
    /// Where the edit came from when it was converted from Lightroom's develop settings.
    public var provenance: EditProvenance?
    /// Under Redlamp Reproduction, where the photo's camera puts a metered grey: its own, written
    /// when the look arrives and never copied from another photo (`EditRecipe.anchored`).
    public var exposureAnchor: ExposureAnchor?
    /// The lens profile chosen in the Lens Corrections panel (LNS-15); nil at Default with none named.
    public var lensProfileChoice: LensProfileChoice? {
        didSet {
            if lensProfileChoice != oldValue {
                turnOn(.lens)
            }
        }
    }

    /// The crop, in the straightened frame (see `GeometryMap`); its angle is `cropAngle`.
    public var crop: CropRect = .full
    /// The user's rotation and flip, after the camera's orientation.
    public var orientation: ImageOrientation = .identity
    /// Parameters and fields written by a newer Redlamp. They don't affect rendering here,
    /// but are written back unchanged so saving never erases them.
    public private(set) var unknownValues: [String: Double] = [:]
    public private(set) var unknownFields: [String: JSONValue] = [:]

    public init() {}

    /// The edit was made with rendering behavior this build doesn't have.
    public var requiresNewerProcess: Bool {
        processVersion > EditRecipe.currentProcessVersion
    }

    public subscript(parameter: ParameterID) -> Double {
        get { values[parameter] ?? parameter.spec.defaultValue }
        set {
            guard !parameter.isMaskScoped, !parameter.isSpotScoped, !parameter.isPointColorScoped else { return }
            let spec = parameter.spec
            let clamped = spec.clamp(newValue)
            let previous = values[parameter]
            if abs(clamped - spec.defaultValue) < 1e-9 {
                values[parameter] = nil
            } else {
                values[parameter] = clamped
            }
            if values[parameter] != previous {
                turnOn(panelHolding: parameter)
            }
        }
    }

    public func isDefault(_ parameter: ParameterID) -> Bool {
        values[parameter] == nil
    }

    /// The point curve for `channel`: `pointCurve` for RGB, otherwise the channel's own.
    public subscript(curve channel: CurveChannel) -> [CurvePoint] {
        get {
            channel == .rgb ? pointCurve : channelCurves[channel] ?? EditRecipe.linearPointCurve
        }
        set {
            guard channel != .rgb else {
                pointCurve = newValue
                return
            }
            let previous = channelCurves[channel]
            channelCurves[channel] = newValue == EditRecipe.linearPointCurve ? nil : newValue
            if channelCurves[channel] != previous {
                turnOn(.toneCurve)
            }
        }
    }

    public mutating func reset(_ parameters: some Sequence<ParameterID>) {
        for parameter in parameters where values[parameter] != nil {
            values[parameter] = nil
            turnOn(panelHolding: parameter)
        }
    }

    private mutating func turnOn(panelHolding parameter: ParameterID) {
        if !panelsOff.isEmpty, let panel = SwitchablePanel(holding: parameter) {
            panelsOff.remove(panel)
        }
    }

    private mutating func turnOn(_ panel: SwitchablePanel) {
        if !panelsOff.isEmpty {
            panelsOff.remove(panel)
        }
    }

    /// Whether nothing has been changed from a fresh import.
    public var isPristine: Bool {
        values.filter { $0.key != .temperature && $0.key != .tint }.isEmpty
            && treatment == .color
            && baseLook == BuiltInBaseLook.color.reference
            && whiteBalanceMode == .asShot
            && !hasPointCurve
            && pointColor.isEmpty
            && masks.isEmpty
            && spots.isEmpty
            && appliedRecipe == nil
            && provenance == nil
            // From process 16 every raw's edit gets its camera's anchor when it's made (CAM-29).
            && (exposureAnchor == nil || processVersion >= 16)
            && lensProfileChoice == nil
            && crop.isFull
            && orientation.isIdentity
            && panelsOff.isEmpty
            && unknownPanelsOff.isEmpty
            && unknownValues.isEmpty
            && unknownFields.isEmpty
    }

    /// Parameters whose value differs from `other`.
    public func parametersChanged(from other: EditRecipe) -> [ParameterID] {
        values.compactMap { other.values[$0.key] == $0.value ? nil : $0.key }
            + other.values.keys.filter { values[$0] == nil }
    }

    public func mask(_ id: UUID) -> MaskLayer? {
        masks.first { $0.id == id }
    }

    /// Whether any of the point curves isn't straight: RGB's, or a channel's own.
    public var hasPointCurve: Bool {
        pointCurve != EditRecipe.linearPointCurve || !channelCurves.isEmpty
    }
}

// MARK: - Codable

extension EditRecipe: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, processVersion, treatment, baseLook, whiteBalance, pointCurve, values, pointColor, masks
        case pointCurveRed, pointCurveGreen, pointCurveBlue
        case appliedRecipe, exposureAnchor, crop, orientation, spots, panelsOff
        case lensProfile, provenance
        /// Format version 1's name for `baseLook`; read, never written.
        case profile

        static func curve(_ channel: CurveChannel) -> CodingKeys {
            switch channel {
            case .rgb: .pointCurve
            case .red: .pointCurveRed
            case .green: .pointCurveGreen
            case .blue: .pointCurveBlue
            }
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        processVersion = try container.decodeIfPresent(Int.self, forKey: .processVersion) ?? 1
        treatment = try container.decodeIfPresent(Treatment.self, forKey: .treatment) ?? .color
        baseLook = try container.decodeIfPresent(BaseLookReference.self, forKey: .baseLook)
            ?? container.decodeIfPresent(BaseLookReference.self, forKey: .profile)
            ?? BuiltInBaseLook.color.reference
        whiteBalanceMode = try container.decodeIfPresent(WhiteBalanceMode.self, forKey: .whiteBalance) ?? .asShot
        for channel in CurveChannel.allCases {
            self[curve: channel] = try container.decodeIfPresent([CurvePoint].self, forKey: .curve(channel))
                ?? EditRecipe.linearPointCurve
        }
        let raw = try container.decodeIfPresent([String: Double].self, forKey: .values) ?? [:]
        for (key, value) in raw {
            if let parameter = ParameterID(rawValue: key) {
                self[parameter] = value
            } else {
                unknownValues[key] = value
            }
        }
        pointColor = try container.decodeIfPresent([PointColorSwatch].self, forKey: .pointColor) ?? []
        masks = try container.decodeIfPresent([MaskLayer].self, forKey: .masks) ?? []
        spots = try container.decodeIfPresent([RetouchSpot].self, forKey: .spots) ?? []
        appliedRecipe = try container.decodeIfPresent(AppliedRecipe.self, forKey: .appliedRecipe)
        provenance = try container.decodeIfPresent(EditProvenance.self, forKey: .provenance)
        exposureAnchor = try container.decodeIfPresent(ExposureAnchor.self, forKey: .exposureAnchor)
        lensProfileChoice = try container.decodeIfPresent(LensProfileChoice.self, forKey: .lensProfile)
        crop = try container.decodeIfPresent(CropRect.self, forKey: .crop) ?? .full
        orientation = try container.decodeIfPresent(ImageOrientation.self, forKey: .orientation) ?? .identity
        // After the settings, whose setters turn panels on.
        for name in try container.decodeIfPresent([String].self, forKey: .panelsOff) ?? [] {
            if let panel = SwitchablePanel(rawValue: name) {
                panelsOff.insert(panel)
            } else if !unknownPanelsOff.contains(name) {
                unknownPanelsOff.append(name)
            }
        }
        unknownFields = try decoder.container(keyedBy: DynamicCodingKey.self)
            .unknownFields(excluding: Set(CodingKeys.allCases.map(\.stringValue)))
    }

    public func encode(to encoder: Encoder) throws {
        var unknown = encoder.container(keyedBy: DynamicCodingKey.self)
        try unknown.encode(unknownFields)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(EditRecipe.formatVersion, forKey: .version)
        try container.encode(processVersion, forKey: .processVersion)
        try container.encode(treatment, forKey: .treatment)
        try container.encode(baseLook, forKey: .baseLook)
        try container.encode(whiteBalanceMode, forKey: .whiteBalance)
        for channel in CurveChannel.allCases where self[curve: channel] != EditRecipe.linearPointCurve {
            try container.encode(self[curve: channel], forKey: .curve(channel))
        }
        let known = Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
        try container.encode(unknownValues.merging(known) { _, value in value }, forKey: .values)
        if !pointColor.isEmpty {
            try container.encode(pointColor, forKey: .pointColor)
        }
        if !masks.isEmpty {
            try container.encode(masks, forKey: .masks)
        }
        if !spots.isEmpty {
            try container.encode(spots, forKey: .spots)
        }
        try container.encodeIfPresent(appliedRecipe, forKey: .appliedRecipe)
        try container.encodeIfPresent(provenance, forKey: .provenance)
        try container.encodeIfPresent(exposureAnchor, forKey: .exposureAnchor)
        try container.encodeIfPresent(lensProfileChoice, forKey: .lensProfile)
        if !crop.isFull {
            try container.encode(crop, forKey: .crop)
        }
        if !orientation.isIdentity {
            try container.encode(orientation, forKey: .orientation)
        }
        if !panelsOff.isEmpty || !unknownPanelsOff.isEmpty {
            try container.encode(panelsOff.sorted().map(\.rawValue) + unknownPanelsOff, forKey: .panelsOff)
        }
    }
}
