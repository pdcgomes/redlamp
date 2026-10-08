import Foundation
import RedlampLibrary

/// The library's stacks as `StackFinder` finds them in its index (LIB-28), by the index's photo IDs, found
/// once for the grid's stacks and its groups alike and kept until something can have changed them. The
/// photos' names, which most of the finding reads, are kept until photos come or go.
actor LibraryStackFinder {
    private var names: StackNames?
    private var stacks: Stacks?
    private var finding: Task<(names: StackNames, stacks: Stacks)?, Never>?
    private var generation = 0

    /// Forgets the stacks, which are found again when next asked for, and with `names` the photos' names.
    func forget(names: Bool) {
        generation += 1
        stacks = nil
        finding = nil
        if names {
            self.names = nil
        }
    }

    /// The stacks, found first when they aren't known; nil when the index can't be read.
    func stacks(in index: LibraryIndex, engine: QueryEngine) async -> Stacks? {
        if let stacks {
            return stacks
        }
        let task = finding ?? {
            let known = names
            let task = Task.detached(priority: .userInitiated) {
                await Self.find(in: index, engine: engine, names: known)
            }
            finding = task
            return task
        }()
        let generation = generation
        let found = await task.value
        if generation == self.generation, let found {
            (names, stacks, finding) = (found.names, found.stacks, nil)
        }
        return found?.stacks
    }

    private static func find(in index: LibraryIndex, engine: QueryEngine, names known: StackNames?) async
        -> (names: StackNames, stacks: Stacks)? {
        do {
            if !engine.isLoaded {
                try await engine.load()
            }
            guard let store = engine.store else { return nil }
            let (names, choices) = try await index.read { reader in
                try (known ?? StackNames(reader), StackChoices(reader))
            }
            return (names, StackFinder.find(in: store, names: names, choices: choices))
        } catch {
            return nil
        }
    }
}
