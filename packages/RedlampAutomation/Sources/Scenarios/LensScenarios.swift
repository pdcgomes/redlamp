#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import ImageIO
    import RedlampLibrary
    @_spi(Harness) import RedlampUI
    import UniformTypeIdentifiers

    /// The traits the lens's fields give (LIB-06), on a scratch folder of JPEGs whose EXIF says how each was shot.
    enum LensScenarios {
        static let all: [Scenario] = [traits]

        /// A photo of the scratch folder: its camera, lens, focal length, the 35 mm focal length its camera wrote (none
        /// for the Canon, whose crop factor the library knows) and f-number.
        struct Shot {
            let name: String
            let make: String
            let model: String
            let lens: String
            let focal: Double
            let focal35: Int?
            let aperture: Double
        }

        /// Telephoto: 200 mm, 85 mm, and 50 mm on APS-C (80 mm). Ultra wide: 16 mm. Wide open: f/2.8 on the f/2.8 zoom,
        /// and the two f/1.8 primes at f/1.8.
        static let shots = [
            Shot(
                name: "Tele.jpg", make: "SONY", model: "ILCE-7M4", lens: "FE 70-200mm F2.8 GM OSS II", focal: 200,
                focal35: 200, aperture: 8,
            ),
            Shot(
                name: "Wide.jpg", make: "SONY", model: "ILCE-7M4", lens: "FE 16-35mm F2.8 GM", focal: 16, focal35: 16,
                aperture: 2.8,
            ),
            Shot(
                name: "Portrait.jpg", make: "SONY", model: "ILCE-7M4", lens: "FE 85mm F1.8", focal: 85, focal35: 85,
                aperture: 1.8,
            ),
            Shot(
                name: "Street.jpg", make: "SONY", model: "ILCE-7M4", lens: "FE 35mm F1.8", focal: 35, focal35: 35,
                aperture: 5.6,
            ),
            Shot(
                name: "Crop.jpg", make: "Canon", model: "Canon EOS 90D", lens: "EF50mm f/1.8 STM", focal: 50,
                focal35: nil, aperture: 1.8,
            ),
        ]

        static let traits = Scenario(
            "library.lens-traits",
            "is:telephoto, is:ultra-wide and is:wide-open in the filter bar's text find the photos their lenses' "
                + "widest apertures and 35 mm focal lengths make so, Tab completes a trait with its count, and the "
                + "35 mm Focal Length column chooses by it",
            claims: [.feature("library.filter")],
        ) { app in
            let scratch = try SourcesScratch(app, photos: shots.map(\.name))
            defer { app.removeScratch(scratch) }
            for (number, shot) in shots.enumerated() {
                try jpeg(shot, number: number).write(to: scratch.photo(shot.name))
            }
            try scratch.index(app)
            defer { try? app.resetFilter() }
            try app.main { $0.libraryFilters?.setFilter(LibraryFilter()) }
            if try !app.main({ $0.libraryFilters?.isBarShown ?? false }) {
                try app.press(.toggleFilterBar)
            }
            try app.wait("the filter bar's text to take the keyboard") { _ in
                (Views.editorWindow?.firstResponder as? NSTextView)?.delegate is NSTextField
            }

            try app.typeQuery("is:telephoto")
            try app.wait("the 200 mm, the 85 mm and the 50 mm on APS-C", timeout: 20) { model in
                names(model) == ["Crop.jpg", "Portrait.jpg", "Tele.jpg"]
            }
            try clear(app)
            try app.typeQuery("is:ultra")
            try app.wait("Ultra Wide offered, with the folder's one") { model in
                model.libraryFilters?.completions.first.map { $0.text == "is:ultra-wide " && $0.count == 1 } == true
            }
            try app.pressInWindow(KeyCombo(.tab))
            try app.wait("Tab to take it, and the 16 mm alone", timeout: 20) { model in
                model.libraryFilters?.filter.text == "is:ultra-wide " && names(model) == ["Wide.jpg"]
            }
            try clear(app)
            try app.typeQuery("is:wide-open")
            try app.wait("the photos shot at their lenses' widest apertures", timeout: 20) { model in
                names(model) == ["Crop.jpg", "Portrait.jpg", "Wide.jpg"]
            }
            app.covered(.feature("library.filter"), via: .key)
            try clear(app)

            try app.main { $0.libraryFilters?.setColumns([.focal35, .widestAperture]) }
            try app.clickView("library.filter.metadata", modifiers: .shift)
            try app.wait("the Metadata section") { model in
                model.libraryFilters?.filter.sections.contains(.metadata) == true
            }
            try app.wait("the 35 mm focal lengths counted, the Canon's from its crop factor", timeout: 20) { model in
                let values = model.libraryFilters?.columns[0]?.values.compactMap(\.name) ?? []
                return Set(values) == ["16", "35", "80", "85", "200"]
            }
            try app.wait("the 16 mm row on screen") { _ in
                Views.editorWindow.flatMap { Views.find("library.filter.column.0.value.16", in: $0) } != nil
            }
            try app.clickView("library.filter.column.0.value.16")
            try app.wait("the row's filter in the text, and the 16 mm alone", timeout: 20) { model in
                model.libraryFilters?.filter.text == "focal35:16" && names(model) == ["Wide.jpg"]
            }
            try app.wait("the Widest Aperture column counting it alone, at f/2.8", timeout: 20) { model in
                model.libraryFilters?.columns[1].map { $0.total == 1 && $0.values.first?.name == "2.8" } == true
            }
            app.covered(.feature("library.filter"), via: .mouse)
        }

        @MainActor private static func names(_ model: EditorModel) -> [String] {
            model.items.map(\.name).sorted()
        }

        /// The text emptied, and every photo of the scratch back.
        private static func clear(_ app: RunningApp) throws {
            try app.main { $0.libraryFilters?.setFilter(LibraryFilter()) }
            try app.wait("every photo back", timeout: 20) { $0.items.count == shots.count }
        }

        /// A small JPEG of its own colour, with `shot`'s camera, lens and exposure in its EXIF, a second apart.
        static func jpeg(_ shot: Shot, number: Int) throws -> Data {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: nil, width: 96, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
                  )
            else { throw ScenarioFailure("No bitmap context") }
            context.setFillColor(red: CGFloat(number % 5) / 5, green: 0.4, blue: CGFloat(number % 3) / 3, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
            var exif: [CFString: Any] = [
                kCGImagePropertyExifLensModel: shot.lens, kCGImagePropertyExifFocalLength: shot.focal,
                kCGImagePropertyExifFNumber: shot.aperture,
                kCGImagePropertyExifDateTimeOriginal: String(format: "2026:10:01 12:00:%02d", number),
            ]
            if let focal35 = shot.focal35 {
                exif[kCGImagePropertyExifFocalLenIn35mmFilm] = focal35
            }
            let properties: [CFString: Any] = [
                kCGImagePropertyTIFFDictionary: [
                    kCGImagePropertyTIFFMake: shot.make,
                    kCGImagePropertyTIFFModel: shot.model,
                ],
                kCGImagePropertyExifDictionary: exif,
            ]
            let data = NSMutableData()
            guard let image = context.makeImage(),
                  let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
            else { throw ScenarioFailure("No JPEG encoder") }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw ScenarioFailure("The JPEG wasn't written") }
            return data as Data
        }
    }
#endif
