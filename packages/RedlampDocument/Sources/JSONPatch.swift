import Foundation
import RedlampEngineAPI

/// RFC 6902 JSON Patch, with the `add`, `remove` and `replace` operations: how a history session
/// stores each step, as the change from the step before it.
public enum JSONPatch {
    public enum Op: String, Codable, Sendable, Hashable {
        case add, remove, replace
    }

    public struct Operation: Codable, Sendable, Hashable {
        public var op: Op
        /// A JSON Pointer (RFC 6901).
        public var path: String
        public var value: JSONValue?

        public init(_ op: Op, _ path: String, _ value: JSONValue? = nil) {
            self.op = op
            self.path = path
            self.value = value
        }
    }

    public enum Error: Swift.Error, Equatable {
        case invalidPath(String)
        case missingValue(String)
    }

    /// The operations that turn `old` into `new`. Objects change key by key and arrays element by
    /// element, so appending a brush stroke adds one stroke and a slider replaces one value.
    public static func diff(from old: JSONValue, to new: JSONValue) -> [Operation] {
        var operations: [Operation] = []
        diff(old, new, at: "", into: &operations)
        return operations
    }

    /// `value` with `operations` applied in order.
    public static func apply(_ operations: [Operation], to value: JSONValue) throws -> JSONValue {
        try operations.reduce(value) { document, operation in
            if operation.op != .remove, operation.value == nil {
                throw Error.missingValue(operation.path)
            }
            return try applying(operation, to: document, at: tokens(operation.path)[...])
        }
    }

    // MARK: - Diff

    private static func diff(_ old: JSONValue, _ new: JSONValue, at path: String, into operations: inout [Operation]) {
        guard old != new else { return }
        switch (old, new) {
        case let (.object(before), .object(after)):
            for key in before.keys.sorted() where after[key] == nil {
                operations.append(Operation(.remove, path + "/" + escape(key)))
            }
            for key in after.keys.sorted() {
                guard let value = after[key] else { continue }
                if let previous = before[key] {
                    diff(previous, value, at: path + "/" + escape(key), into: &operations)
                } else {
                    operations.append(Operation(.add, path + "/" + escape(key), value))
                }
            }
        case let (.array(before), .array(after)):
            diffArrays(before, after, at: path, into: &operations)
        default:
            operations.append(Operation(.replace, path, new))
        }
    }

    private static func diffArrays(
        _ before: [JSONValue], _ after: [JSONValue], at path: String, into operations: inout [Operation],
    ) {
        // One element inserted or removed (a new mask, a deleted component) moves the rest along.
        if abs(before.count - after.count) == 1 {
            let longer = before.count > after.count ? before : after
            let shorter = before.count > after.count ? after : before
            let index = shorter.indices.first { shorter[$0] != longer[$0] } ?? shorter.count
            if Array(shorter[index...]) == Array(longer[(index + 1)...]) {
                operations.append(before.count > after.count
                    ? Operation(.remove, "\(path)/\(index)")
                    : Operation(.add, "\(path)/\(index)", after[index]))
                return
            }
        }
        let common = min(before.count, after.count)
        for index in 0 ..< common {
            diff(before[index], after[index], at: "\(path)/\(index)", into: &operations)
        }
        for index in common ..< after.count {
            operations.append(Operation(.add, "\(path)/-", after[index]))
        }
        for index in (common ..< before.count).reversed() {
            operations.append(Operation(.remove, "\(path)/\(index)"))
        }
    }

    // MARK: - Apply

    private static func applying(
        _ operation: Operation, to document: JSONValue, at tokens: ArraySlice<String>,
    ) throws -> JSONValue {
        guard let token = tokens.first else {
            guard operation.op != .remove, let value = operation.value else {
                throw Error.invalidPath(operation.path)
            }
            return value
        }
        let rest = tokens.dropFirst()
        switch document {
        case var .object(object):
            if rest.isEmpty {
                try apply(operation, to: &object, key: token)
            } else {
                guard let child = object[token] else { throw Error.invalidPath(operation.path) }
                object[token] = try applying(operation, to: child, at: rest)
            }
            return .object(object)
        case var .array(array):
            if rest.isEmpty {
                try apply(operation, to: &array, index: token)
            } else {
                guard let index = Int(token), array.indices.contains(index) else {
                    throw Error.invalidPath(operation.path)
                }
                array[index] = try applying(operation, to: array[index], at: rest)
            }
            return .array(array)
        default:
            throw Error.invalidPath(operation.path)
        }
    }

    private static func apply(_ operation: Operation, to object: inout [String: JSONValue], key: String) throws {
        switch operation.op {
        case .add:
            object[key] = operation.value
        case .replace:
            guard object[key] != nil else { throw Error.invalidPath(operation.path) }
            object[key] = operation.value
        case .remove:
            guard object.removeValue(forKey: key) != nil else { throw Error.invalidPath(operation.path) }
        }
    }

    /// `index` is a number, or `-` (past the end) to append.
    private static func apply(_ operation: Operation, to array: inout [JSONValue], index token: String) throws {
        let index = token == "-" ? array.count : Int(token) ?? -1
        switch (operation.op, operation.value) {
        case let (.add, value?) where (0 ... array.count).contains(index):
            array.insert(value, at: index)
        case let (.replace, value?) where array.indices.contains(index):
            array[index] = value
        case (.remove, _) where array.indices.contains(index):
            array.remove(at: index)
        default:
            throw Error.invalidPath(operation.path)
        }
    }

    // MARK: - Pointers

    private static func escape(_ key: String) -> String {
        key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
    }

    private static func tokens(_ path: String) throws -> [String] {
        guard !path.isEmpty else { return [] }
        guard path.hasPrefix("/") else { throw Error.invalidPath(path) }
        return path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map {
            $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
        }
    }
}
