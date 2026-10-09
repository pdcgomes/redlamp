import Foundation
import RedlampDocument
import RedlampEngineAPI

/// A field to give many photos at once, replacing what each has (LIB-15, LIB-22). A text or location
/// cleared is written empty, so what's embedded in the photo or other apps' `.xmp` doesn't come back.
public enum MetadataField: Sendable, Hashable {
    /// 0 to 5 stars.
    case rating(Int)
    case flag(PhotoFlag?)
    /// A colour label, or none: a custom label goes too.
    case label(ColorLabel?)
    /// A label by its name: a colour's in any label set (`Red`, `Approved`) is that colour, any other a
    /// custom label; none clears the label.
    case namedLabel(String?)
    /// In the quick collection.
    case mark(Bool)
    case title(String?)
    case caption(String?)
    case creator(String?)
    case copyright(String?)
    /// The whole location.
    case location(PhotoLocation?)
    case sublocation(String?)
    case city(String?)
    case state(String?)
    case country(String?)
    case countryCode(String?)

    /// What it does to each photo's sidecar fields.
    var edits: [String: FieldEdit] {
        func text(_ value: String?) -> FieldEdit {
            .set(.string(value ?? ""))
        }
        func place(_ value: String?) -> FieldEdit {
            .set(value.flatMap(XMPSource.trimmed).map(JSONValue.string))
        }
        switch self {
        case let .rating(stars): return ["rating": .set(.number(Double(min(max(stars, 0), 5))))]
        case let .flag(flag): return ["flag": .set(flag.map { .string($0.rawValue) })]
        case let .label(label): return ["label": .set(label.map { .string($0.rawValue) }), "customLabel": .set(nil)]
        case let .namedLabel(name):
            guard let name = name.flatMap(XMPSource.trimmed) else { return MetadataField.label(nil).edits }
            if let label = XMPLabelNames.label(named: name) ?? ColorLabel(rawValue: name.lowercased()) {
                return MetadataField.label(label).edits
            }
            return ["label": .set(nil), "customLabel": .set(.string(name))]
        case let .mark(marked): return ["mark": .set(marked ? .bool(true) : nil)]
        case let .title(value): return ["title": text(value)]
        case let .caption(value): return ["caption": text(value)]
        case let .creator(value): return ["creator": text(value)]
        case let .copyright(value): return ["copyright": text(value)]
        case let .location(location):
            let json = (location ?? PhotoLocation()).json
            return ["location": .set(json)]
        case let .sublocation(value): return ["location.sublocation": place(value)]
        case let .city(value): return ["location.city": place(value)]
        case let .state(value): return ["location.state": place(value)]
        case let .country(value): return ["location.country": place(value)]
        case let .countryCode(value): return ["location.countryCode": place(value)]
        }
    }

    /// What `fields` do to each photo's sidecar fields, a later field's edit replacing an earlier one's.
    static func edits(_ fields: [MetadataField]) -> [String: FieldEdit] {
        fields.reduce(into: [String: FieldEdit]()) { $0.merge($1.edits) { _, new in new } }
    }

    /// `the rating`, `the caption`, as a batch's title names it.
    var name: String {
        switch self {
        case .rating: "the rating"
        case .flag: "the flag"
        case .label, .namedLabel: "the label"
        case .mark: "the mark"
        case .title: "the title"
        case .caption: "the caption"
        case .creator: "the creator"
        case .copyright: "the copyright"
        case .location: "the location"
        case .sublocation: "the sublocation"
        case .city: "the city"
        case .state: "the state"
        case .country: "the country"
        case .countryCode: "the country code"
        }
    }
}

/// A change to many photos' metadata (LIB-15, LIB-22), made as one batch with Undo.
public enum MetadataChange: Sendable, Hashable {
    /// Gives the photos each field.
    case set([MetadataField], on: [Int64])
    /// Gives each photo its own fields, as culling does (`]` steps each photo's own rating). A photo whose
    /// row already shows them is in the batch too: its sidecar is read, and written if it doesn't hold them.
    case each([Int64: [MetadataField]])
    /// Gives the photos the fields the preset ticks, each replacing, appending to or prefixing what
    /// they have, with the codes of `codes` expanded in its texts.
    case preset(MetadataPreset, to: [Int64], codes: CodeReplacements = CodeReplacements())
}

/// A change to manual stacks (LIB-28), made as one batch with Undo: each photo's sidecar keeps its place.
/// Each is planned against the stacks as they are when its turn comes (`StackChoices` describes them).
public enum StackChange: Sendable, Hashable {
    /// Stacks the photos by hand, with their pairs' others, taking them out of any stack they were in;
    /// `top` is shown for the stack, else the one taken first.
    case stack([Int64], top: Int64? = nil)
    /// Takes apart the bursts and manual stacks holding the photos: each of their photos stands alone,
    /// in no burst.
    case unstack([Int64])
    /// Takes the photos and their pairs' others out of their stacks, the stacks' others staying stacked.
    case remove([Int64])
    /// Splits the burst or manual stack holding the photo before it.
    case split(before: Int64)
    /// Moves the photo, with its pair's others, `by` places down its burst or manual stack, up when it's
    /// negative, counting only the frames of the photos `among` holds when it's given.
    case move(Int64, by: Int, among: Set<Int64>? = nil)
    /// Moves the photos, with their pairs' others, to the second's place in the burst or manual stack holding
    /// them all.
    case place([Int64], at: Int64)
    /// Shows the photo for the burst or manual stack holding it.
    case top(Int64)
    /// Forgets what was decided for the photos, which are stacked again as they're found.
    case reset([Int64])
}

