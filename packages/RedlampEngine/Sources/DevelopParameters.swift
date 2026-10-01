import Foundation
import Metal
import RedlampColor
import RedlampEngineAPI
import RedlampKernels
import simd

/// Everything the fused develop kernel reads for one render.
struct DevelopInputs {
    var params: DevelopParams
    var toneLUT: [Float]
    var mixer: [Float]
    /// Never empty: Metal needs a bound buffer, so a zeroed element stands in.
    var layers: [MaskLayerGPU]
    var components: [MaskComponentGPU]
    /// The Base Look's table; nil binds the identity table with the stage off.
    var lookTable: (any MTLTexture)?
}

/// Translates an `EditRecipe` into the fused kernel's parameter block.
///
/// This is where slider units become rendering units; tuning a slider's feel happens here
/// and nowhere else.
enum DevelopParameters {
    static func make(
        recipe: EditRecipe,
        session: ImageSession,
        baseLook resolved: BaseLookRegistry.Resolved? = nil,
        outputSize: PixelSize,
        region: ImageRect = .full,
        encoding: OutputEncoding,
        showClipping: Bool,
        maskOverlay: UUID? = nil,
        maskOverlayColor: MaskOverlayColor = .red,
        maskOverlayStyle: MaskOverlayStyle = .colorOverlay,
        masks: MaskBindings = .none,
    ) -> DevelopInputs {
        var p = DevelopParams()
        let baseLook = resolved ?? BaseLookRegistry.Resolved(
            parameters: (BuiltInBaseLook(reference: recipe.baseLook) ?? .color).parameters,
            table: nil, tableSize: 0, isAvailable: true,
        )
        let look = baseLook.parameters.scaled(by: recipe.baseLook.amount)
        if baseLook.table != nil {
            p.lookTable = SIMD4(
                Float(recipe.baseLook.amount / 100), Float(baseLook.tableSize),
                baseLook.tableSpace == .sceneLog ? 1 : 0, 0,
            )
        }
        p.recipe = SIMD4(
            Float(recipe[.colorChrome] / 100),
            Float(recipe[.colorChromeBlue] / 100),
            Float(0.25 * log2(max(recipe[.dynamicRange], 100) / 100)),
            0,
        )

        p.setCameraToWorking(session.cameraToWorking(for: recipe))
        // Display-referred work stays in Rec.2020 primaries; the kernel gamut-maps into these.
        p.setDisplayToOutput(
            encoding == .sRGB || encoding == .linearSRGB
                ? ColorMatrices.rec2020ToSRGB.floatMatrix : ColorMatrices.rec2020ToDisplayP3.floatMatrix,
        )

        // Camera-style fine-tuning: ±100 is ±0.3 EV on the red or blue channel.
        let shift = SIMD3<Float>(
            Float(pow(2, 0.3 * recipe[.wbShiftRed] / 100)), 1, Float(pow(2, 0.3 * recipe[.wbShiftBlue] / 100)),
        )
        p.wbRatio = SIMD4(SIMD3<Float>(session.whiteBalanceRatio(for: recipe)) * shift, 0)

        let exposure = recipe[.exposure] + session.baselineExposure
        let contrast = recipe[.contrast] / 100 * 0.32 + (look.contrast - 1) * 0.6
        p.tone = SIMD4(
            Float(pow(2, exposure)),
            Float(contrast),
            Float(recipe[.highlights] / 100),
            Float(recipe[.shadows] / 100),
        )

        let whites = recipe[.whites] / 100
        let blacks = recipe[.blacks] / 100
        let whitePoint = pow(2, -whites * 0.85)
        let blackPoint = blacks > 0 ? -0.012 * blacks : -0.008 * blacks
        p.tone2 = SIMD4(
            Float(whitePoint),
            Float(blackPoint),
            ToneCurveMath.isIdentity(recipe) ? 0 : 1,
            showClipping ? 1 : 0,
        )

        let monochrome = recipe.treatment == .blackAndWhite || look.isMonochrome
        p.color = SIMD4(
            Float(recipe[.vibrance] / 100),
            Float(look.saturation * (1 + recipe[.saturation] / 100)),
            Float(look.warmth),
            monochrome ? 1 : 0,
        )

        let mixer = ColorBand.allCases.map { Float(recipe[$0.hueParameter] / 100) }
            + ColorBand.allCases.map { Float(recipe[$0.saturationParameter] / 100) }
            + ColorBand.allCases.map { Float(recipe[$0.luminanceParameter] / 100) }
        p.look = SIMD4(
            Float(look.greenBoost),
            Float(look.skinSoftening),
            mixer.contains { $0 != 0 } ? 1 : 0,
            0,
        )

        func grade(_ range: GradingRange, strength: Double) -> SIMD4<Float> {
            let direction = OKLab.direction(forWheelHue: recipe[range.hueParameter])
            let saturation = recipe[range.saturationParameter] / 100
            let offset = direction * saturation * strength
            return SIMD4(Float(offset.x), Float(offset.y), Float(recipe[range.luminanceParameter] / 100 * 0.12), 0)
        }
        p.gradeShadows = grade(.shadows, strength: 0.1)
        p.gradeMidtones = grade(.midtones, strength: 0.08)
        p.gradeHighlights = grade(.highlights, strength: 0.08)
        p.gradeGlobal = grade(.global, strength: 0.06)
        let gradingActive = GradingRange.allCases.contains {
            !recipe.isDefault($0.saturationParameter) || !recipe.isDefault($0.luminanceParameter)
        }
        p.gradeShape = SIMD4(
            Float(recipe[.gradeBlending] / 100),
            Float(recipe[.gradeBalance] / 100),
            gradingActive ? 1 : 0,
            0,
        )

        p.vignette = SIMD4(
            Float(recipe[.vignetteAmount] / 100),
            Float(recipe[.vignetteMidpoint] / 100),
            Float(recipe[.vignetteRoundness] / 100),
            Float(recipe[.vignetteFeather] / 100),
        )
        p.grain = SIMD4(
            Float(recipe[.grainAmount] / 100),
            Float(recipe[.grainSize] / 100),
            Float(recipe[.grainRoughness] / 100),
            7,
        )
        p.grain2 = SIMD4(Float(recipe[.grainColor] / 100), recipe.processVersion >= 2 ? 1 : 0, 0, 0)
        p.render = SIMD4(recipe.processVersion >= 3 && !session.isRaw ? 1 : 0, recipe.processVersion >= 3 ? 1 : 0, 0, 0)
        p.mood0 = SIMD4(
            Float(recipe[.leakAmount] / 100), Float(recipe[.leakWarmth] / 100),
            Float(recipe[.leakVariation] / 100), Float(recipe[.dustAmount] / 100),
        )
        p.mood1 = SIMD4(Float(recipe[.scratchAmount] / 100), Float(recipe[.frameStyle]), Float(recipe[.frameSize] / 100), 0)
        // Radii as fractions of the long side, so the glow is the same at any resolution: halation
        // about 0.2-2% (a 35 mm frame's 0.1-0.7 mm), bloom about 0.5-6%.
        p.glow = SIMD4(
            Float(recipe[.halationAmount] / 100),
            Float(0.002 * pow(10, recipe[.halationSize] / 100)),
            Float(recipe[.bloomAmount] / 100),
            Float(0.005 * pow(12, recipe[.bloomSize] / 100)),
        )

        let full = session.orientedSize
        // Full-resolution pixels per output pixel; picks the pyramid level to sample.
        let scale = region.width * Double(full.width) / Double(max(outputSize.width, 1))
        p.geometry = SIMD4(
            Float(session.orientation),
            Float(max(0, log2(scale))),
            encoding.rawValue,
            Float(full.aspectRatio),
        )
        p.outputSize = SIMD4(Float(outputSize.width), Float(outputSize.height), Float(scale), 0)
        p.region = SIMD4(Float(region.x), Float(region.y), Float(region.width), Float(region.height))
        p.haze = SIMD4(session.airlight, Float(recipe[.dehaze] / 100))

        let (layers, components, overlayIndex) = maskBuffers(
            recipe.masks, aspect: full.aspectRatio, overlay: maskOverlay, masks: masks,
            detailLevel: detailLevel(session),
        )
        if encoding == .okLab {
            // A guide: Rec.2020 output, and no grain for range masks to speckle on.
            p.setDisplayToOutput(matrix_identity_float3x3)
            p.grain.x = 0
            p.tone2.w = 0
        }
        p.masks = SIMD4(
            Float(layers.count), Float(overlayIndex ?? -1), Float(components.count),
            Float(maskOverlayColor.rawValue + 8 * maskOverlayStyle.rawValue),
        )

        let lut = ToneCurveMath.isIdentity(recipe) ? [Float](repeating: 0, count: 4) : ToneCurveMath.lut(for: recipe)
        return DevelopInputs(
            params: p,
            toneLUT: lut,
            mixer: mixer,
            layers: layers.isEmpty ? [.empty] : layers,
            components: components.isEmpty ? [.empty] : components,
            lookTable: baseLook.table,
        )
    }

