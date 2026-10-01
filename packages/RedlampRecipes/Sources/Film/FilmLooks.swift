import Foundation
import RedlampEngineAPI

/// Film looks built by the film model, for the look-development tools. Looks are built
/// offline and ship as Base Look tables; the model and its stock data never ship.
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

    static func stock(_ id: String, in directory: URL?) throws -> FilmStock {
        if let stock = synthetic[id] {
            return stock
        }
        guard let directory, FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(id).json").path)
        else { throw FilmLookError.unknownStock(id, known: stockIDs(in: directory)) }
        let fallback = id == fallbackDyes ? nil : try? FilmStock
            .load(directory.appendingPathComponent("\(fallbackDyes).json"))
        return try FilmStock.load(directory.appendingPathComponent("\(id).json"), dyesFrom: fallback)
    }

    /// The scene-referred table for a film with the look's settings. Negatives are printed on
    /// `print` when given, and scanned otherwise.
    public static func table(
        film: String,
        print: String? = nil,
        parameters: FilmLookParameters = FilmLookParameters(),
        size: Int = 33,
        data directory: URL? = nil,
    ) throws -> LookTable {
        let negative = try stock(film, in: directory)
        let paper = try print.map { try stock($0, in: directory) }
        return try FilmModel(film: negative, print: paper, parameters: parameters).table(size: size)
    }
}