public extension LibraryMetadata {
    /// What `change` would do, worked out from the index as it is; nothing is written.
    func plan(_ change: MetadataChange) async throws -> MetadataPlan {
        var batch: MetadataBatch
        switch change {
        case let .set(fields, ids):
            let edit = MetadataField.edits(fields)
            batch = MetadataBatch(kind: .metadata, title: Self.title(fields, ids.count))
            batch.edit = edit
            batch.photos = try await photos(ids, edit: edit)
        case let .each(fields):
            let ids = fields.keys.sorted()
            batch = MetadataBatch(kind: .metadata, title: Self.title(ids.flatMap { fields[$0] ?? [] }, ids.count))
            let alike = Set(fields.values).count == 1
            batch.edit = alike ? fields.values.first.map(MetadataField.edits) ?? [:] : [:]
            batch.photos = try await photos(
                ids, edits: alike ? [:] : fields.mapValues(MetadataField.edits), edit: batch.edit,
                keepingUnchanged: true,
            )
        case let .preset(preset, ids, codes):
            batch = MetadataBatch(kind: .preset, title: "Apply “\(preset.name)” to \(Self.count(ids.count))")
            batch.edit = preset.edits(codes: codes)
            batch.photos = try await photos(ids, edit: batch.edit)
        }
        return MetadataPlan(batch: batch)
    }

    /// What `change` would do to the stacks `stacks` holds, found from this index (`StackFinder`), with
    /// the choices the index keeps; nothing is written.
    func plan(_ change: StackChange, in stacks: Stacks) async throws -> MetadataPlan {
        let current = try await index.read { try StackChoices($0) }
        var choices = current
        let title: String
        let changed: [Int64]
        switch change {
        case let .stack(ids, top):
            (title, changed) = ("Stack \(Self.count(ids.count))", choices.stack(ids, top: top, in: stacks))
        case let .unstack(ids):
            changed = choices.unstack(ids, in: stacks)
            title = "Unstack \(Self.count(Set(changed).count))"
        case let .remove(ids):
            changed = choices.remove(ids, in: stacks)
            title = "Remove \(Self.count(ids.count)) from \(ids.count == 1 ? "its stack" : "their stacks")"
        case let .split(id):
            (title, changed) = ("Split a stack", choices.split(before: id, in: stacks))
        case let .move(id, offset, shown):
            changed = choices.move(id, by: offset, among: shown, in: stacks)
            title = "Move a photo \(offset < 0 ? "up" : "down") its stack"
        case let .place(ids, target):
            changed = choices.place(ids, at: target, in: stacks)
            title = "Move \(Self.count(ids.count)) in \(ids.count == 1 ? "its stack" : "their stack")"
        case let .top(id):
            (title, changed) = ("Show a photo for its stack", choices.setTop(id, in: stacks))
        case let .reset(ids):
            (title, changed) = ("Forget the stacks of \(Self.count(ids.count))", choices.reset(ids, in: stacks))
        }
        var batch = MetadataBatch(kind: .stacks, title: title)
        let ids = Array(Set(changed)).sorted()
        let shown = try await index.read { reader in
            try (reader.metadataValues(ofPhotos: ids, keys: ["stack"]), reader.photoPaths(ids))
        }
        batch.photos = ids.compactMap { id in
            guard let values = shown.0[id]?.values, let path = shown.1[id], choices[id] != current[id] else {
                return nil
            }
            let choice = choices[id].map { JSONValue.encoded($0) }
            return MetadataBatch.Photo(
                id: id, path: path, index: PhotoMetadata.canonical(values), edits: ["stack": .set(choice)],
            )
        }
        return MetadataPlan(batch: batch)
    }

    /// `Set the caption of 1,200 photos`, `Set the rating and the flag of a photo`.
    internal static func title(_ fields: [MetadataField], _ photos: Int) -> String {
        var names: [String] = []
        for field in fields where !names.contains(field.name) {
            names.append(field.name)
        }
        let what = names.count <= 1 ? names.first ?? "nothing"
            : names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        return "Set \(what) of \(count(photos))"
    }
}

extension PhotoLocation {
    /// As the sidecar writes it.
    var json: JSONValue {
        JSONValue.encoded(self)
    }
}

extension JSONValue {
    /// `value` as JSON encodes it; null when it can't be.
    static func encoded(_ value: some Encodable) -> JSONValue {
        guard let data = try? JSONEncoder().encode(value),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return .null }
        return json
    }
}
