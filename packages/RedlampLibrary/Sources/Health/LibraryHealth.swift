import Foundation
import RedlampDocument

/// Library Health (LIB-40): checks that each list the photos needing a decision (exact duplicates,
/// raw and JPEG pairs under the user's rule, damaged files and wrong extensions), shown only while
/// there's something to decide, and acted on only as one batch the user confirms.
///
/// - **Findings** come from the index and the column store (`HealthFindings`): each photo with its
///   reason in words and the check's proposal, which is data apart from the user's own flags and
///   never written as one. Each check is also a source (`PhotoSource.health`), kept current as every
///   list is.
/// - **Acting** is one batch of the file operations (LIB-26): to the Trash, or for wrong extensions a
///   rename, which one Undo reverses. A photo the user rated, flagged or labelled, and one with
///   decisions of its own, is acted on only when the user chooses it, never because a proposal said
///   so; the batch is checked against the findings just before it runs, in its turn.
/// - **Keep Anyway** takes a finding away, in `Definitions/Health.json` (`HealthDefinitions`), until
///   it's taken back.
public final class LibraryHealth: Sendable {
    public let operations: FileOperations
    public let engine: QueryEngine
    /// The readers of the photos' volumes, which confirming duplicates and checking their removal read
    /// through.
    public let volumes: VolumeIORegistry

    /// `engine` defaults to the one `operations.live` keeps lists with, else one of its own;
    /// `volumes` to readers through `operations.fileSystem`.
    public init(operations: FileOperations, engine: QueryEngine? = nil, volumes: VolumeIORegistry? = nil) {
        self.operations = operations
        self.engine = engine ?? operations.live?.engine ?? QueryEngine(index: operations.index)
        self.volumes = volumes ?? VolumeIORegistry(fileSystem: operations.fileSystem)
    }

    public var index: LibraryIndex {
        operations.index
    }

    public var paths: LibraryPaths {
        operations.paths
    }

    // MARK: - Findings

    /// What `check` finds in the library as the column store has it now.
    public func findings(_ check: HealthCheck) async throws -> HealthFindings {
        try await engine.healthFindings(check)
    }

    /// The checks that have findings, in Library Health's order, with pairs under `rule`: a check that
    /// finds nothing isn't offered.
    public func offered(pairs rule: PairRule = .keepBoth) async throws -> [HealthFindings] {
        var offered: [HealthFindings] = []
        for check in HealthCheck.all(pairs: rule) {
            let found = try await findings(check)
            if !found.isEmpty {
                offered.append(found)
            }
        }
        return offered
    }

    /// Reads the duplicate candidates no recorded hash confirms whole, as `redlamp library duplicates
    /// --confirm` does, so the duplicates check finds every group; lists follow. First it removes the
    /// hashes of photos gone from the index that no batch of `operations` can bring back (LIB-39).
    @discardableResult
    public func confirmDuplicates(
        progress: (@Sendable (DuplicateFinder.Progress) -> Void)? = nil,
    ) async throws -> DuplicateConfirmation {
        let finder = try await finder()
        let confirmation = try await finder.confirm(finder.candidates(), operations: operations, progress: progress)
        await changed()
        return confirmation
    }

    func finder() async throws -> DuplicateFinder {
        let sidecars = try await SidecarStore(locator: LibrarySidecars(index: index, paths: paths).locator())
        return DuplicateFinder(index: index, volumes: volumes, sidecars: sidecars)
    }

    /// Has open lists made again, and the engine's findings worked out again, after something they
    /// depend on changed beyond the photos' rows.
    func changed() async {
        if let live = operations.live, live.engine === engine {
            live.namesChanged()
            await live.settle()
        } else {
            try? await engine.updateNames()
        }
    }
}
