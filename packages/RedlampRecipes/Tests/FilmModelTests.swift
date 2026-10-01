import Foundation
import RedlampEngineAPI
import simd
import Testing
@testable import RedlampRecipes

struct FilmModelTests {
    @Test func `spectra reproduce the colours they came from`() {
        let upsampler = SpectralUpsampler()
        let white = Colorimetry.xyz(upsampler.illuminant)
        let toD65 = Colorimetry.adaptation(from: white, to: Colorimetry.whiteD65)
        for rgb in [SIMD3(0.18, 0.18, 0.18), SIMD3(0.45, 0.30, 0.22), SIMD3(0.20, 0.35, 0.60), SIMD3(0.1, 0.4, 0.12)] {
            let xyz = Colorimetry.xyz(upsampler.radiance(rgb)) / white.y
            let back = Colorimetry.xyzToRec2020 * (toD65 * xyz)
            #expect(simd_length(back - rgb) < 2e-3, "\(rgb) came back as \(back)")
        }
    }

    static let data = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("../../../research/film-data").standardizedFileURL

    static func stock(_ id: String) throws -> FilmStock {
        try FilmLooks.stock(id, in: data)
    }

    static var models: [(String, FilmModel)] {
        get throws {
            try [
                ("negative", FilmModel(film: .syntheticNegative, print: .syntheticPrint)),
                ("reversal", FilmModel(film: .syntheticReversal)),
                ("monochrome", FilmModel(film: .syntheticMonochrome, print: .syntheticPaper)),
                ("scanned negative", FilmModel(film: .syntheticNegative)),
                ("Portra scan", FilmModel(film: stock("kodak-portra-400"))),
                ("Vision3 on 2383", FilmModel(film: stock("kodak-vision3-500t"), print: stock("kodak-2383"))),
                ("Provia", FilmModel(film: stock("fuji-provia-100f"))),
                (
                    "Tri-X on Multigrade",
                    FilmModel(film: stock("kodak-tri-x-400"), print: stock("ilford-multigrade-rc")),
                ),
                ("HP5 scan", FilmModel(film: stock("ilford-hp5-plus"))),
            ]
        }
    }

    @Test func `every datasheet loads`() throws {
        for id in FilmLooks.stockIDs(in: Self.data) {
            let stock = try FilmLooks.stock(id, in: Self.data)
            #expect(stock.curves.count == stock.layerCount, "\(id)")
            #expect(stock.sensitivities.allSatisfy { $0.values.max() ?? 0 > 0 }, "\(id)")
        }
    }

    @Test func `mid-grey displays neutral at the chosen brightness`() throws {
        for (name, model) in try Self.models {
            let grey = model.display(SIMD3(repeating: 0.18))
            #expect(abs(grey.max() - grey.min()) < 2e-3, "\(name): \(grey)")
            #expect(abs(grey.y - model.parameters.displayGrey) < 2e-3, "\(name): \(grey)")
        }
    }

    @Test func `a grey ramp gets brighter all the way from deep shadow to extreme highlight`() throws {
        for (name, model) in try Self.models {
            var previous = -1.0
            for ev in stride(from: -9.0, through: 6.0, by: 0.25) {
                let y = model.display(SIMD3(repeating: 0.18 * pow(2, ev))).y
                #expect(y >= previous - 1e-6, "\(name) darkens at \(ev) EV")
                previous = y
            }
            #expect(previous > 0.8, "\(name) never reaches near white: \(previous)")
        }
    }

    @Test func `every catalogue look builds a recipe with its effects`() throws {
        for look in FilmLookCatalog.looks {
            let recipe = try FilmLooks.recipe(for: look, size: 9, data: Self.data)
            #expect(recipe.includes.isSuperset(of: [.baseLook, .effects]), "\(look.id)")
            #expect(recipe.settings[.grainAmount] > 0, "\(look.id)")
            #expect(recipe.embeddedBaseLooks.first?.table != nil, "\(look.id)")
            let monochrome = try FilmLooks.stock(look.film, in: Self.data).kind.isMonochrome
            #expect((recipe.settings.treatment == .blackAndWhite) == monochrome, "\(look.id)")
        }
        #expect(Set(FilmLookCatalog.looks.map(\.id)).count == FilmLookCatalog.looks.count)
    }

    @Test func `every film look ships, matching what its datasheets build`() throws {
        for look in FilmLookCatalog.looks {
            let shipped = try #require(
                BuiltInBaseLooks.package(id: look.baseLookID, version: look.version),
                "\(look.id) isn't bundled; run `redlamp recipe film --all --install`",
            )
            let built = try FilmLooks.bundledPackage(for: look, data: Self.data)
            // Values rather than hashes: libm may round differently on another OS release.
            let a = try #require(try shipped.definition().table), b = try #require(try built.definition().table)
            let worst = zip(a.values, b.values).map { abs(Float($0) - Float($1)) }.max() ?? 0
            #expect(worst < 2e-3, "\(look.id): the look changed; bump its version and reinstall")
            let recipe = try #require(BuiltInRecipes.recipe(id: look.recipeID), "\(look.id) has no bundled recipe")
            #expect(recipe.baseLook == shipped.reference)
            #expect(recipe.group == "Film Stocks")
            #expect(FilmLookCatalog.look(forBundledID: shipped.id) == look)
            #expect(
                try look.isMonochrome == (FilmLooks.stock(look.film, in: Self.data).kind.isMonochrome),
                "\(look.id)",
            )
        }
    }

    @Test func `every film icon draws`() throws {
        for look in FilmLookCatalog.looks {
            let image = try #require(look.icon.image(pixels: 64), "\(look.id)")
            #expect(image.width == 64 && image.height == 64)
            let data = try #require(image.dataProvider?.data as Data?)
            let opaque = stride(from: 3, to: data.count, by: 4).count { data[$0] > 200 }
            #expect(opaque > 64 * 64 / 4, "\(look.id): the icon is mostly empty")
        }
    }

    @Test func `scanner profiles keep mid-grey neutral`() throws {
        for scanner in ScannerProfile.allCases {
            var parameters = FilmLookParameters()
            parameters.scanner = scanner
            let grey = try FilmModel(film: Self.stock("kodak-portra-400"), parameters: parameters)
                .display(SIMD3(repeating: 0.18))
            #expect(grey.max() - grey.min() < 2e-3, "\(scanner): \(grey)")
        }
    }

    @Test func `the look is a scene-referred table`() throws {
        let table = try FilmModel(film: .syntheticNegative, print: .syntheticPrint).table(size: 9)
        #expect(table.space == .sceneLog)
        #expect(table.size == 9)
    }
}
