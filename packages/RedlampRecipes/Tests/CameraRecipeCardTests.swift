import Foundation
import RedlampEngineAPI
import RedlampRecipes
import Testing

/// Pins mapping version 1. A failing test here means the mapping changed: bump
/// `CameraRecipeCard.mappingVersion` and document the new row instead of editing these.
struct CameraRecipeCardTests {
    @Test func `mapping version 1 translates every field`() {
        let card = CameraRecipeCard(
            filmSimulation: .chrome,
            dynamicRange: .dr400,
            highlight: -1,
            shadow: 1.5,
            color: -2,
            colorChrome: .strong,
            chromeFxBlue: .weak,
            whiteBalance: .init(mode: "auto", shiftRed: 2, shiftBlue: -4),
            grain: .init(strength: .weak, size: .large),
            clarity: -2,
            sharpness: -1,
            noiseReduction: -4,
            exposure: 0.33,
        )
        let settings = card.resolvedSettings()
        #expect(settings.values == [
            .exposure: 0.33,
            .highlights: -12,
            .whites: -5,
            .shadows: -18,
            .blacks: -7.5,
            .dynamicRange: 400,
            .saturation: -14,
            .colorChrome: 85,
            .colorChromeBlue: 45,
            .wbShiftRed: 22,
            .wbShiftBlue: -44,
            .grainAmount: 22,
            .grainSize: 55,
            .clarity: -16,
            .sharpenAmount: 30,
        ])
        #expect(settings.whiteBalanceMode == .auto)
        #expect(settings.treatment == .color)
    }

    @Test func `neutral card is nearly a no-op`() {
        let settings = CameraRecipeCard().resolvedSettings()
        // Noise reduction 0 is the camera's default, a light 12 here.
        #expect(settings.values == [.noiseLuminance: 12])
    }

    @Test func `out of range values are clamped to the camera's steps`() {
        let card = CameraRecipeCard(
            highlight: 9,
            shadow: -7.3,
            color: 12,
            whiteBalance: .init(mode: "kelvin", kelvin: 99999, shiftRed: 40),
        )
        let clamped = card.clamped
        #expect(clamped.highlight == 4)
        #expect(clamped.shadow == -2)
        #expect(clamped.color == 4)
        #expect(clamped.whiteBalance.shiftRed == 9)
        #expect(clamped.whiteBalance.kelvin == 10000)
        let settings = card.resolvedSettings()
        #expect(settings.whiteBalanceMode == .custom)
        #expect(settings.values[.temperature] == 10000)
    }

    @Test func `monochrome slots switch to black and white and tone`() {
        let card = CameraRecipeCard(filmSimulation: .monochromeRed, monochromeWarmCool: 3)
        let recipe = card.recipe(id: "local/mono", name: "Mono")
        #expect(recipe.settings.treatment == .blackAndWhite)
        #expect(recipe.settings.values[.gradeGlobalHue] == 45)
        #expect(recipe.settings.values[.gradeGlobalSaturation] == 9)
        #expect(recipe.lintWaivers.contains("neutral-axis"))
    }

    @Test func `the card survives in the file and re-resolves when edited`() throws {
        let card = CameraRecipeCard(filmSimulation: .negativeClassic, color: 3)
        let recipe = card.recipe(id: "local/card", name: "Card")
        let decoded = try RecipeValidator.decode(RecipeFile.encode(recipe)).recipe
        #expect(decoded.cameraCard == card)
        #expect(decoded == recipe)
        var edited = card
        edited.color = -1
        let updated = decoded.updatingCard(edited)
        #expect(updated.settings.values[.saturation] == -7)
        #expect(updated.id == recipe.id)
        #expect(updated.cameraCard == edited)
    }

    @Test func `every slot resolves to a Base Look`() {
        for slot in FilmSlot.allCases {
            let reference = slot.baseLook
            #expect(!reference.id.isEmpty, "\(slot)")
        }
    }
}
