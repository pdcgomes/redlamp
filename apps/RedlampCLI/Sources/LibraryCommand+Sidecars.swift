import Foundation
import RedlampLibrary
import Synchronization

extension LibraryCommand {
    /// `redlamp library sidecars`: where a root keeps its sidecars and how many it has in each
    /// place (LIB-11, LIB-12), and moving them between beside the photos and this Mac. A move a
    /// forced quit interrupted is finished first.
    static func sidecars(_ arguments: [String]) async throws {
        let options = try Arguments(arguments, valued: ["--index", "--move"])
        guard options.positional.count == 1, let path = options.value("--index") else {
            throw CLIError(description: "sidecars needs a root and --index\n\n\(usage)")
        }
        let destination: RootRecord.Sidecars? = try options.value("--move").map { name in
            switch name {
            case "beside": .besidePhotos
            case "mac": .onThisMac
            default: throw CLIError(description: "--move takes beside or mac, not \(name)")
            }
        }
        let dryRun = options.has("--dry-run")
        if dryRun, destination == nil {
            throw CLIError(description: "--dry-run goes with --move")
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError(description: "no index at \(url.path) (make one with redlamp library index)")
        }
        var rootPath = URL(fileURLWithPath: options.positional[0], isDirectory: true).standardizedFileURL.path
        if rootPath.count > 1, rootPath.hasSuffix("/") {
            rootPath.removeLast()
        }
        let index = try await LibraryIndex.open(at: url)
        let library = LibrarySidecars(index: index)
        let roots = try await index.read { try $0.roots() }
        guard let root = roots.first(where: { $0.path == rootPath }) else {
            await index.close()
            let known = roots.isEmpty ? "none" : roots.map(\.path).joined(separator: ", ")
            throw CLIError(description: "\(rootPath) isn't a root of the library at \(url.path) (roots: \(known))")
        }

        var lines: [String] = []
        var failed = false
        let resumed = try await library.resumeMove()
        if let resumed {
            lines.append("Finished a move a forced quit interrupted: \(count(resumed.moved)) moved")
            failed = !resumed.failed.isEmpty
        }
        var plan: SidecarMovePlan?
        var outcome: SidecarMoveOutcome?
        if let destination {
            let planned = try await library.planMove(ofRoot: root.id, to: destination)
            plan = planned
            if !planned.conflicts.isEmpty {
                failed = true
                let photos = planned.conflicts.count == 1 ? "1 photo has" : "\(count(planned.conflicts.count)) photos have"
                lines.append("Nothing moved: \(photos) a sidecar in both places")
                lines += planned.conflicts.prefix(50).map { "  \($0.photo)" }
                if planned.conflicts.count > 50 {
                    lines.append("  and \(count(planned.conflicts.count - 50)) more")
                }
            } else if dryRun {
                lines.append("Would move \(count(planned.items.count)) sidecars \(destinationDescription(destination))")
            } else {
                let reported = Mutex(ContinuousClock.now)
                let moved = try await library.move(planned, progress: { progress in
                    let (done, total) = (progress.done, progress.total)
                    let report = reported.withLock { last in
                        guard ContinuousClock.now - last >= .seconds(1) || done == total else { return false }
                        last = .now
                        return true
                    }
                    if report {
                        FileHandle.standardError.write(Data("  \(count(done)) of \(count(total))\n".utf8))
                    }
                })
                outcome = moved
                failed = failed || !moved.failed.isEmpty || !moved.conflicts.isEmpty
                lines.append("Moved \(count(moved.moved)) sidecars \(destinationDescription(destination))")
                if moved.gone > 0 {
                    lines.append("  \(count(moved.gone)) were gone before they could be moved")
                }
                if !moved.conflicts.isEmpty {
                    lines
                        .append("  \(count(moved.conflicts.count)) turned up in both places and were left as they are:")
                    lines += moved.conflicts.prefix(50).map { "    \($0)" }
                }
                for (photo, message) in moved.failed.sorted(by: { $0.key < $1.key }).prefix(50) {
                    lines.append("  couldn't move \(photo)'s sidecar: \(message)")
                }
            }
        }
        let census = try await library.census(ofRoot: root.id)
        await index.close()

        if options.has("--json") {
            struct Conflict: Encodable {
                let photo: String
                let beside: String
                let onThisMac: String
            }
            struct Move: Encodable {
                let to: String
                let dryRun: Bool
                let planned: Int
                let conflicts: [Conflict]
                let moved: Int?
                let gone: Int?
                let leftInBothPlaces: [String]?
                let failed: [String: String]?
            }
            struct Output: Encodable {
                let root: String
                let sidecars: String
                let beside: Int
                let onThisMac: Int
                let both: Int
                let otherApps: Int
                let resumedMoved: Int?
                let move: Move?
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let move = plan.map { plan in
                Move(
                    to: placementName(plan.destination), dryRun: dryRun, planned: plan.items.count,
                    conflicts: plan.conflicts.map {
                        Conflict(photo: $0.photo, beside: $0.beside.path, onThisMac: $0.onThisMac.path)
                    },
                    moved: outcome?.moved, gone: outcome?.gone, leftInBothPlaces: outcome?.conflicts,
                    failed: outcome?.failed,
                )
            }
            let output = Output(
                root: census.root, sidecars: placementName(census.placement), beside: census.beside,
                onThisMac: census.onThisMac, both: census.both, otherApps: census.otherApps,
                resumedMoved: resumed?.moved, move: move,
            )
            try print(String(decoding: encoder.encode(output), as: UTF8.self))
        } else {
            lines.insert(contentsOf: [
                "\(census.root): sidecars \(placementDescription(census.placement))",
                "  \(count(census.beside)) beside the photos, \(count(census.onThisMac)) on this Mac, "
                    +
                    "\(count(census.both)) in both places; \(count(census.otherApps)) other apps' .xmp beside the photos",
            ], at: 0)
            print(lines.joined(separator: "\n"))
        }
        if failed {
            throw ExitCode(1)
        }
    }

    /// Where a move takes sidecars, as the sentence saying so ends.
    private static func destinationDescription(_ placement: RootRecord.Sidecars) -> String {
        switch placement {
        case .besidePhotos: "beside the photos"
        case .onThisMac: "to this Mac"
        }
    }

    /// `20,000`, whatever the locale.
    private static func count(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }
}
