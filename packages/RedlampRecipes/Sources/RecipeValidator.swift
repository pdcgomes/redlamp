import Foundation
import RedlampEngineAPI

/// One finding from validating a recipe file.
public struct RecipeIssue: Sendable, Hashable, CustomStringConvertible {
    public enum Severity: String, Sendable, Hashable, Comparable {
        /// Informational: something was adjusted or kept for a newer Redlamp.
        case warning
        /// The file can't be used.
        case error

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs == .warning && rhs == .error
        }
    }

    public var severity: Severity
    public var message: String

    public init(_ severity: Severity, _ message: String) {
        self.severity = severity
        self.message = message
    }

    public var description: String {
        "\(severity.rawValue): \(message)"
    }
}

public struct RecipeValidationError: Error, CustomStringConvertible, Sendable {
    public var issues: [RecipeIssue]

    public var description: String {
        issues.filter { $0.severity == .error }.map(\.message).joined(separator: "; ")
    }
}

/// Checks recipe files from anywhere before they are used.
///
/// Recipes are data, never code, and every value is checked: size caps, finite numbers,
/// parameters clamped to their slider ranges, look tables verified against their hashes.
public enum RecipeValidator {
    public static let maximumFileSize = 16 << 20
    public static let maximumEmbeddedLooks = 8
    public static let maximumNameLength = 120
    public static let maximumTags = 32

    /// Where a file comes from decides which namespaces it may use.
    public enum Origin: Sendable {
        /// Shipped inside Redlamp: may use `redlamp/`.
        case bundled
        /// Made or imported by the user.
        case user
    }

    /// Decodes and validates a `.redrecipe` file. Values out of range are clamped and
    /// reported as warnings; anything unsafe or corrupt is an error.
    public static func decode(_ data: Data, origin: Origin = .user) throws -> (recipe: Recipe, issues: [RecipeIssue]) {
        guard data.count <= maximumFileSize else {
            throw RecipeValidationError(issues: [RecipeIssue(.error, "the file is larger than 16 MB")])
        }
        let recipe: Recipe
        do {
            recipe = try RecipeFile.decoder.decode(Recipe.self, from: data)
        } catch {
            throw RecipeValidationError(issues: [RecipeIssue(.error, "not a recipe file: \(error)")])
        }
        let (sanitized, issues) = validate(recipe, origin: origin)
        if issues.contains(where: { $0.severity == .error }) {
            throw RecipeValidationError(issues: issues)
        }
        return (sanitized, issues)
    }

    /// Validates a recipe and returns a copy with every value brought into range.
    public static func validate(_ recipe: Recipe, origin: Origin = .user) -> (Recipe, [RecipeIssue]) {
        var recipe = recipe
        var issues = identityIssues(recipe, origin: origin)
        issues += trimMetadata(&recipe)
        issues += newerRedlampIssues(recipe)
        issues += sanitizeValues(&recipe)
        issues += sanitizeCurveAndLook(&recipe)
        issues += embeddedLookIssues(recipe, origin: origin)
        return (recipe, issues)
    }