    /// Visible masks (plus the overlaid one, even if hidden) as kernel buffers.
    /// Coordinates are aspect-corrected so gradients stay perpendicular and circles round.
    private static func maskBuffers(
        _ layerList: [MaskLayer],
        aspect: Double,
        overlay: UUID?,
        masks: MaskBindings,
        detailLevel: Int,
    ) -> (layers: [MaskLayerGPU], components: [MaskComponentGPU], overlayIndex: Int?) {
        var layers: [MaskLayerGPU] = []
        var overlayIndex: Int?
        var encoder = MaskComponentEncoder(aspect: aspect, masks: masks, layers: layerList)

        for mask in layerList where mask.isVisible || mask.id == overlay {
            guard layers.count < MaskLayer.maximumLayers else { break }
            let first = encoder.components.count
            for component in mask.components where encoder.components.count < MaskLayer.maximumComponents {
                encoder.append(component)
            }
            let count = encoder.components.count - first
            let scale = mask.isVisible ? mask.amount / 100 : 0
            func value(_ parameter: ParameterID, _ divisor: Double = 100) -> Float {
                Float(mask[parameter] / divisor * scale)
            }
            if mask.id == overlay {
                overlayIndex = layers.count
            }
            layers.append(MaskLayerGPU(
                color: SIMD4(
                    value(.localTemperature),
                    value(.localTint),
                    value(.localHue, 1) / 6,
                    value(.localSaturation),
                ),
                tone: SIMD4(
                    value(.localExposure, 1),
                    value(.localContrast),
                    value(.localHighlights),
                    value(.localShadows),
                ),
                tone2: SIMD4(value(.localWhites), value(.localBlacks), Float(first), Float(count)),
                detail: SIMD4(value(.localDehaze), Float(mask.detail / 100), Float(detailLevel), 0),
                glow: SIMD4(value(.localHalation), value(.localBloom), 0, 0),
            ))
        }
        return (layers, encoder.finished(), overlayIndex)
    }

