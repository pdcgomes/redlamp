import CryptoKit
import Foundation
import RedlampEngineAPI

/// `kit.json`: every file of an app-look capture kit, so exports can be matched to what
/// was sent to the phone.
public struct CaptureKitManifest: Codable, Sendable {
    public static let fileName = "kit.json"

    public struct Source: Codable, Sendable, Hashable {
        public var title: String?
        public var author: String?
        public var license: String
        public var url: String
        /// The page the licence was checked on.
        public var page: String?
        /// The raw file a photo was rendered from, in the look-development set.
        public var raw: String?

        public init(
            title: String? = nil,
            author: String? = nil,
            license: String,
            url: String,
            page: String? = nil,
            raw: String? = nil,
        ) {
            self.title = title
            self.author = author
            self.license = license
            self.url = url
            self.page = page
            self.raw = raw
        }
    }

    public struct File: Codable, Sendable, Hashable {
        public var file: String
        /// `chart`, `compact`, `photo` or `readme`.
        public var role: String
        /// 1-based chart number.
        public var chart: Int?
        public var subject: String?
        public var sha256: String
        public var bytes: Int
        public var width: Int?
        public var height: Int?
        public var source: Source?
        /// A compact image's photo tiles, in order: the subjects.
        public var tiles: [String]?

        public init(
            file: String,
            role: String,
            chart: Int? = nil,
            subject: String? = nil,
            data: Data,
            width: Int? = nil,
            height: Int? = nil,
            source: Source? = nil,
            tiles: [String]? = nil,
        ) {
            self.file = file
            self.role = role
            self.chart = chart
            self.subject = subject
            sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            bytes = data.count
            self.width = width
            self.height = height
            self.source = source
            self.tiles = tiles
        }
    }

    public var kit = "redlamp-capture-kit"
    public var version = CaptureChart.kitVersion
    /// nil in manifests written before the compact kit, which were all `full`.
    public var layout: CaptureLayout.Kind?
    public var created: Date
    public var lattice: Int
    public var files: [File]

    public init(layout: CaptureLayout = .full, created: Date = Date(), files: [File]) {
        self.layout = layout.kind
        lattice = layout.lattice
        self.created = created
        self.files = files
    }

    public static let compactFileName = "redlamp-kit.png"

    public var compact: File? {
        files.first { $0.role == "compact" }
    }

    public var charts: [File] {
        files.filter { $0.role == "chart" }
    }

    public var photos: [File] {
        files.filter { $0.role == "photo" }
    }

    public static func chartFileName(_ chart: Int) -> String {
        "redlamp-kit-chart-\(chart + 1).png"
    }

    /// The chart a file name points at, for exports that kept the kit's name.
    public static func chartHint(_ fileName: String) -> Int? {
        let lower = fileName.lowercased()
        guard let range = lower.range(of: "chart-") ?? lower.range(of: "chart_") ?? lower.range(of: "chart"),
              let digit = lower[range.upperBound...].first?.wholeNumberValue,
              (1 ... CaptureChart.chartCount).contains(digit) else { return nil }
        return digit - 1
    }
}

public extension AppLookReport.Photo {
    init(
        file: String,
        kitPhoto: String,
        matchedBy: String,
        similarity: Float,
        measures: PhotoPairAnalysis.Measures,
    ) {
        self.init(
            file: file, kitPhoto: kitPhoto, matchedBy: matchedBy, similarity: Double(similarity),
            residualMeanDeltaE: Double(measures.residualMean), residualP90DeltaE: Double(measures.residualP90),
            vignette: measures.vignette, cornerGain: measures.cornerGain.map(Double.init),
            grainLuma: Double(measures.grainLuma), sharpness: Double(measures.sharpness),
            glow: Double(measures.glow),
        )
    }
}

public extension AppLookReport.Provenance {
    init(app: String?, filter: String?, variant: String? = nil, settings: String? = nil) {
        self.init(app: app, filter: filter, captured: Date(), variant: variant, settings: settings)
    }
}

