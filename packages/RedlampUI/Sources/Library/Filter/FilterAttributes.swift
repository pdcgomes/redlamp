import Foundation
import RedlampDocument
import RedlampLibrary

/// What the Attribute section shows of a filter's rules, and the filters it writes back (LIB-18):
/// flags, the rating and its comparison, colour labels, edited or not, kinds of file, marked, offline and
/// damaged photos (LIB-40), and the moments without a pick (LIB-41). Each is the first filter on its field
/// at the top of the rules that keeps photos and that the section can show; anything else stays in the
/// text as typed, `missing:` among it, which no list but Library Health's Missing check finds (DEC-59).
struct FilterAttributes: Equatable {
    var flags: Set<FlagChoice> = []
    var rating: Rating?
    var labels: Set<LabelChoice> = []
    var edited: Bool?
    var kinds: Set<PhotoRecord.Kind> = []
    var marked = false
    var offline = false
    /// `is:damaged` alone in a filter at the top.
    var damaged = false
    /// `is:unpicked-moment` alone in a filter at the top.
    var unpickedMoments = false

    struct Rating: Equatable {
        var comparison: LibraryQuery.Comparison
        var stars: Int
    }

    /// A flag, or none.
    enum FlagChoice: Hashable, CaseIterable {
        case pick, unflagged, reject

        var flag: PhotoFlag? {
            switch self {
            case .pick: .pick
            case .unflagged: nil
            case .reject: .reject
            }
        }

        init(_ flag: PhotoFlag?) {
            self = switch flag {
            case .pick: .pick
            case .reject: .reject
            case nil: .unflagged
            }
        }
    }

    /// A colour label, or none.
    enum LabelChoice: Hashable {
        case color(ColorLabel)
        case none

        static let all: [LabelChoice] = ColorLabel.allCases.map(LabelChoice.color) + [.none]

        var label: ColorLabel? {
            if case let .color(label) = self {
                return label
            }
            return nil
        }
    }

    /// The kinds the section has buttons for; the text and the File Type column reach the others.
    static let offeredKinds: [PhotoRecord.Kind] = [.raw, .jpeg, .heic]
    /// The comparisons a rating takes, as Lightroom Classic offers them.
    static let ratingComparisons: [LibraryQuery.Comparison] = [.greaterOrEqual, .lessOrEqual, .equal]

    init() {}

    init(_ rules: QueryRules) {
        if let values = Self.values(rules, .flag) {
            flags = Set(values.compactMap { value in
                if case let .flag(flag) = value {
                    return FlagChoice(flag)
                }
                return nil
            })
        }
        if let filter = rules.filters(on: .rating).first?.filter, filter.values.count == 1,
           case let .number(number) = filter.values[0], filter.comparison != .notEqual,
           number == number.rounded(), (0 ... 5).contains(number) {
            rating = Rating(comparison: filter.comparison, stars: Int(number))
        }
        if let values = Self.values(rules, .label) {
            labels = Set(values.compactMap { value in
                if case let .label(label) = value {
                    return label.map(LabelChoice.color) ?? LabelChoice.none
                }
                return nil
            })
        }
        if let values = Self.values(rules, .edited) {
            let yes = values.contains(.bool(true))
            let no = values.contains(.bool(false))
            edited = yes == no ? nil : yes
        }
        if let values = Self.values(rules, .ext) {
            kinds = Set(values.compactMap { value in
                if case let .kind(kind) = value {
                    return kind
                }
                return nil
            })
        }
        marked = Self.values(rules, .marked) == [.bool(true)]
        offline = Self.values(rules, .offline) == [.bool(true)]
        let traits = rules.filters(on: .trait).map(\.filter)
        damaged = traits.contains(Self.filter(.damaged))
        unpickedMoments = traits.contains(Self.filter(.unpickedMoment))
    }

    /// The filter keeping the photos `trait` finds.
    static func filter(_ trait: LibraryQuery.Trait) -> LibraryQuery.Filter {
        LibraryQuery.Filter(.trait, .equal, [.trait(trait)])
    }

    /// The values of the first filter on `field` that keeps photos with `:`.
    private static func values(_ rules: QueryRules, _ field: LibraryQuery.Field) -> [LibraryQuery.Value]? {
        rules.filters(on: field).first { $0.filter.comparison == .equal }?.filter.values
    }

    // MARK: - Filters to write

    /// `flag:pick,none`; nil for none, or every flag.
    static func filter(flags: Set<FlagChoice>) -> LibraryQuery.Filter? {
        guard !flags.isEmpty, flags.count < FlagChoice.allCases.count else { return nil }
        return LibraryQuery.Filter(.flag, .equal, FlagChoice.allCases.filter(flags.contains).map { .flag($0.flag) })
    }

    static func filter(rating: Rating?) -> LibraryQuery.Filter? {
        guard let rating, rating.stars > 0 || rating.comparison == .equal else { return nil }
        return LibraryQuery.Filter(.rating, rating.comparison, [.number(Double(rating.stars))])
    }

