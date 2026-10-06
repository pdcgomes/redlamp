import RedlampEngineAPI

/// The glyphs the inspector's choice menus show beside each option.
extension RetouchSpot.Mode: MenuChoice {
    var symbol: String {
        switch self {
        case .remove: "eraser"
        case .heal: "bandage"
        case .clone: "square.on.square"
        }
    }
}

extension SpotPick: MenuChoice {
    var symbol: String {
        switch self {
        case .spot: "circle.dashed"
        case .person: "person"
        case .object: "cube"
        }
    }
}

/// What a new Remove spot is filled with (RM-10).
enum FillChoice: CaseIterable, MenuChoice {
    case contentAware
    case generative

    init(generative: Bool) {
        self = generative ? .generative : .contentAware
    }

    var name: String {
        switch self {
        case .contentAware: "Content-Aware"
        case .generative: "Generative"
        }
    }

    var symbol: String {
        switch self {
        case .contentAware: "square.grid.3x3.topleft.filled"
        case .generative: "sparkles"
        }
    }
}

extension ObjectSelection: MenuChoice {
    var symbol: String {
        switch self {
        case .rectangle: "rectangle.dashed"
        case .brush: "paintbrush.pointed"
        }
    }
}

extension BrushChoice: MenuChoice {
    var name: String {
        rawValue
    }

    var symbol: String {
        switch self {
        case .a: "a.circle"
        case .b: "b.circle"
        case .erase: "eraser"
        }
    }
}

extension MaskCurves.Channel: MenuChoice {
    var symbol: String {
        switch self {
        case .rgb: "circle.lefthalf.filled"
        case .red: "r.circle"
        case .green: "g.circle"
        case .blue: "b.circle"
        }
    }
}

extension Treatment: MenuChoice {
    var symbol: String {
        switch self {
        case .color: "paintpalette"
        case .blackAndWhite: "circle.lefthalf.filled"
        }
    }
}

extension ToneCurvePanel.Mode: MenuChoice {
    var name: String {
        rawValue
    }

    var symbol: String {
        switch self {
        case .parametric: "slider.horizontal.3"
        case .point: "point.topleft.down.to.point.bottomright.curvepath"
        }
    }
}

extension ColorMixerPanel.Mixer: MenuChoice {
    var name: String {
        rawValue
    }

    var symbol: String {
        switch self {
        case .hsl: "slider.horizontal.3"
        case .color: "swatchpalette"
        case .pointColor: "eyedropper"
        }
    }
}

extension ColorMixerPanel.Attribute: MenuChoice {
    var name: String {
        rawValue
    }

    var symbol: String {
        switch self {
        case .hue: "paintpalette"
        case .saturation: "drop.halffull"
        case .luminance: "sun.max"
        case .all: "square.grid.2x2"
        }
    }
}
