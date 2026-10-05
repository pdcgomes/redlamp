import Foundation
import RedlampDocument
import RedlampLibrary
import Synchronization

extension LibraryCommand {
    /// `redlamp library duplicates`: the exact duplicates in an index (LIB-39), grouped by content
    /// key and size and, with `--confirm`, confirmed by reading every candidate whole; prints the
    /// groups, what removing all but the proposed copies would free, the proposals and why, and the
    /// candidates that couldn't be compared, with its progress on stderr. It removes nothing.
    static func duplicates(_ arguments: [String]) async throws {
        let options = try Arguments(arguments, valued: ["--index"])
        guard options.positional.isEmpty, let path = options.value("--index") else {
            throw CLIError(description: "duplicates needs --index\n\n\(usage)")
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError(description: "no index at \(url.path) (make one with redlamp library index)")
        }
        let confirming = options.has("--confirm")

        let index = try await LibraryIndex.open(at: url)
        let sidecars = try await SidecarStore(locator: LibrarySidecars(index: index).locator())
        let finder = DuplicateFinder(index: index, sidecars: sidecars)
        let clock = ContinuousClock()
        let grouping = clock.now
        let candidates = try await finder.candidates()
        let grouped = clock.now - grouping
        report(
            "\(count(candidates.photosGrouped)) photos grouped by content key and size in "
                + String(format: "%.1f ms", grouped.seconds * 1000) + ": \(count(candidates.photoCount)) candidates "
                + "in \(count(candidates.groups.count)) groups",
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
                    + String(format: "%.1f s (%.0f MB/s)", seconds, Double(confirmation.bytesRead) / 1e6 / seconds)
                    + "; \(count(confirmation.reused)) unchanged since they were hashed",
            )
        }
        let review = try await finder.review(confirmation)
        await index.close()
        if options.has("--json") {
            try print(String(decoding: review.json(), as: UTF8.self))
        } else {
            print(review.text)
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
