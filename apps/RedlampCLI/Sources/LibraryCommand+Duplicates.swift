import Foundation
import RedlampDocument
import RedlampLibrary
import Synchronization

extension LibraryCommand {
    /// `redlamp library duplicates`: the exact duplicates in an index (LIB-39), grouped by content
    /// key and size and, with `--confirm`, confirmed by reading every candidate whole; prints the
    /// groups, what removing all but the proposed copies would free, the proposals and why, and the
    /// candidates that couldn't be compared, with its progress on stderr. It removes nothing unless
    /// `--trash` is given: then every candidate is read whole, every file that would move to the
    /// Trash is printed, and all but each group's proposed copy move, as one journaled batch that
    /// `undo` takes back (LIB-26), only with `--confirm` and without `--dry-run`, once each copy and
    /// the copy kept for it are checked again.
    static func duplicates(_ arguments: [String]) async throws {
        let options = try Arguments(arguments, valued: ["--index"])
        guard options.positional.isEmpty, let path = options.value("--index") else {
            throw CLIError(description: "duplicates needs --index\n\n\(usage)")
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError(description: "no index at \(url.path) (make one with redlamp library index)")
        }
        let trashing = options.has("--trash")
        let confirming = options.has("--confirm") || trashing

        let index = try await LibraryIndex.open(at: url)
        do {
            let operations = FileOperations(index: index)
            if trashing {
                for outcome in try await operations.recover() {
                    let state = outcome.state == .finished ? "finished" : "rolled back"
                    report("\(outcome.title), which a forced quit interrupted: \(state)")
                }
            }
            let sidecars = try await SidecarStore(locator: LibrarySidecars(index: index).locator())
            let finder = DuplicateFinder(index: index, sidecars: sidecars)
            let clock = ContinuousClock()
            let grouping = clock.now
            let candidates = try await finder.candidates()
            let grouped = clock.now - grouping
            report(
                "\(count(candidates.photosGrouped)) photos grouped by content key and size in "
                    + String(format: "%.1f ms", grouped.seconds * 1000)
                    + ": \(count(candidates.photoCount)) candidates in \(count(candidates.groups.count)) groups",
            )
            let reported = Mutex(clock.now)
            let started = clock.now
            let confirmation = try await finder.confirm(candidates, readingFiles: confirming) { progress in
                let due = reported.withLock { last in
                    guard clock.now - last >= .seconds(1) else { return false }
                    last = clock.now
                    return true
                }
                if due {
                    report(
                        "\(count(progress.done)) of \(count(progress.candidates)) candidates; "
                            + "\(megabytes(progress.bytesRead)) of \(megabytes(progress.bytes)) read",
                    )
                }
            }
            if confirming {
                let seconds = max((clock.now - started).seconds, 1e-9)
                report(
                    "\(count(confirmation.hashed)) files read and hashed, \(megabytes(confirmation.bytesRead)) in "
                        + String(
                            format: "%.1f s (%.0f MB/s)", seconds, Double(confirmation.bytesRead) / 1e6 / seconds,
                        )
                        + "; \(count(confirmation.reused)) unchanged since they were hashed",
                )
            }
            let review = try await finder.review(confirmation)
            if trashing {
                try await trash(review, finder: finder, operations: operations, options: options)
            } else if options.has("--json") {
                try print(String(decoding: review.json(), as: UTF8.self))
            } else {
                print(review.text)
            }
            await index.close()
        } catch {
            await index.close()
            throw error
        }
    }

    /// Moves all but each group's proposed copy to the Trash as one batch, once every file it moves
    /// is printed; without `--confirm`, or with `--dry-run`, says what would move and what would stop
    /// it, and moves nothing. Exits 1 when something stops it.
    private static func trash(
        _ review: DuplicateReview, finder: DuplicateFinder, operations: FileOperations, options: Arguments,
    ) async throws {
        let plan = try DuplicateRemovalPlan(review, removing: review.allButProposed)
        let batch = try await finder.trashBatch(for: plan, operations: operations)
        let json = options.has("--json")
        if !json {
            print((review.findings + [""] + plan.lines(batch)).joined(separator: "\n"))
        }
        let dryRun = options.has("--dry-run")
        let outcome: DuplicateRemovalPlan.Outcome = if batch.steps.isEmpty {
            .shown(dryRun: dryRun, stopping: [])
        } else if dryRun || !options.has("--confirm") {
            try await .shown(
                dryRun: dryRun,
                stopping: finder.check(plan, batch, operations: operations, hashing: false).map(\.description)
                    + operations.check(batch).map(\.description),
            )
        } else {
            try await moving(plan, batch, finder: finder, operations: operations)
        }
        if json {
            try print(String(decoding: review.json(plan, batch: batch, outcome: outcome), as: UTF8.self))
        } else if !batch.steps.isEmpty {
            print(DuplicateRemovalPlan.lines(outcome).joined(separator: "\n"))
        }
        if outcome.isStopped {
            throw ExitCode(1)
        }
    }

    /// Checks the plan's copies and those kept for them again, with its progress on stderr, and moves
    /// the copies to the Trash; or says what stopped them, nothing having moved.
    private static func moving(
        _ plan: DuplicateRemovalPlan, _ batch: FileBatch, finder: DuplicateFinder, operations: FileOperations,
    ) async throws -> DuplicateRemovalPlan.Outcome {
        let files = Set(plan.removals.map(\.photo) + plan.removals.map(\.kept.photo)).count
        report("checking the \(count(plan.removals.count)) copies and those kept for them again: \(count(files)) files")
        let clock = ContinuousClock()
        let reported = Mutex(clock.now)
        let started = clock.now
        do {
            let moved = try await finder.trash(plan, batch, operations: operations) { progress in
                let due = reported.withLock { last in
                    guard clock.now - last >= .seconds(1) else { return false }
                    last = clock.now
                    return true
                }
                if due {
                    report(
                        "\(count(progress.done)) of \(count(progress.candidates)) files checked; "
                            + "\(megabytes(progress.bytesRead)) of \(megabytes(progress.bytes)) read",
                    )
                }
            }
            return .moved(moved, seconds: (clock.now - started).seconds)
        } catch let DuplicateRemovalPlan.Refusal.differs(differences) {
            return .stopped(differences.map(\.description))
        } catch let FileOperationError.conflicts(conflicts) {
            return .stopped(conflicts.map(\.description))
        } catch let FileOperationError.failed(path, message) {
            return .stopped(["\(path): \(message); everything the batch had moved was put back"])
        } catch let FileOperationError.stuck(id, path, message) {
            throw CLIError(
                description: "\(path): \(message); the batch (\(id)) couldn't be put back and waits in the "
                    + "journal: redlamp library journal --finish or --roll-back settles it",
            )
        }
    }

    private static func report(_ line: String) {
        FileHandle.standardError.write(Data(("  " + line + "\n").utf8))
    }

    /// `20,000`, whatever the locale.
    private static func count(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }

    private static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }
}

private extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
