import CoreGraphics
import Foundation
import ImageIO
import RedlampRecipes

public struct BenchMatch: Sendable, Hashable {
    public var asset: String
    public var method: BenchManifest.Pairing
    public var score: Double?
}

/// Pairs a result with the asset it came from, trying the folder's pairing methods in order: the
/// file name less the suffixes apps add, the capture kit's barcode, then similarity by a clear
/// margin. It holds small copies of the assets, made once, so it works within a share
/// extension's memory.
public final class BenchPairer: @unchecked Sendable {
    /// Similarity's copies: enough for structure, small enough for 20 assets in an extension.
    public static let thumbnailSize = 384
    /// Big enough for the charts' markers and barcode, which `AppLookImport.locate` reads.
    public static let chartSize = 1280
    public static let minimumSimilarity: Float = 0.5
    /// How far the best match must lead the next one.
    public static let margin: Float = 0.08

    private let methods: [BenchManifest.Pairing]
    private let thumbnails: [String: PixelImage]

    public init(folder: BenchFolder) {
        methods = folder.manifest.pairing
        var thumbnails: [String: PixelImage] = [:]
        if methods.contains(.similarity) {
            for asset in folder.manifest.assets {
                if let file = folder.file(asset.file), let image = Self.image(file, maxLongEdge: Self.thumbnailSize) {
                    thumbnails[asset.id] = image
                }
            }
        }
        self.thumbnails = thumbnails
    }

    public func pair(_ file: URL, originalName: String, in folder: BenchFolder) -> BenchMatch? {
        for method in methods {
            let match: BenchMatch? = switch method {
            case .fileName: Self.byName(originalName, assets: folder.manifest.assets)
            case .captureChart: Self.byChart(file, assets: folder.manifest.assets)
            case .similarity: bySimilarity(file, in: folder)
            case .hand: nil
            }
            if let match {
                return match
            }
        }
        return nil
    }

    // MARK: - By name

    /// The asset whose file stem is the result's, or the result's after removing, one at a time,
    /// the suffixes apps add (`-2`, `-Edit`, ` copy`, ` (1)`). The first unique match wins.
    static func byName(_ name: String, assets: [BenchManifest.Asset]) -> BenchMatch? {
        let stems = assets
            .map { (id: $0.id, stem: BenchFile.stem(($0.file as NSString).lastPathComponent).lowercased()) }
        var candidate = BenchFile.stem(name).lowercased()
        while true {
            let matches = stems.filter { $0.stem == candidate || $0.id.lowercased() == candidate }
            if matches.count == 1 {
                return BenchMatch(asset: matches[0].id, method: .fileName, score: nil)
            }
            guard let shorter = stripSuffix(candidate) else { return nil }
            candidate = shorter
        }
    }

    private static let suffixes: [NSRegularExpression] = [
        #"[-_ ](edit|edited|copy)([-_ ]?\d+)?$"#,
        #" \(\d+\)$"#,
        #"[-_ ]\d{1,3}$"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    static func stripSuffix(_ stem: String) -> String? {
        let range = NSRange(stem.startIndex..., in: stem)
        for pattern in suffixes {
            if let match = pattern.firstMatch(in: stem, range: range), let found = Range(match.range, in: stem) {
                let shorter = String(stem[..<found.lowerBound])
                return shorter.isEmpty ? nil : shorter
            }
        }
        return nil
    }

    // MARK: - By the capture kit's barcode

    static func byChart(_ file: URL, assets: [BenchManifest.Asset]) -> BenchMatch? {
        guard assets.contains(where: { $0.chart != nil }),
              let image = image(file, maxLongEdge: chartSize),
              let location = AppLookImport.locate(image),
              let chart = location.chart else { return nil }
        let number = location.layout.barcodeNumber(chart: chart)
        guard let asset = assets.first(where: { $0.chart == number }) else { return nil }
        return BenchMatch(asset: asset.id, method: .captureChart, score: nil)
    }

    // MARK: - By similarity

    /// The asset most like the result, among those still without a result first, then all of
    /// them; only above `minimumSimilarity` and `margin` ahead of the next best.
    func bySimilarity(_ file: URL, in folder: BenchFolder) -> BenchMatch? {
        guard !thumbnails.isEmpty, let result = Self.image(file, maxLongEdge: Self.thumbnailSize) else { return nil }
        let scores = folder.manifest.assets.compactMap { asset -> (id: String, score: Float)? in
            thumbnails[asset.id].map { (asset.id, PhotoPairAnalysis.similarity($0, result)) }
        }
        let open = scores.filter { folder.results.current(for: $0.id) == nil }
        return Self.best(open) ?? Self.best(scores)
    }

    static func best(_ scores: [(id: String, score: Float)]) -> BenchMatch? {
        let ranked = scores.sorted { $0.score > $1.score }
        guard let first = ranked.first, first.score >= minimumSimilarity else { return nil }
        if ranked.count > 1, first.score - ranked[1].score < margin {
            return nil
        }
        return BenchMatch(asset: first.id, method: .similarity, score: Double(first.score))
    }

    // MARK: - Images

    /// A small copy of an image file, oriented, through ImageIO's thumbnailer, which reads raws'
    /// previews too.
    public static func image(_ url: URL, maxLongEdge: Int) -> PixelImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxLongEdge,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return PixelImage(image, maxLongEdge: maxLongEdge)
    }
}
