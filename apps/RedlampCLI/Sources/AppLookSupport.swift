import CoreGraphics
import CoreText
import Foundation
import RedlampEngineAPI
import RedlampRecipes

extension AppLookCommands {
    struct KitPhoto {
        var file: CaptureKitManifest.File
        var url: URL
        var image: PixelImage
    }

    struct ExportedPhoto {
        var name: String
        var image: PixelImage
    }

    struct PhotoMatch {
        var export: Int
        var kit: Int
        /// `name` or `content`.
        var by: String
        var similarity: Float
    }

    /// A folder of exports (or one compact export) and the kit they came from.
    struct Session {
        var kit: URL
        var manifest: CaptureKitManifest?
        var charts: [AppLookImport.Export] = []
        var locations: [AppLookImport.Location] = []
        var photos: [ExportedPhoto] = []
        var kitPhotos: [KitPhoto] = []

        var isCompact: Bool {
            !locations.isEmpty && locations.allSatisfy { $0.layout.kind == .compact }
        }

        /// `kit` nil picks the generated kit that matches the exports' layout.
        static func load(path: URL, kit: URL?) throws -> Session {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isFolder) else {
                throw CLIError(description: "\(path.path) doesn't exist")
            }
            let files = isFolder.boolValue
                ? try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil)
                .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                : [path]
            var session = Session(kit: kit ?? Repository.root.appendingPathComponent(kitFolder))
            for file in files {
                guard let image = try PixelImage(ImageFile.read(file), maxLongEdge: 3072) else { continue }
                let name = file.lastPathComponent
                if let location = AppLookImport.locate(image) {
                    session.charts.append(AppLookImport.Export(
                        name: name, image: image, chartHint: CaptureKitManifest.chartHint(name),
                    ))
                    session.locations.append(location)
                } else {
                    session.photos.append(ExportedPhoto(name: name, image: image))
                }
            }
            if kit == nil, session.isCompact {
                session.kit = Repository.root.appendingPathComponent(compactKitFolder)
            }
            session.manifest = try? JSONDecoder.iso8601.decode(
                CaptureKitManifest.self,
                from: Data(contentsOf: session.kit.appendingPathComponent(CaptureKitManifest.fileName)),
            )
            if session.manifest == nil {
                print("no kit at \(session.kit.path): charts use the layout's values and photos are skipped")
            }
            session.kitPhotos = (session.manifest?.photos ?? []).compactMap { file in
                let url = session.kit.appendingPathComponent(file.file)
                guard let image = try? PixelImage(ImageFile.read(url), maxLongEdge: 1024) else { return nil }
                return KitPhoto(file: file, url: url, image: image)
            }
            let compact = session.locations.count(where: { $0.layout.kind == .compact })
            print(
                "\(session.charts.count - compact) charts, \(compact) one-image exports, "
                    + "\(session.photos.count) photos in \(path.lastPathComponent)",
            )
            return session
        }

        /// The kit's own files, for exact input colours and the compact image's photo tiles.
        func originals() -> AppLookImport.Originals {
            var originals = AppLookImport.Originals()
            for chart in manifest?.charts ?? [] {
                if let number = chart.chart,
                   let image = try? PixelImage(ImageFile.read(kit.appendingPathComponent(chart.file))) {
                    originals.charts[number - 1] = image
                }
            }
            if let file = manifest?.compact {
                originals.compact = try? PixelImage(ImageFile.read(kit.appendingPathComponent(file.file)))
                originals.tileNames = file.tiles ?? []
            }
            return originals
        }

        /// The session as the importer's inputs, with the photos paired by `matches`.
        func inputs(_ matches: [PhotoMatch], provenance: AppLookReport.Provenance) -> CaptureInputs {
            CaptureInputs(
                charts: charts, originals: originals(),
                compactKitFile: manifest?.compact.map { kit.appendingPathComponent($0.file) },
                photos: matches.map { match in
                    let kitPhoto = kitPhotos[match.kit], export = photos[match.export]
                    return CaptureInputs.PhotoPair(
                        export: export.name, exportImage: export.image, kitPhoto: kitPhoto.file.file,
                        kitImage: kitPhoto.image, kitFile: kitPhoto.url, matchedBy: match.by,
                        similarity: match.similarity,
                    )
                },
                unmatched: photos.indices.filter { photo in !matches.contains { $0.export == photo } }
                    .map { photos[$0].name },
                provenance: provenance,
            )
        }
    }

    /// Pairs exports with kit photos: by the kit's file name when the app kept it, otherwise
    /// by image structure.
    static func match(_ exports: [ExportedPhoto], _ kit: [KitPhoto]) -> [PhotoMatch] {
        var result: [PhotoMatch] = []
        var usedKit = Set<Int>(), usedExport = Set<Int>()
        for (e, export) in exports.enumerated() {
            let lower = export.name.lowercased()
            if let k = kit.indices.first(where: {
                !usedKit.contains($0) && lower.contains(kit[$0].url.deletingPathExtension().lastPathComponent)
            }) {
                result.append(PhotoMatch(
                    export: e, kit: k, by: "name", similarity: PhotoPairAnalysis.similarity(kit[k].image, export.image),
                ))
                usedKit.insert(k)
                usedExport.insert(e)
            }
        }
        var scores: [PhotoMatch] = []
        for e in exports.indices where !usedExport.contains(e) {
            for k in kit.indices where !usedKit.contains(k) {
                scores.append(PhotoMatch(
                    export: e, kit: k, by: "content",
                    similarity: PhotoPairAnalysis.similarity(kit[k].image, exports[e].image),
                ))
            }
        }
        for score in scores.sorted(by: { $0.similarity > $1.similarity }) where score.similarity > 0.5 {
            guard !usedExport.contains(score.export), !usedKit.contains(score.kit) else { continue }
            result.append(score)
            usedExport.insert(score.export)
            usedKit.insert(score.kit)
        }
        return result.sorted { $0.kit < $1.kit }
    }

    /// One row per matched photo (and the first chart): the kit image, the app's export, and
    /// the new look. Photos made from look-dev raws are rendered by the engine with the recipe;
    /// the charts and the portraits have no raw, so the table and vignette are applied directly.
    static func contactSheet(
        _ recipe: Recipe,
        _ result: AppLookImport.Result,
        renderer: RecipeRenderer,
        _ session: Session,
        _ matches: [PhotoMatch],
    ) async throws -> CGImage {
        let vignette = result.report.vignette?.model
        func preview(_ image: PixelImage) -> CGImage? {
            let small = image.cgImage().flatMap { PixelImage($0, maxLongEdge: 720) } ?? image
            return PhotoPairAnalysis.preview(small, table: result.table, vignette: vignette).cgImage()
        }
        var rows: [[CGImage?]] = []
        if session.isCompact, let export = session.charts.first, let location = session.locations.first,
           let original = session.originals().compact {
            rows.append([original.cgImage(), export.image.cgImage(), preview(original)])
            rows += compactTiles(original, export.image, location).map { kit, exported in
                [kit.cgImage(), exported.cgImage(), preview(kit)]
            }
        } else if let chart = session.charts.first,
                  let number = session.locations.first?.chart ?? chart.chartHint,
                  let file = session.manifest?.charts.first(where: { $0.chart == number + 1 }),
                  let original = try? PixelImage(ImageFile.read(session.kit.appendingPathComponent(file.file))) {
            rows.append([original.cgImage(), chart.image.cgImage(), preview(original)])
        }
        for match in matches {
            let kitPhoto = session.kitPhotos[match.kit]
            let raw = kitPhoto.file.source?.raw.map {
                LookDevSet.folder(root: Repository.root).appendingPathComponent($0)
            }
            let rendered: CGImage? = if let raw, FileManager.default.fileExists(atPath: raw.path) {
                try await renderer.render(recipe, image: raw, maxLongEdge: 720)
            } else {
                preview(kitPhoto.image)
            }
            rows.append([kitPhoto.image.cgImage(), session.photos[match.export].image.cgImage(), rendered])
        }
        return try grid(rows, titles: ["Kit original", "App export", "Redlamp: \(recipe.name)"])
    }

    /// Each photo tile of the compact kit and the same region of the export.
    static func compactTiles(
        _ kit: PixelImage,
        _ export: PixelImage,
        _ location: AppLookImport.Location,
    ) -> [(PixelImage, PixelImage)] {
        location.layout.photoTiles.compactMap { tile in
            let target = location.transform.apply(tile).integral
            guard target.minX >= 0, target.minY >= 0,
                  target.maxX <= CGFloat(export.width), target.maxY <= CGFloat(export.height) else { return nil }
            return (crop(kit, tile), crop(export, target))
        }
    }

    static func crop(_ image: PixelImage, _ rect: CGRect) -> PixelImage {
        var pixels: [SIMD3<Float>] = []
        for y in Int(rect.minY) ..< Int(rect.maxY) {
            for x in Int(rect.minX) ..< Int(rect.maxX) {
                pixels.append(image[x, y])
            }
        }
        return PixelImage(width: Int(rect.width), height: Int(rect.height), pixels: pixels)
    }

    static func grid(_ rows: [[CGImage?]], titles: [String], tile: Int = 360) throws -> CGImage {
        let gap = 6, labelHeight = 22, tileHeight = tile * 3 / 4
        let width = gap + titles.count * (tile + gap)
        let height = labelHeight + gap + max(rows.count, 1) * (tileHeight + gap)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        ) else { throw CLIError(description: "cannot draw the contact sheet") }
        context.setFillColor(CGColor(gray: 0.16, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (column, title) in titles.enumerated() {
            label(title, in: context, at: CGPoint(x: gap + column * (tile + gap) + 2, y: height - labelHeight + 6))
        }
        context.interpolationQuality = .high
        for (row, images) in rows.enumerated() {
            let y = height - labelHeight - (row + 1) * (tileHeight + gap)
            for (column, image) in images.enumerated() {
                guard let image else { continue }
                let box = CGRect(x: gap + column * (tile + gap), y: y, width: tile, height: tileHeight)
                let scale = min(box.width / CGFloat(image.width), box.height / CGFloat(image.height))
                let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                context.draw(image, in: CGRect(
                    x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height,
                ))
            }
        }
        guard let sheet = context.makeImage() else { throw CLIError(description: "cannot draw the contact sheet") }
        return sheet
    }

    static func label(_ text: String, in context: CGContext, at point: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
                "Helvetica" as CFString,
                12,
                nil,
            ),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.92, alpha: 1),
        ]
        context.textPosition = point
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
    }
}

extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
