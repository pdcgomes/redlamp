import Foundation
import RedlampDocument
import RedlampEngineAPI

/// Some of a photo's metadata, by the keys of its sidecar's `metadata` (`rating`, `caption`,
/// `collections`), each as the sidecar writes it: `.null` for a field it doesn't hold.
typealias MetadataValues = [String: JSONValue]

/// What a batch does to one field of each photo's metadata, a key of the sidecar's `metadata`, or a key
/// inside one (`location.city`): it sets it, adds text to it, or adds, takes off or moves the items of a
/// list.
public enum FieldEdit: Sendable, Hashable, Codable {
    /// The value, as the sidecar writes it; nil takes the field out.
    case set(JSONValue?)
    /// `text` after what the field holds, `separator` between them when it holds something.
    case append(String, separator: String)
    /// `text` before what the field holds, `separator` between them when it holds something.
    case prefix(String, separator: String)
    /// Items the list gains at its end; those it has stay where they are.
    case add([String])
    case remove([String])
    /// Each item at or within the path `from` moves to the same place within `to`, or comes off when
    /// there's no `to`, as a collection's photos follow it.
    case move(from: String, to: String?)
    /// Each item at or within any of the paths comes off.
    case drop([String])

    /// Whether it starts from what the field holds, which is what the index shows when the sidecar
    /// holds none.
    var derives: Bool {
        if case .set = self {
            return false
        }
        return true
    }

    /// The field's value once edited, from `value` (`.null` for none).
    func applied(to value: JSONValue) -> JSONValue {
        switch self {
        case let .set(new):
            return new ?? .null
        case let .append(text, separator):
            let current = value.textValue ?? ""
            return .string(current.isEmpty ? text : text.isEmpty ? current : current + separator + text)
        case let .prefix(text, separator):
            let current = value.textValue ?? ""
            return .string(current.isEmpty ? text : text.isEmpty ? current : text + separator + current)
        case let .add(items):
            var list = value.items
            for item in items where !list.contains(item) {
                list.append(item)
            }
            return .array(list.map(JSONValue.string))
        case let .remove(items):
            return .array(value.items.filter { !items.contains($0) }.map(JSONValue.string))
        case let .move(from, to):
            guard let from = CollectionPath(from) else { return value }
            let to = to.flatMap(CollectionPath.init)
            var moved: [String] = []
            for item in value.items {
                guard let path = CollectionPath(item), path.isWithin(from) else {
                    moved.append(item)
                    continue
                }
                guard let to else { continue }
                let text = path.replacingPrefix(from, with: to).text
                if !moved.contains(text) {
                    moved.append(text)
                }
            }
            return .array(moved.map(JSONValue.string))
        case let .drop(paths):
            let paths = paths.compactMap(CollectionPath.init)
            return .array(value.items.filter { item in
                !(CollectionPath(item).map { path in paths.contains { path.isWithin($0) } } ?? false)
            }.map(JSONValue.string))
        }
    }
}

extension [String: FieldEdit] {
    /// The sidecar's keys the edits touch: `location` for `location.city`.
    var touched: Set<String> {
        Set(keys.map { $0.split(separator: ".", maxSplits: 1).first.map(String.init) ?? $0 })
    }

    /// `current` (the fields as the sidecar holds them, `.null` for none) with the edits made, in the
    /// order of their keys; one that starts from the field's value, or a key inside it, starts from
    /// `fallback`'s, what the index shows, where `current` holds none.
    func applied(to current: MetadataValues, fallback: MetadataValues) -> MetadataValues {
        var result = current
        for (path, edit) in sorted(by: { $0.key < $1.key }) {
            let parts = path.split(separator: ".", maxSplits: 1).map(String.init)
            let key = parts[0]
            var base = result[key] ?? .null
            if base == .null, edit.derives || parts.count > 1 {
                base = fallback[key] ?? .null
            }
            guard parts.count > 1 else {
                result[key] = edit.applied(to: base)
                continue
            }
            var object = base.objectValue ?? [:]
            let field = edit.applied(to: object[parts[1]] ?? .null)
            object[parts[1]] = field == .null ? nil : field
            result[key] = .object(object)
        }
        return result
    }
}

/// `current` with what a batch made of `before` to give `after` taken back, field by field: a field it
/// holds as the batch left it goes back; a list that changed since loses what the batch added and gets
/// back what it took off; any other field that changed since stays as it is.
func undone(_ current: MetadataValues, before: MetadataValues, after: MetadataValues) -> MetadataValues {
    var result = current
    for key in Set(before.keys).union(after.keys) {
        let now = current[key] ?? .null
        let was = before[key] ?? .null
        let made = after[key] ?? .null
        if now == made {
            result[key] = was
        } else if case .array = now, PhotoMetadata.lists.contains(key) {
            let added = Set(made.items).subtracting(was.items)
            var list = now.items.filter { !added.contains($0) }
            for item in was.items where !made.items.contains(item) && !list.contains(item) {
                list.append(item)
            }
            result[key] = .array(list.map(JSONValue.string))
        }
    }
    return result
}

extension PhotoMetadata {
    /// The keys whose values are lists of paths.
    static let lists: Set = ["collections", "keywords"]

    /// The metadata as its sidecar writes it.
    var json: [String: JSONValue] {
        guard let data = try? JSONEncoder().encode(self),
              case let .object(object)? = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return [:] }
        return object
    }

    /// What it holds of `keys`, `.null` for each it doesn't.
    func values(_ keys: some Sequence<String>) -> MetadataValues {
        let json = json
        return Dictionary(uniqueKeysWithValues: keys.map { ($0, json[$0] ?? .null) })
    }

    /// The metadata with `values` in place of its own, `.null` taking a field out; nil when the values
    /// aren't what the sidecar can hold.
    func setting(_ values: MetadataValues) -> PhotoMetadata? {
        var json = json
        for (key, value) in values {
            json[key] = value == .null ? nil : value
        }
        json["rating"] = json["rating"] ?? .number(0)
        guard let data = try? JSONEncoder().encode(JSONValue.object(json)) else { return nil }
        return try? JSONDecoder().decode(PhotoMetadata.self, from: data)
    }

    /// `values` as the sidecar would write them back: a false mark or an empty list of collections as
    /// none, so that values that mean the same compare equal.
    static func canonical(_ values: MetadataValues) -> MetadataValues {
        guard let metadata = PhotoMetadata().setting(values) else { return values }
        return metadata.values(values.keys)
    }
}

extension JSONValue {
    /// The items of a list of texts; none for anything else.
    var items: [String] {
        guard case let .array(values) = self else { return [] }
        return values.compactMap(\.textValue)
    }

    var objectValue: [String: JSONValue]? {
        if case let .object(object) = self {
            return object
        }
        return nil
    }
}
