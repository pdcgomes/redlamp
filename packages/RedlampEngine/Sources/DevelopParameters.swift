import Foundation
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
}

/// Translates an `EditRecipe` into the fused kernel's parameter block.
///
/// This is where slider units become rendering units; tuning a slider's feel happens here
/// and nowhere else.
enum DevelopParameters {
    static let sRGBToDisplayP3 = RGBPrimaries.sRGB.conversion(to: .displayP3).floatMatrix

    static func make(
        recipe: EditRecipe,
        session: ImageSession,
        outputSize: PixelSize,
        encoding: OutputEncoding,
        showClipping: Bool,
        maskOverlay: UUID? = nil,
        maskOverlayColor: MaskOverlayColor = .red,
    ) -> DevelopInputs {
        var p = DevelopParams()
        let profile = BuiltInProfile(reference: recipe.profile) ?? .color
        let look = profile.look

        p.setCameraToWorking(session.cameraToWorking)
        p.setWorkingToDisplay(ColorMatrices.rec2020ToSRGB.floatMatrix)
        p.setDisplayToOutput(encoding == .sRGB ? matrix_identity_float3x3 : sRGBToDisplayP3)

        p.wbRatio = SIMD4(SIMD3<Float>(session.whiteBalanceRatio(for: recipe)), 0)

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

        let full = session.orientedSize
        let lod = max(0, log2(Double(full.longEdge) / Double(max(outputSize.longEdge, 1))))
        p.geometry = SIMD4(
            Float(session.orientation),
            Float(lod),
            encoding.rawValue,
            Float(outputSize.aspectRatio),
        )
        p.outputSize = SIMD4(
            Float(outputSize.width),
            Float(outputSize.height),
            Float(Double(full.width) / Double(max(outputSize.width, 1))),
            0,
        )

        let (layers, components, overlayIndex) = maskBuffers(
            recipe.masks, aspect: outputSize.aspectRatio, overlay: maskOverlay,
        )
        p.masks = SIMD4(
            Float(layers.count), Float(overlayIndex ?? -1), Float(components.count), Float(maskOverlayColor.rawValue),
        )

        let lut = ToneCurveMath.isIdentity(recipe) ? [Float](repeating: 0, count: 4) : ToneCurveMath.lut(for: recipe)
        return DevelopInputs(
            params: p,
            toneLUT: lut,
            mixer: mixer,
            layers: layers.isEmpty ? [.empty] : layers,
            components: components.isEmpty ? [.empty] : components,
        )
    }

    /// Visible masks (plus the overlaid one, even if hidden) as kernel buffers.
    /// Coordinates are aspect-corrected so gradients stay perpendicular and circles round.
    private static func maskBuffers(
        _ masks: [MaskLayer],
        aspect: Double,
        overlay: UUID?,
    ) -> (layers: [MaskLayerGPU], components: [MaskComponentGPU], overlayIndex: Int?) {
        var layers: [MaskLayerGPU] = []
        var components: [MaskComponentGPU] = []
        var overlayIndex: Int?

        for mask in masks where mask.isVisible || mask.id == overlay {
            guard layers.count < MaskLayer.maximumLayers else { break }
            let first = components.count
            for component in mask.components where components.count < MaskLayer.maximumComponents {
                components.append(gpuComponent(component, aspect: aspect))
            }
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
                tone2: SIMD4(value(.localWhites), value(.localBlacks), Float(first), Float(components.count - first)),
            ))
        }
        return (layers, components, overlayIndex)
    }

    private static func gpuComponent(_ component: MaskComponent, aspect: Double) -> MaskComponentGPU {
        let operation: Float = switch component.operation {
        case .add: 0
        case .subtract: 1
        case .intersect: 2
        }
        let inverted: Float = component.inverted ? 1 : 0
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
        }
    }
}