    /// The pyramid level a mask's Detail measures texture at: about 2048 px on the long side,
    /// whatever the zoom.
    static func detailLevel(_ session: ImageSession) -> Int {
        max(
            0,
            min(
                Int(log2(Double(session.orientedSize.longEdge) / 2048).rounded()),
                session.pyramid.mipmapLevelCount - 1,
            ),
        )
    }

    /// The kernel's form of a component; `nil` for one written by a newer Redlamp, which is
    /// left out. A raster component without its bitmap covers nothing.
    static func gpuComponent(
        _ component: MaskComponent, aspect: Double, masks: MaskBindings = .none,
    ) -> MaskComponentGPU? {
        let operation: Float = switch component.operation {
        case .add: 0
        case .subtract: 1
        case .intersect: 2
        }
        let inverted: Float = component.inverted ? 1 : 0
        let inverseAspect = Float(1 / max(aspect, 1e-6))
        switch component.shape {
        case let .linear(gradient):
            return MaskComponentGPU(
                geometry: SIMD4(
                    Float(gradient.start.x * aspect), Float(gradient.start.y),
                    Float(gradient.end.x * aspect), Float(gradient.end.y),
                ),
                shape: SIMD4(1, operation, inverted, 0),
                rotation: SIMD4(1, 0, 0, 0),
            )
        case let .radial(gradient):
            let radians = gradient.rotation * .pi / 180
            return MaskComponentGPU(
                geometry: SIMD4(
                    Float(gradient.center.x * aspect), Float(gradient.center.y),
                    Float(gradient.radiusX), Float(gradient.radiusY),
                ),
                shape: SIMD4(2, operation, inverted, Float(gradient.feather / 100)),
                rotation: SIMD4(Float(cos(radians)), Float(sin(radians)), 0, 0),
            )
        case .brush, .ai:
            guard let slice = masks.slices[component.id] else {
                return MaskComponentGPU(geometry: .zero, shape: SIMD4(0, operation, inverted, 0), rotation: .zero)
            }
            return MaskComponentGPU(
                geometry: SIMD4(Float(slice), inverseAspect, 0, 0),
                shape: SIMD4(3, operation, inverted, 0),
                rotation: .zero,
            )
        case let .luminanceRange(range):
            let r = range.normalized
            return MaskComponentGPU(
                geometry: SIMD4(
                    Float((r.lower - r.lowerFeather) / 100), Float(r.lower / 100),
                    Float(r.upper / 100), Float((r.upper + r.upperFeather) / 100),
                ),
                shape: SIMD4(4, operation, inverted, 0),
                rotation: SIMD4(inverseAspect, 0, 0, 0),
            )
        case let .colorRange(range):
            var gpu = MaskComponentGPU(
                geometry: SIMD4(
                    Float(range.samples.count), Float(ColorRangeMath.tolerance(refine: range.refine)), inverseAspect, 0,
                ),
                shape: SIMD4(5, operation, inverted, 0),
                rotation: .zero,
            )
            let samples = range.samples.map { sample in
                SIMD3<Float>(
                    Float(sample.center.x), Float(sample.center.y),
                    Float(ColorRangeMath.level(radius: sample.radius, guideHeight: masks.guideSize.height)),
                )
            }
            func sample(_ index: Int) -> SIMD3<Float> {
                index < samples.count ? samples[index] : .zero
            }
            gpu.extra0 = SIMD4(sample(0).x, sample(0).y, sample(1).x, sample(1).y)
            gpu.extra1 = SIMD4(sample(2).x, sample(2).y, sample(3).x, sample(3).y)
            gpu.extra2 = SIMD4(sample(4).x, sample(4).y, sample(4).z, 0)
            gpu.extra3 = SIMD4(sample(0).z, sample(1).z, sample(2).z, sample(3).z)
            return gpu
        case let .depthRange(depth):
            let r = depth.range.normalized
            guard let slice = masks.slices[component.id] else {
                return MaskComponentGPU(geometry: .zero, shape: SIMD4(0, operation, inverted, 0), rotation: .zero)
            }
            return MaskComponentGPU(
                geometry: SIMD4(
                    Float((r.lower - r.lowerFeather) / 100), Float(r.lower / 100),
                    Float(r.upper / 100), Float((r.upper + r.upperFeather) / 100),
                ),
                shape: SIMD4(7, operation, inverted, 0),
                rotation: SIMD4(Float(slice), inverseAspect, 0, 0),
            )
        case .maskReference:
            // Filled in by MaskComponentEncoder with the referenced mask's components.
            return MaskComponentGPU(geometry: .zero, shape: SIMD4(6, operation, inverted, 0), rotation: .zero)
        case .unknown:
            return nil
        }
    }
}

