import Foundation
import RedlampDocument
import RedlampLibrary

/// What the Attribute section shows of a filter's rules, and the filters it writes back (LIB-18):
/// flags, the rating and its comparison, colour labels, edited or not, kinds of file, marked, and
/// missing and offline photos, and the moments without a pick (LIB-41). Each is the first filter on its
/// field at the top of the rules that keeps photos and that the section can show; anything else stays
/// in the text as typed.
struct FilterAttributes: Equatable {
    var flags: Set<FlagChoice> = []
    var rating: Rating?
    var labels: Set<LabelChoice> = []
    var edited: Bool?
    var kinds: Set<PhotoRecord.Kind> = []
    var marked = false
    var missing = false
    var offline = false
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
        missing = Self.values(rules, .missing) == [.bool(true)]
        offline = Self.values(rules, .offline) == [.bool(true)]
        unpickedMoments = rules.filters(on: .trait).contains { $0.filter == Self.unpickedMoments }
    }

    /// The filter keeping the photos in moments without a pick.
    static let unpickedMoments = LibraryQuery.Filter(.trait, .equal, [.trait(.unpickedMoment)])

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

    /// Marked, missing or offline photos only, or not.
    func toggle(_ field: LibraryQuery.Field) {
        let attributes = attributes
        let on: Bool = switch field {
        case .marked: attributes.marked
        case .missing: attributes.missing
        case .offline: attributes.offline
        default: true
        }
        edit { $0.replacingFilters(on: field, with: FilterAttributes.filter(field, yes: !on)) }
    }

    /// The photos in moments without a pick only (LIB-41), or every photo again: `is:unpicked-moment`
    /// added to the rules, narrowing them, or taken out, the other traits staying as they are.
    func toggleUnpickedMoments() {
        let term = FilterAttributes.unpickedMoments
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

    internal var attributes: FilterAttributes {
        FilterAttributes(rules)
    }
}
