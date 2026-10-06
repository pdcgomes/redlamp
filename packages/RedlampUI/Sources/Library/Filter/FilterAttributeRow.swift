import AppKit
import RedlampDesign
import RedlampDocument
import RedlampLibrary

/// The filter bar's Attribute section, as Lightroom Classic's: flags, the rating with its comparison,
/// colour labels, edited or not, kinds of file, marked photos, and missing and offline ones. Each
/// button sets its field's filter in the query, which the text shows.
final class FilterAttributeRow: NSView {
    private let model: EditorModel
    private var tracker: Tracker?
    private var groups: [(label: NSTextField, controls: [NSView])] = []
    private let flags: [FilterAttributes.FlagChoice: FilterToggle]
    private let comparison = FilterPopUp(identifier: "library.filter.rating-comparison", tip: "Rating Comparison")
    private let stars: [FilterToggle]
    private let labels: [FilterAttributes.LabelChoice: FilterToggle]
    private let edited: FilterToggle
    private let unedited: FilterToggle
    private let kinds: [PhotoRecord.Kind: FilterToggle]
    private let marked: FilterToggle
    private let missing: FilterToggle
    private let offline: FilterToggle

    init(model: EditorModel) {
        self.model = model
        flags = [
            .pick: FilterToggle(symbol: "flag.fill", identifier: "library.filter.flag.pick", tip: "Picked"),
            .unflagged: FilterToggle(symbol: "flag", identifier: "library.filter.flag.none", tip: "Unflagged"),
            .reject: FilterToggle(symbol: "xmark.circle", identifier: "library.filter.flag.reject", tip: "Rejected"),
        ]
        stars = (1 ... 5).map { stars in
            FilterToggle(
                symbol: "star", identifier: "library.filter.star.\(stars)",
                tip: "\(stars) Star\(stars == 1 ? "" : "s") (again to clear)",
            )
        }
        var labels: [FilterAttributes.LabelChoice: FilterToggle] = [:]
        for label in ColorLabel.allCases {
            labels[.color(label)] = FilterToggle(
                symbol: "circle.fill", color: label.nsColor, identifier: "library.filter.label.\(label.rawValue)",
                tip: label.rawValue.capitalized,
            )
        }
        labels[.none] = FilterToggle(symbol: "circle.slash", identifier: "library.filter.label.none", tip: "No Label")
        self.labels = labels
        edited = FilterToggle(title: "Edited", identifier: "library.filter.edited", tip: "Edited")
        unedited = FilterToggle(title: "Unedited", identifier: "library.filter.unedited", tip: "Unedited")
        var kinds: [PhotoRecord.Kind: FilterToggle] = [:]
        for (kind, title) in zip(FilterAttributes.offeredKinds, ["Raw", "JPEG", "HEIC"]) {
            kinds[kind] = FilterToggle(
                title: title,
                identifier: "library.filter.kind.\(title.lowercased())",
                tip: title,
            )
        }
        self.kinds = kinds
        marked = FilterToggle(title: "Marked", identifier: "library.filter.marked", tip: "Marked (B)")
        missing = FilterToggle(
            title: "Missing",
            identifier: "library.filter.missing",
            tip: "Missing from their folders",
        )
        offline = FilterToggle(title: "Offline", identifier: "library.filter.offline", tip: "On volumes not connected")
        super.init(frame: .zero)
        for (choice, toggle) in flags {
            toggle.onPress = { [weak self] _ in self?.model.libraryFilters?.toggle(choice) }
        }
        comparison.onChoose = { [weak self] tag in
            guard FilterAttributes.ratingComparisons.indices.contains(tag) else { return }
            self?.model.libraryFilters?.setRatingComparison(FilterAttributes.ratingComparisons[tag])
        }
        for (index, star) in stars.enumerated() {
            star.onPress = { [weak self] _ in self?.model.libraryFilters?.rate(index + 1) }
        }
        for (choice, toggle) in labels {
            toggle.onPress = { [weak self] _ in self?.model.libraryFilters?.toggle(choice) }
        }
        edited.onPress = { [weak self] _ in self?.model.libraryFilters?.toggleEdited(true) }
        unedited.onPress = { [weak self] _ in self?.model.libraryFilters?.toggleEdited(false) }
        for (kind, toggle) in kinds {
            toggle.onPress = { [weak self] _ in self?.model.libraryFilters?.toggle(kind) }
        }
        marked.onPress = { [weak self] _ in self?.model.libraryFilters?.toggle(.marked) }
        missing.onPress = { [weak self] _ in self?.model.libraryFilters?.toggle(.missing) }
        offline.onPress = { [weak self] _ in self?.model.libraryFilters?.toggle(.offline) }
        comparison.set(
            [("≥", 0), ("≤", 1), ("=", 2)], chosen: 0,
        )
        groups = [
            (filterLabel("Flag"), FilterAttributes.FlagChoice.allCases.compactMap { flags[$0] }),
            (filterLabel("Rating"), [comparison] + stars),
            (filterLabel("Label"), FilterAttributes.LabelChoice.all.compactMap { labels[$0] }),
            (filterLabel("Edit"), [edited, unedited]),
            (filterLabel("Kind"), FilterAttributes.offeredKinds.compactMap { kinds[$0] }),
            (filterLabel("Status"), [marked, missing, offline]),
        ]
        for group in groups {
            addSubview(group.label)
            group.controls.forEach(addSubview)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Attribute")
        setAccessibilityIdentifier("library.filter.attributes")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tracker?.cancel()
        tracker = nil
        guard window != nil else { return }
        tracker = Tracker { [weak self] in self?.update() }
    }

    private func update() {
        guard let filters = model.libraryFilters else { return }
        let attributes = filters.attributes
        for (choice, toggle) in flags {
            toggle.isOn = attributes.flags.contains(choice)
        }
        let rating = attributes.rating
        for (index, star) in stars.enumerated() {
            let lit = (rating?.stars ?? 0) > index
            star.isOn = lit
            star.symbol = lit ? "star.fill" : "star"
        }
        let comparisons = FilterAttributes.ratingComparisons
        comparison.set(
            [("≥", 0), ("≤", 1), ("=", 2)],
            chosen: rating.flatMap { comparisons.firstIndex(of: $0.comparison) } ?? 0,
        )
        for (choice, toggle) in labels {
            toggle.isOn = attributes.labels.contains(choice)
        }
        edited.isOn = attributes.edited == true
        unedited.isOn = attributes.edited == false
        for (kind, toggle) in kinds {
            toggle.isOn = attributes.kinds.contains(kind)
        }
        marked.isOn = attributes.marked
        missing.isOn = attributes.missing
        offline.isOn = attributes.offline
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 12
        for group in groups {
            let width = filterWidth(group.label)
            group.label.frame = CGRect(x: x, y: (bounds.height - 16) / 2, width: width, height: 16)
            x += width + 4
            for control in group.controls {
                let controlWidth = (control as? FilterToggle)?.fittingWidth ?? 40
                control.frame = CGRect(x: x, y: (bounds.height - 20) / 2, width: controlWidth, height: 20)
                x += controlWidth + 1
            }
            x += 12
        }
    }
}
