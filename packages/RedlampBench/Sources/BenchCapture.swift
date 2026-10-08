import Foundation
import ImageIO
import RedlampRecipes

/// Look references and the capture kit (TON-36): the kit as the hub's `look-kit` template, and
/// a finished reference as the inputs the app-look importer reads.
public enum BenchCapture {
    /// The template new look references copy their kit images from: the full kit's charts and
    /// photos and the one-image kit, from the folders `redlamp recipe app-kit` writes. Replaces
    /// an earlier template.
    @discardableResult
    public static func publishKit(full: URL?, compact: URL?, in store: BenchStore) throws -> BenchFolder {
        var assets: [BenchFolder.NewAsset] = []
        for folder in [full, compact].compactMap(\.self) {
            let manifest = try JSONDecoder.bench.decode(
                CaptureKitManifest.self, from: Data(contentsOf: folder.appending(path: CaptureKitManifest.fileName)),
            )
            for file in manifest.files where file.role != "readme" {
                let url = folder.appending(path: file.file)
                switch file.role {
                case "chart":
                    assets.append(.init(file: url, label: "Chart \(file.chart ?? 0)", chart: file.chart))
                case "compact":
                    assets.append(.init(file: url, label: "One-image kit", chart: 9, tiles: file.tiles))
                default:
                    assets.append(.init(file: url, label: (file.subject ?? file.file).capitalizedFirst))
                }
            }
        }
        guard !assets.isEmpty else { throw BenchError.notFound("a capture kit in the folders given") }
        let manifest = BenchManifest(
            id: BenchStore.lookKitID, title: "Capture kit", kind: BenchManifest.Kind.lookKit,
            completion: .manual, pairing: [.captureChart, .fileName, .similarity],
            note: "Kit version \(CaptureChart.kitVersion). New look references copy their images from here.",
        )
        try store.prepare()
        let templates = store.url(.templates)
        if let old = store.folder(BenchStore.lookKitID, in: .templates) {
            try FileManager.default.removeItem(at: old.url)
        }
        return try BenchFolder.create(manifest, assets: assets, in: templates)
    }

    public enum CaptureError: Error, CustomStringConvertible {
        case notALook(String)
        case noCharts(String)

        public var description: String {
            switch self {
            case let .notALook(id): "\(id) isn't a look reference"
            case let .noCharts(id): "\(id) has no chart or one-image kit export back yet"
            }
        }
    }

    /// A finished look reference as the importer's inputs. Its own kit images are the originals,
    /// so it can't be measured against another version of the kit.
    public static func inputs(_ folder: BenchFolder, maxLongEdge: Int = 3072) throws -> CaptureInputs {
        guard let look = folder.manifest.look else { throw CaptureError.notALook(folder.id) }
        /// The full image, resampled as `app-import` resamples a folder's exports, so a
        /// reference measures exactly as the same files would from a folder.
        func image(_ relative: String, long: Int = maxLongEdge) -> PixelImage? {
            guard let url = folder.file(relative), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            return PixelImage(image, maxLongEdge: long)
        }
        var originals = AppLookImport.Originals()
        var charts: [AppLookImport.Export] = []
        var photos: [CaptureInputs.PhotoPair] = []
        var unmatched: [String] = []
        for asset in folder.manifest.assets {
            switch asset.chart {
            case let chart? where (1 ... 3).contains(chart):
                originals.charts[chart - 1] = image(asset.file)
            case 9:
                originals.compact = image(asset.file)
                originals.tileNames = asset.tiles ?? []
            default:
                break
            }
        }
        // Each asset's current result, and the unpaired ones the importer may still place.
        for result in folder.results.results
            where result.asset.map({ folder.results.current(for: $0) == result }) ?? true {
            guard let exported = image(result.file) else { continue }
            let asset = result.asset.flatMap(folder.manifest.asset)
            if let asset, asset.chart == nil, let kitImage = image(asset.file, long: 1024) {
                photos.append(.init(
                    export: result.originalName, exportImage: exported, kitPhoto: asset.label ?? asset.id,
                    kitImage: kitImage, kitFile: folder.file(asset.file),
                    matchedBy: result.pairedBy?.rawValue ?? "hand",
                    similarity: Float(result.score ?? 1),
                ))
            } else if asset?.chart != nil || AppLookImport.locate(exported) != nil {
                let hint = asset?.chart.flatMap { (1 ... 3).contains($0) ? $0 - 1 : nil }
                charts.append(.init(name: result.originalName, image: exported, chartHint: hint))
            } else {
                unmatched.append(result.originalName)
            }
        }
        guard !charts.isEmpty else { throw CaptureError.noCharts(folder.id) }
        return CaptureInputs(
            charts: charts, originals: originals, photos: photos, unmatched: unmatched,
            provenance: .init(app: look.app, filter: look.filter, variant: look.variant, settings: look.settings),
        )
    }
}

extension String {
    var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}
