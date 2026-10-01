import Foundation
import RedlampEngineAPI

/// Film looks built by the film model, for the look-development tools. Looks are built
/// offline and ship as Base Look tables; the model and its stock data never ship.
/// How the film was processed.
public enum FilmProcess: String, Sendable, Hashable, Codable {
    case standard
    /// Bleach bypass: the silver is left in with the dyes.
    case bleachBypass
    /// A slide film developed in C-41 as a negative.
    case crossProcessed
}

public enum FilmLooks {
    public enum FilmLookError: Error, CustomStringConvertible {
        case unknownStock(String, known: [String])

        public var description: String {
            switch self {
            case let .unknownStock(id, known): "no film stock \(id) (known: \(known.joined(separator: ", ")))"
            }
        }
    }

    static let synthetic: [String: FilmStock] = Dictionary(uniqueKeysWithValues: [
        FilmStock.syntheticNegative, .syntheticPrint, .syntheticReversal, .syntheticMonochrome, .syntheticPaper,
    ].map { ($0.id, $0) })

    /// Colour negatives whose datasheets publish no individual dye curves borrow these.
    static let fallbackDyes = "kodak-vision3-500t"

    /// Every stock: the synthetic ones and each datasheet file in `directory`.
    public static func stockIDs(in directory: URL?) -> [String] {
        let files = directory.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) } ?? []
        return (Array(synthetic.keys) + files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }).sorted()
    }

    static func stock(_ id: String, in directory: URL?, variant: [String: String]? = nil) throws -> FilmStock {
        if let stock = synthetic[id] {
            return stock
        }
        guard let directory, FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(id).json").path)
        else { throw FilmLookError.unknownStock(id, known: stockIDs(in: directory)) }
        let fallback = id == fallbackDyes ? nil : try? FilmStock
            .load(directory.appendingPathComponent("\(fallbackDyes).json"))
        return try FilmStock.load(directory.appendingPathComponent("\(id).json"), dyesFrom: fallback, variant: variant)
    }

    /// The scene-referred table for a film with the look's settings. Negatives are printed on
    /// `print` when given, and scanned otherwise; `process` can bleach-bypass or cross-process.
    public static func table(
        film: String,
        filmVariant: [String: String]? = nil,
        print: String? = nil,
        printVariant: [String: String]? = nil,
        process: FilmProcess = .standard,
        parameters: FilmLookParameters = FilmLookParameters(),
        size: Int = 33,
        data directory: URL? = nil,
    ) throws -> LookTable {
        var negative = try stock(film, in: directory, variant: filmVariant)
        let paper = try print.map { try stock($0, in: directory, variant: printVariant) }
        var parameters = parameters
        switch process {
        case .standard:
            break
        case .bleachBypass:
            parameters.silverRetention = max(parameters.silverRetention, 1)
        case .crossProcessed:
            guard negative.kind == .reversal else { break }
            negative = negative.crossProcessed()
            parameters.masking = 0
        }
        return try FilmModel(film: negative, print: paper, parameters: parameters).table(size: size)
    }
}