/// A recipe's components for the kernel. A reference component points at the referenced
/// mask's components, appended after every layer's own.
struct MaskComponentEncoder {
    let aspect: Double
    let masks: MaskBindings
    let layers: [MaskLayer]
    private(set) var components: [MaskComponentGPU] = []
    private var references: [(index: Int, maskID: UUID)] = []

    init(aspect: Double, masks: MaskBindings, layers: [MaskLayer]) {
        self.aspect = aspect
        self.masks = masks
        self.layers = layers
    }

    mutating func append(_ component: MaskComponent) {
        guard let gpu = DevelopParameters.gpuComponent(component, aspect: aspect, masks: masks) else { return }
        if case let .maskReference(reference) = component.shape {
            references.append((components.count, reference.maskID))
        }
        components.append(gpu)
    }

    /// The components, with every reference resolved. A missing mask covers nothing.
    func finished() -> [MaskComponentGPU] {
        var result = components
        for (index, maskID) in references {
            guard let referenced = layers.first(where: { $0.id == maskID }) else { continue }
            let first = result.count
            for component in referenced.components {
                if case .maskReference = component.shape {
                    continue
                }
                if let gpu = DevelopParameters.gpuComponent(component, aspect: aspect, masks: masks) {
                    result.append(gpu)
                }
            }
            result[index].geometry = SIMD4(Float(first), Float(result.count - first), 0, 0)
        }
        return result
    }
}

/// Color Range's slider units, shared with the CPU reference in tests.
enum ColorRangeMath {
    /// The OKLab distance at which a colour stops being selected, from Refine (0...100).
    static func tolerance(refine: Double) -> Double {
        0.02 + 0.2 * pow(min(max(refine, 0), 100) / 100, 1.5)
    }

    /// The guide level whose texels average a sample's disc (at least a few texels).
    static func level(radius: Double, guideHeight: Int) -> Double {
        max(0, log2(max(radius * Double(guideHeight), 1.5)))
    }
}
