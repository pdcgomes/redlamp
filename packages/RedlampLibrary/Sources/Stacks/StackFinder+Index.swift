import Foundation

public extension StackFinder {
    /// Every stack among `index`'s photos: their names, and the choices its settings keep, read from
    /// it, and the rest from `store`, its column store (`QueryEngine.store`). Finds them off the
    /// caller's thread.
    static func find(in index: LibraryIndex, store: ColumnStore) async throws -> Stacks {
        let (names, choices) = try await index.read { reader in try (StackNames(reader), StackChoices(reader)) }
        return await Task.detached(priority: .userInitiated) {
            find(in: store, names: names, choices: choices)
        }.value
    }
}
