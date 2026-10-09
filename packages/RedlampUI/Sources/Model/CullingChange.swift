import Foundation
import RedlampDocument
import RedlampLibrary

/// What a culling action asks for, before it's worked out for each photo it reaches.
public enum CullingChange: Sendable, Hashable {
    case rating(Int)
    /// `]` and `[`: each photo's own rating, one up or down.
    case ratingStep(Int)
    case flag(PhotoFlag?)
    /// P and X: the flag on every photo, or on none when every one has it.
    case toggleFlag(PhotoFlag)
    /// A colour, or none: a custom label goes too.
    case label(ColorLabel?)
    /// 6 to 9 and purple: the colour on every photo, or on none when every one has it.
    case toggleLabel(ColorLabel)
    /// A custom label by its name, as a colour toggles.
    case toggleCustomLabel(String)
    /// B: every photo marked, or none when every one is.
    case toggleMark
    case mark(Bool)

    /// The change an action's key makes; nil for actions that aren't culling.
    init?(_ action: ShortcutAction) {
        switch action {
        case .rating0: self = .rating(0)
        case .rating1: self = .rating(1)
        case .rating2: self = .rating(2)
        case .rating3: self = .rating(3)
        case .rating4: self = .rating(4)
        case .rating5: self = .rating(5)
        case .decreaseRating: self = .ratingStep(-1)
        case .increaseRating: self = .ratingStep(1)
        case .flagPick: self = .toggleFlag(.pick)
        case .flagReject: self = .toggleFlag(.reject)
        case .unflag: self = .flag(nil)
        case .labelRed: self = .toggleLabel(.red)
        case .labelYellow: self = .toggleLabel(.yellow)
        case .labelGreen: self = .toggleLabel(.green)
        case .labelBlue: self = .toggleLabel(.blue)
        case .labelPurple: self = .toggleLabel(.purple)
        case .clearLabel: self = .label(nil)
        case .toggleMark: self = .toggleMark
        default: return nil
        }
    }

    var field: CullingField {
        switch self {
        case .rating, .ratingStep: .rating
        case .flag, .toggleFlag: .flag
        case .label, .toggleLabel, .toggleCustomLabel: .label
        case .toggleMark, .mark: .mark
        }
    }

    /// `Rating`, `Red Label`, `Label “Urgent”`, as Undo and the activity log name it.
    var title: String {
        switch self {
        case let .rating(stars): stars == 0 ? "Clear Rating" : stars == 1 ? "1 Star" : "\(stars) Stars"
        case let .ratingStep(step): step > 0 ? "Increase Rating" : "Decrease Rating"
        case .flag(nil): "Unflag"
        case .flag(.pick), .toggleFlag(.pick): "Flag as Pick"
        case .flag(.reject), .toggleFlag(.reject): "Flag as Rejected"
        case let .label(label): label.map { "\($0.rawValue.capitalized) Label" } ?? "No Label"
        case let .toggleLabel(label): "\(label.rawValue.capitalized) Label"
        case let .toggleCustomLabel(name): "Label “\(name)”"
        case .toggleMark: "Mark / Unmark"
        case let .mark(marked): marked ? "Mark" : "Unmark"
        }
    }

    /// What each photo's culling fields become, from what they are.
    func resolved(_ photos: [CullingValues]) -> [CullingValues] {
        switch self {
        case let .rating(stars):
            return photos.map { var photo = $0; photo.rating = min(max(stars, 0), 5); return photo }
        case let .ratingStep(step):
            return photos.map { var photo = $0; photo.rating = min(max(photo.rating + step, 0), 5); return photo }
        case let .flag(flag):
            return photos.map { var photo = $0; photo.flag = flag; return photo }
        case let .toggleFlag(flag):
            let every = photos.allSatisfy { $0.flag == flag }
            return Self.flag(every ? nil : flag).resolved(photos)
        case let .label(label):
            return photos.map { var photo = $0; photo.label = label; photo.customLabel = nil; return photo }
        case let .toggleLabel(label):
            let every = photos.allSatisfy { $0.label == label }
            return Self.label(every ? nil : label).resolved(photos)
        case let .toggleCustomLabel(name):
            let every = photos.allSatisfy { $0.label == nil && $0.customLabel == name }
            return photos.map { photo in
                var photo = photo
                photo.label = nil
                photo.customLabel = every ? nil : name
                return photo
            }
        case .toggleMark:
            return Self.mark(!photos.allSatisfy(\.mark)).resolved(photos)
        case let .mark(marked):
            return photos.map { var photo = $0; photo.mark = marked; return photo }
        }
    }
}

/// The fields culling changes, one a change: a label and a custom label are one field.
enum CullingField: CaseIterable, Sendable {
    case rating, flag, label, mark
}

/// A photo's culling fields as its badges show them.
struct CullingValues: Hashable, Sendable {
    var rating = 0
    var flag: PhotoFlag?
    var label: ColorLabel?
    var customLabel: String?
    var mark = false

    init(_ metadata: PhotoMetadata) {
        rating = metadata.rating
        flag = metadata.flag
        label = metadata.label
        customLabel = metadata.label == nil ? metadata.customLabel : nil
        mark = metadata.mark
    }

    func matches(_ other: CullingValues, in field: CullingField) -> Bool {
        switch field {
        case .rating: rating == other.rating
        case .flag: flag == other.flag
        case .label: label == other.label && customLabel == other.customLabel
        case .mark: mark == other.mark
        }
    }

    /// `metadata` with `field` as these values have it.
    func apply(_ field: CullingField, to metadata: inout PhotoMetadata) {
        switch field {
        case .rating: metadata.rating = rating
        case .flag: metadata.flag = flag
        case .label:
            metadata.label = label
            metadata.customLabel = customLabel
        case .mark: metadata.mark = mark
        }
    }

    /// `apply`, for a sidecar's metadata as it is on disk when it's saved.
    func setting(_ field: CullingField) -> @Sendable (inout PhotoMetadata) -> Void {
        let values = self
        return { values.apply(field, to: &$0) }
    }

    /// What the library gives a photo for `field` to be as these values have it.
    func fields(_ field: CullingField) -> [MetadataField] {
        switch field {
        case .rating: [.rating(rating)]
        case .flag: [.flag(flag)]
        case .label: [customLabel.map { .namedLabel($0) } ?? .label(label)]
        case .mark: [.mark(mark)]
        }
    }
}

extension CullingValues {
    /// These values with `field` as `other` has it.
    func apply(_ field: CullingField, to other: inout CullingValues) {
        switch field {
        case .rating: other.rating = rating
        case .flag: other.flag = flag
        case .label:
            other.label = label
            other.customLabel = customLabel
        case .mark: other.mark = mark
        }
    }
}