    static func filter(labels: Set<LabelChoice>) -> LibraryQuery.Filter? {
        guard !labels.isEmpty, labels.count < LabelChoice.all.count else { return nil }
        return LibraryQuery.Filter(.label, .equal, LabelChoice.all.filter(labels.contains).map { .label($0.label) })
    }

    static func filter(edited: Bool?) -> LibraryQuery.Filter? {
        edited.map { LibraryQuery.Filter(.edited, .equal, [.bool($0)]) }
    }

    static func filter(kinds: Set<PhotoRecord.Kind>) -> LibraryQuery.Filter? {
        guard !kinds.isEmpty else { return nil }
        let kinds = PhotoRecord.Kind.allCases.filter(kinds.contains)
        return LibraryQuery.Filter(.ext, .equal, kinds.map(LibraryQuery.Value.kind))
    }

    static func filter(_ field: LibraryQuery.Field, yes: Bool) -> LibraryQuery.Filter? {
        yes ? LibraryQuery.Filter(field, .equal, [.bool(true)]) : nil
    }
}

public extension LibraryFilters {
    /// The Attribute section's flag buttons: each adds its flag to those shown, or takes it away.
    internal func toggle(_ flag: FilterAttributes.FlagChoice) {
        var flags = attributes.flags
        flags.formSymmetricDifference([flag])
        edit { $0.replacingFilters(on: .flag, with: FilterAttributes.filter(flags: flags)) }
    }

    /// A star: photos rated so, by the comparison chosen; the same star again clears it.
    func rate(_ stars: Int) {
        let current = attributes.rating
        let comparison = current?.comparison ?? .greaterOrEqual
        let rating = current?.stars == stars ? nil : FilterAttributes.Rating(comparison: comparison, stars: stars)
        edit { $0.replacingFilters(on: .rating, with: FilterAttributes.filter(rating: rating)) }
    }

    func setRatingComparison(_ comparison: LibraryQuery.Comparison) {
        guard let current = attributes.rating else { return }
        let rating = FilterAttributes.Rating(comparison: comparison, stars: current.stars)
        edit { $0.replacingFilters(on: .rating, with: FilterAttributes.filter(rating: rating)) }
    }

    internal func toggle(_ label: FilterAttributes.LabelChoice) {
        var labels = attributes.labels
        labels.formSymmetricDifference([label])
        edit { $0.replacingFilters(on: .label, with: FilterAttributes.filter(labels: labels)) }
    }

    /// Edited, or unedited: the same again shows both.
    func toggleEdited(_ edited: Bool) {
        let next = attributes.edited == edited ? nil : edited
        edit { $0.replacingFilters(on: .edited, with: FilterAttributes.filter(edited: next)) }
    }

    func toggle(_ kind: PhotoRecord.Kind) {
        var kinds = attributes.kinds
        kinds.formSymmetricDifference([kind])
        edit { $0.replacingFilters(on: .ext, with: FilterAttributes.filter(kinds: kinds)) }
    }

    /// Marked or offline photos only, or not.
    func toggle(_ field: LibraryQuery.Field) {
        let attributes = attributes
        let on: Bool = switch field {
        case .marked: attributes.marked
        case .offline: attributes.offline
        default: true
        }
        edit { $0.replacingFilters(on: field, with: FilterAttributes.filter(field, yes: !on)) }
    }

    /// The photos `trait` finds only, the damaged files (LIB-40) or the moments without a pick (LIB-41), or
    /// every photo again: `is:` and the trait added to the rules, narrowing them, or taken out, the other
    /// traits staying as they are.
    func toggle(_ trait: LibraryQuery.Trait) {
        let term = FilterAttributes.filter(trait)
        edit { rules in
            var rules = rules
            if let found = rules.filters(on: .trait).first(where: { $0.filter == term }) {
                rules.rules.remove(at: found.index)
            } else {
                if rules.match != .all, !rules.rules.isEmpty {
                    rules = QueryRules(match: .all, rules: [.group(rules)])
                }
                rules.rules.append(.filter(term, negated: false))
            }
            return QueryRules(LibraryQuery(rules))
        }
    }

    /// `query`, a term of the language, as one more of the filter's, as the palette adds it (LIB-19): a filter on a
    /// field takes the place of the field's that keep photos, as a column's choice does; a trait goes beside the
    /// others, as the Attribute section puts one; anything else, a term with `-` among them, narrows the rules as
    /// it is. A term the rules have already changes nothing.
    func narrow(by query: LibraryQuery) {
        let rule = QueryRules.Rule(query)
        edit { rules in
            if case let .filter(filter, negated: false) = rule, filter.field != .trait {
                return rules.replacingFilters(on: filter.field, with: filter)
            }
            guard rules.match != .all || !rules.rules.contains(rule) else { return rules }
            var rules = rules
            if rules.match != .all, !rules.rules.isEmpty {
                rules = QueryRules(match: .all, rules: [.group(rules)])
            }
            rules.rules.append(rule)
            return QueryRules(LibraryQuery(rules))
        }
    }

    internal var attributes: FilterAttributes {
        FilterAttributes(rules)
    }
}