public extension AppLookReport {
    /// Adds photo measurements; when the charts gave no vignette, the photos' median one is used.
    mutating func add(photos: [Photo]) {
        self.photos += photos
        let measured = self.photos.compactMap { photo in photo.vignette.map { ($0, photo.cornerGain ?? 1) } }
            .sorted { $0.0.amount < $1.0.amount }
        if vignette == nil, !measured.isEmpty {
            let (model, corner) = measured[measured.count / 2]
            vignette = Vignette(
                model: model, frame: "export", cornerGain: corner, fitRMS: 0, irregularity: 0,
                cornerTint: [1, 1, 1], source: "photos",
            )
        }
        let adaptive = self.photos.filter { $0.residualMeanDeltaE > 4 }
        if !adaptive.isEmpty {
            warnings.append(
                "\(adaptive.count) photo(s) differ from the table by more than ΔE 4: the filter may adapt to "
                    + "each image, or add local effects a table can't hold",
            )
        }
        if self.photos.contains(where: { $0.glow > 0.03 }) {
            warnings.append("glow or bloom around highlights: not captured (Redlamp has no halation stage yet)")
        }
    }
}

/// A captured look as a recipe: the measured table as an embedded Base Look, plus the
/// vignette and grain the kit measured.
public enum AppLookRecipe {
    public static let dialect = "redlamp.app-capture"
    /// Effects weaker than this are left at their defaults.
    static let minimumEffect = 3.0

    public static func make(
        _ result: AppLookImport.Result,
        name: String,
        id: String = RecipeNamespace.newLocalID(),
    ) throws -> Recipe {
        let table = try result.baseLookTable()
        var recipe = LookTableImport.recipe(for: table, name: name, id: id)
        recipe.summary = "Measured with the Redlamp capture kit."
        recipe.tags = ["lut", "captured"]
        recipe.embeddedBaseLooks = recipe.embeddedBaseLooks.map { look in
            var look = look
            look.summary = "Measured look table"
            return look
        }
        var values: [ParameterID: Double] = [:]
        if let vignette = result.report.vignette, abs(vignette.model.amount) >= minimumEffect {
            values[.vignetteAmount] = vignette.model.amount.rounded()
            values[.vignetteMidpoint] = vignette.model.midpoint.rounded()
            values[.vignetteFeather] = vignette.model.feather.rounded()
        }
        if let grain = result.report.grain, grain.suggestedAmount >= minimumEffect {
            values[.grainAmount] = grain.suggestedAmount
            values[.grainSize] = grain.suggestedSize
        }
        if !values.isEmpty {
            recipe.includes.insert(.effects)
            recipe.settings = RecipeSettings(values: values)
        }
        recipe.source = .other(dialect: dialect, payload: payload(result.report))
        return recipe
    }

    /// The private provenance and measurement summary kept with the recipe.
    static func payload(_ report: AppLookReport) -> [String: JSONValue] {
        var provenance: [String: JSONValue] = [:]
        if let app = report.provenance?.app {
            provenance["app"] = .string(app)
        }
        if let filter = report.provenance?.filter {
            provenance["filter"] = .string(filter)
        }
        if let variant = report.provenance?.variant {
            provenance["variant"] = .string(variant)
        }
        if let settings = report.provenance?.settings {
            provenance["settings"] = .string(settings)
        }
        if let captured = report.provenance?.captured {
            provenance["captured"] = .string(ISO8601DateFormatter().string(from: captured))
        }
        var measured: [String: JSONValue] = [
            "patchesMeasured": .number(Double(report.patchesMeasured)),
            "patchesFilled": .number(Double(report.patchesFilled)),
            "nonMonotonic": .bool(report.tone.nonMonotonic),
            "clipped": .bool(report.tone.clipped),
        ]
        if let mean = report.residuals.rampMeanDeltaE {
            measured["rampMeanDeltaE"] = .number((mean * 100).rounded() / 100)
        }
        if let vignette = report.vignette {
            measured["vignetteCornerGain"] = .number((vignette.cornerGain * 1000).rounded() / 1000)
        }
        if let grain = report.grain {
            measured["grainLuma"] = .number((grain.luma * 10000).rounded() / 10000)
        }
        return [
            "kitVersion": .number(Double(report.kitVersion)),
            "provenance": .object(provenance),
            "measured": .object(measured),
        ]
    }
}
