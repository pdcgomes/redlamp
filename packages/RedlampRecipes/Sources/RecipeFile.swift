import Foundation
import RedlampEngineAPI

/// Reading and writing `.redrecipe` files: a single UTF-8 JSON document.
public enum RecipeFile {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func encode(_ recipe: Recipe) throws -> Data {
        try encoder.encode(recipe)
    }

    public static func read(
        _ url: URL,
        origin: RecipeValidator.Origin = .user,
    ) throws -> (recipe: Recipe, issues: [RecipeIssue]) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? Int, size > RecipeValidator.maximumFileSize {
            throw RecipeValidationError(issues: [RecipeIssue(.error, "the file is larger than 16 MB")])
        }
        return try RecipeValidator.decode(Data(contentsOf: url), origin: origin)
    }

    public static func write(_ recipe: Recipe, to url: URL) throws {
        try encode(recipe).write(to: url, options: .atomic)
    }

    /// A file name for a recipe: its name, made safe, plus the extension.
    public static func fileName(for recipe: Recipe) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = String(recipe.name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
            .trimmingCharacters(in: .whitespaces)
        return (cleaned.isEmpty ? "Recipe" : cleaned) + "." + Recipe.fileExtension
    }
}