    private static func identityIssues(_ recipe: Recipe, origin: Origin) -> [RecipeIssue] {
        var issues: [RecipeIssue] = []
        if !RecipeNamespace.isValid(recipe.id) {
            issues.append(RecipeIssue(.error, "“\(recipe.id)” is not a valid recipe id (namespace/name, lowercase)"))
        } else if recipe.isBundled, origin != .bundled {
            issues.append(RecipeIssue(.error, "the redlamp/ namespace is reserved for recipes that ship with Redlamp"))
        }
        if recipe.version < 1 {
            issues.append(RecipeIssue(.error, "version must be 1 or higher"))
        }
        if recipe.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(RecipeIssue(.error, "the recipe has no name"))
        }
        return issues
    }

    private static func trimMetadata(_ recipe: inout Recipe) -> [RecipeIssue] {
        var issues: [RecipeIssue] = []
        if recipe.name.count > maximumNameLength {
            recipe.name = String(recipe.name.prefix(maximumNameLength))
            issues.append(RecipeIssue(.warning, "the name was shortened to \(maximumNameLength) characters"))
        }
        if recipe.tags.count > maximumTags {
            recipe.tags = Array(recipe.tags.prefix(maximumTags))
            issues.append(RecipeIssue(.warning, "only the first \(maximumTags) tags were kept"))
        }
        return issues
    }

    private static func newerRedlampIssues(_ recipe: Recipe) -> [RecipeIssue] {
        var notes: [String] = []
        if recipe.fileFormat > Recipe.formatVersion {
            notes.append("written by a newer Redlamp (format \(recipe.fileFormat)); some settings may be ignored")
        }
        if recipe.processVersion > EditRecipe.currentProcessVersion {
            notes.append("tuned with a newer Redlamp's rendering; it may look different here")
        }
        if !recipe.settings.unknownValues.isEmpty {
            let names = recipe.settings.unknownValues.keys.sorted().joined(separator: ", ")
            notes.append("needs a newer Redlamp for \(names); kept unchanged")
        }
        if !recipe.settings.unknownIncludes.isEmpty {
            notes.append("needs a newer Redlamp for \(recipe.settings.unknownIncludes.joined(separator: ", "))")
        }
        if !recipe.unknownFields.isEmpty {
            notes.append("needs a newer Redlamp for \(recipe.unknownFields.keys.sorted().joined(separator: ", "))")
        }
        return notes.map { RecipeIssue(.warning, $0) }
    }

    /// Drops values that can't be part of the recipe and clamps the rest to their ranges.
    private static func sanitizeValues(_ recipe: inout Recipe) -> [RecipeIssue] {
        var issues: [RecipeIssue] = []
        var values: [ParameterID: Double] = [:]
        for (parameter, value) in recipe.settings.values {
            let key = parameter.rawValue
            guard value.isFinite else {
                issues.append(RecipeIssue(.error, "\(key) is not a number"))
                continue
            }
            guard let group = RecipeSettingGroup(parameter: parameter) else {
                issues.append(RecipeIssue(.warning, "\(key) can't be part of a recipe and was dropped"))
                continue
            }
            guard recipe.includes.contains(group) else {
                issues.append(RecipeIssue(.warning, "\(key) is outside the included settings and was dropped"))
                continue
            }
            let clamped = parameter.spec.clamp(value)
            if clamped != value {
                issues.append(RecipeIssue(.warning, "\(key) was clamped to \(parameter.spec.formatted(clamped))"))
            }
            values[parameter] = clamped
        }
        recipe.settings.values = values
        return issues
    }

    private static func sanitizeCurveAndLook(_ recipe: inout Recipe) -> [RecipeIssue] {
        var issues: [RecipeIssue] = []
        if let curve = recipe.settings.pointCurve {
            if curve.count < 2 || curve.count > 64 || curve.contains(where: { !$0.x.isFinite || !$0.y.isFinite }) {
                issues.append(RecipeIssue(.error, "the point curve is invalid"))
            } else {
                recipe.settings.pointCurve = curve
                    .map { CurvePoint(x: min(max($0.x, 0), 1), y: min(max($0.y, 0), 1)) }
                    .sorted { $0.x < $1.x }
            }
        }
        if let look = recipe.baseLook {
            if !look.amount.isFinite {
                issues.append(RecipeIssue(.error, "the base look amount is not a number"))
            }
            recipe.baseLook = look.withAmount(look.amount.isFinite ? look.amount : 100)
        }
        return issues
    }

    private static func embeddedLookIssues(_ recipe: Recipe, origin: Origin) -> [RecipeIssue] {
        var issues: [RecipeIssue] = []
        if recipe.embeddedBaseLooks.count > maximumEmbeddedLooks {
            issues.append(RecipeIssue(.error, "a recipe can carry at most \(maximumEmbeddedLooks) base looks"))
        }
        for package in recipe.embeddedBaseLooks {
            issues += packageIssues(package, origin: origin)
        }
        if let look = recipe.baseLook, look.contentHash != nil,
           !recipe.embeddedBaseLooks.contains(where: { $0.matches(look) }) {
            issues.append(RecipeIssue(
                .warning,
                "the base look “\(look.name)” isn't included; it must already be installed",
            ))
        }
        return issues
    }

    private static func packageIssues(_ package: BaseLookPackage, origin: Origin) -> [RecipeIssue] {
        var issues: [RecipeIssue] = []
        if !RecipeNamespace.isValid(package.id) {
            issues.append(RecipeIssue(.error, "“\(package.id)” is not a valid base look id"))
        } else if package.id.hasPrefix(RecipeNamespace.bundled + "/"), origin != .bundled,
                  BuiltInBaseLooks.package(id: package.id, version: package.version) != package {
            issues.append(RecipeIssue(
                .error,
                "the redlamp/ namespace is reserved for base looks that ship with Redlamp",
            ))
        }
        let p = package.parameters
        let finite = [p.contrast, p.saturation, p.warmth, p.greenBoost, p.skinSoftening].allSatisfy(\.isFinite)
        if !finite || !(0 ... 3).contains(p.contrast) || !(0 ... 3).contains(p.saturation) || abs(p.warmth) > 0.2 {
            issues.append(RecipeIssue(.error, "base look “\(package.name)” has out-of-range parameters"))
        }
        guard let table = package.table else { return issues }
        guard table.isSupported else {
            issues.append(RecipeIssue(
                .warning,
                "base look “\(package.name)” uses \(table.space), which needs a newer Redlamp",
            ))
            return issues
        }
        do {
            _ = try table.decode()
        } catch {
            issues.append(RecipeIssue(.error, "base look “\(package.name)”: \(error)"))
        }
        return issues
    }
}
