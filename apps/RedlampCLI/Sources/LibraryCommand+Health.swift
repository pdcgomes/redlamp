import Foundation
import RedlampDocument
import RedlampLibrary
import Synchronization

/// `redlamp library health`: Library Health's checks over an index (LIB-40), each listing the photos
/// needing a decision with its reason and proposal, and how long it took; checks with nothing to
/// decide aren't listed. `--trash` and `--rename` carry one check's proposals out as one journaled
/// batch that `undo` takes back, only with `--confirm`; `--keep` and `--unkeep` keep findings anyway
/// and take them back.
extension LibraryCommand {
    static func health(_ arguments: [String]) async throws {
        let options = try Arguments(
            arguments, valued: ["--index", "--rule", "--trash", "--keep", "--unkeep", "--choose", "--limit"],
        )
        guard let path = options.value("--index") else {
            throw CLIError(description: "health needs --index\n\n\(usage)")
        }
        let rule = try pairRule(options.value("--rule"))
        try await withOperations(path) { operations in
            let health = LibraryHealth(operations: operations)
            if options.has("--hash") {
                try await hash(health)
            }
            if let name = options.value("--keep") ?? options.value("--unkeep") {
                try await keep(
                    health,
                    check: check(named: name, rule: rule),
                    keeping: options.value("--keep") != nil,
                    photos: options.positional,
                )
            } else if options.has("--kept") {
                try await kept(health, json: options.has("--json"))
            } else if let name = options.value("--trash") {
                let check = try check(named: name, rule: rule)
                guard check != .extensions else {
                    throw CLIError(description: "wrong extensions are renamed, with --rename, not moved to the Trash")
                }
                try await act(health, check: check, options: options)
            } else if options.has("--rename") {
                try await act(health, check: .extensions, options: options)
            } else {
                guard options.positional.isEmpty else {
                    throw CLIError(description: "health takes photos only with --keep or --unkeep\n\n\(usage)")
                }
                try await list(health, rule: rule, limit: options.int("--limit"), json: options.has("--json"))
            }
        }
    }

    // MARK: - Listing

    private static func list(_ health: LibraryHealth, rule: PairRule, limit: Int?, json: Bool) async throws {
        let clock = ContinuousClock()
        let loading = clock.now
        try await health.engine.load()
        let loaded = clock.now - loading
        var checks: [(findings: HealthFindings, elapsed: Duration)] = []
        for check in HealthCheck.all(pairs: rule) {
            let started = clock.now
            let findings = try await health.findings(check)
            checks.append((findings, clock.now - started))
        }
        let paths = try await paths(of: checks.flatMap(\.findings.photos), in: health.index)
        if json {
            return try print(String(decoding: self.json(checks, paths: paths), as: UTF8.self))
        }
        report("column store loaded in \(milliseconds(loaded)); \(count(health.engine.store?.count ?? 0)) photos")
        var lines: [String] = []
        for (findings, elapsed) in checks {
            report("\(findings.check.title.lowercased()) checked in \(milliseconds(elapsed))")
            guard !findings.isEmpty else { continue }
            lines.append(heading(findings) + " (\(milliseconds(elapsed)))")
            for finding in findings.findings.prefix(limit ?? .max) {
                lines.append("  " + line(finding, path: paths[finding.photo] ?? "photo \(finding.photo)"))
            }
            if let limit, findings.findings.count > limit {
                lines.append("  and \(count(findings.findings.count - limit)) more")
            }
        }
        if lines.isEmpty {
            lines.append("Nothing needs a decision")
        }
        let kept = checks.reduce(0) { $0 + $1.findings.keptAnyway }
        if kept > 0 {
            lines.append("\(count(kept)) kept anyway: --kept lists them")
        }
        if let unconfirmed = checks.first(where: { $0.findings.check == .duplicates })?.findings.unconfirmed,
           unconfirmed > 0 {
            lines.append("\(count(unconfirmed)) duplicate candidates not compared whole yet: --hash reads them")
        }
        print(lines.joined(separator: "\n"))
    }

    /// `Exact duplicates: 4 photos in 2 groups, 2 to the Trash, 1 listed apart`.
    private static func heading(_ findings: HealthFindings) -> String {
        var heading = findings.check.title
        if case let .pairs(rule) = findings.check {
            heading += rule == .keepRaw ? ", keeping the raws" : ", keeping the JPEGs"
        }
        let photos = findings.findings.count
        heading += ": \(count(photos)) photo\(photos == 1 ? "" : "s")"
        if findings.check == .duplicates {
            let groups = Set(findings.findings.compactMap(\.group)).count
            heading += " in \(count(groups)) group\(groups == 1 ? "" : "s")"
        }
        let proposed = findings.proposed.count
        let action = findings.check == .extensions ? "to rename" : "to the Trash"
        heading += ", \(count(proposed)) \(action)"
        let apart = findings.findings.count { $0.apart != nil }
        if apart > 0 {
            heading += ", \(count(apart)) listed apart"
        }
        return heading
    }

    /// `/Photos/IMG_4.JPG  named .JPG, holds HEIC; rename to IMG_4.HEIC`.
    private static func line(_ finding: HealthFinding, path: String) -> String {
        var line = path + "  " + finding.reason.description
        if let apart = finding.apart {
            line += "; \(apart): left out unless chosen"
        } else if let proposal = finding.proposal, proposal != .keep {
            line += "; \(proposal)"
        } else if case let .damage(damage) = finding.reason, damage.isForbidden {
            line += "; nothing proposed: Redlamp isn't allowed to read it, so it may be whole"
        }
        return line
    }

    private static func json(_ checks: [(findings: HealthFindings, elapsed: Duration)], paths: [Int64: String]) throws
        -> Data {
        struct Finding: Encodable {
            let photo: Int64
            let path: String?
            let reason: String
            let proposal: String?
            let renameTo: String?
            let apart: String?
            let group: String?
        }
        struct Check: Encodable {
            let check: String
            let title: String
            let rule: String?
            let count: Int
            let proposed: Int
            let apart: Int
            let keptAnyway: Int
            let unconfirmed: Int
            let milliseconds: Double
            let findings: [Finding]
        }
        let output = checks.filter { !$0.findings.isEmpty }.map { findings, elapsed in
            var rule: String?
            if case let .pairs(pairs) = findings.check {
                rule = pairs.rawValue
            }
            return Check(
                check: findings.check.kind.rawValue, title: findings.check.title, rule: rule,
                count: findings.findings.count, proposed: findings.proposed.count,
                apart: findings.findings.count { $0.apart != nil }, keptAnyway: findings.keptAnyway,
                unconfirmed: findings.unconfirmed, milliseconds: elapsed.seconds * 1000,
                findings: findings.findings.map { finding in
                    let group: String? = switch finding.group {
                    case let .duplicates(sha256)?: sha256.map { String(format: "%02x", $0) }.joined()
                    case let .pair(kept)?: paths[kept]
                    case nil: nil
                    }
                    return Finding(
                        photo: finding.photo, path: paths[finding.photo], reason: finding.reason.description,
                        proposal: finding.proposal.map(proposalName), renameTo: finding.proposal?.renamed,
                        apart: finding.apart?.description, group: group,
                    )
                },
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(["checks": output])
    }

    private static func proposalName(_ proposal: HealthProposal) -> String {
        switch proposal {
        case .trash: "trash"
        case .keep: "keep"
        case .rename: "rename"
        }
    }

    // MARK: - Acting

    /// Prints every file `check`'s batch would move and the findings it leaves out, then runs it only
    /// with `--confirm` and without `--dry-run`; otherwise says what would stop it, moving nothing.
    /// Exits 1 when something stops it.
    private static func act(_ health: LibraryHealth, check: HealthCheck, options: Arguments) async throws {
        if case .pairs(.keepBoth) = check {
            throw CLIError(description: "pairs go to the Trash only under a rule: --rule raw or --rule jpeg")
        }
        let findings = try await health.findings(check)
        let chosen = try await ids(of: options.values("--choose"), in: health.index)
        let plan = try await health.plan(findings, choosing: Set(chosen))
        let paths = try await paths(of: findings.photos, in: health.index)
        let json = options.has("--json")
        if !json {
            var lines = [heading(findings)]
            for item in plan.batch.steps.flatMap(\.items) {
                lines.append("  \(item.source) → \(item.destination ?? "the Trash")")
            }
            if !plan.leftOut.isEmpty {
                lines.append("Left out:")
                lines += plan.leftOut.map { "  " + line($0, path: paths[$0.photo] ?? "photo \($0.photo)") }
            }
            print(lines.joined(separator: "\n"))
        }
        var stopping: [String] = []
        var outcome: FileOutcome?
        if plan.batch.steps.isEmpty {
            if !json {
                print("\(plan.batch.title): nothing to do")
            }
        } else if options.has("--dry-run") || !options.has("--confirm") {
            stopping = try await health.check(plan) + health.operations.check(plan.batch).map(\.description)
            if !json {
                print("\(plan.batch.title): nothing was moved"
                    + (options.has("--dry-run") ? "" : "; --confirm moves them")
                    + (stopping.isEmpty ? "" : ", and this would stop it:"))
                stopping.prefix(50).forEach { print("  \($0)") }
            }
        } else {
            do {
                outcome = try await health.run(plan)
            } catch let HealthError.changed(differences) {
                stopping = differences
            } catch let DuplicateRemovalPlan.Refusal.differs(differences) {
                stopping = differences.map(\.description)
            } catch let FileOperationError.conflicts(conflicts) {
                stopping = conflicts.map(\.description)
            }
            if !json {
                if let outcome {
                    let photos = "\(count(outcome.photos)) photo\(outcome.photos == 1 ? "" : "s")"
                    print("\(outcome.title): done, \(photos); redlamp library undo takes it back")
                } else {
                    print("\(plan.batch.title): nothing was moved, since")
                    stopping.prefix(50).forEach { print("  \($0)") }
                }
            }
        }
        if json {
            struct Move: Encodable {
                let from: String
                let to: String?
            }
            struct Output: Encodable {
                let title: String
                let moves: [Move]
                let leftOut: [String]
                let stopping: [String]
                let moved: Bool
                let batch: String?
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try print(String(decoding: encoder.encode(Output(
                title: plan.batch.title,
                moves: plan.batch.steps.flatMap(\.items).map { Move(from: $0.source, to: $0.destination) },
                leftOut: plan.leftOut.map { paths[$0.photo] ?? "photo \($0.photo)" }, stopping: stopping,
                moved: outcome != nil, batch: outcome?.batch.uuidString,
            )), as: UTF8.self))
        }
        if !stopping.isEmpty {
            throw ExitCode(1)
        }
    }

    // MARK: - Keep Anyway

    private static func keep(
        _ health: LibraryHealth,
        check: HealthCheck,
        keeping: Bool,
        photos: [String],
    ) async throws {
        guard !photos.isEmpty else {
            throw CLIError(description: "\(keeping ? "--keep" : "--unkeep") needs the photos it's for")
        }
        let ids = try await ids(of: photos, in: health.index)
        if keeping {
            let findings = try await health.findings(check)
            let found = ids.filter { findings.finding(for: $0) != nil }
            guard found.count == ids.count else {
                throw CLIError(description: "the \(check.title.lowercased()) check doesn't find "
                    + "\(ids.count - found.count) of these photos")
            }
            try await health.keepAnyway(found, in: findings)
            print("\(count(found.count)) kept anyway: the \(check.title.lowercased()) check leaves them out")
        } else {
            let kept = try await health.keptAnyway().filter { entry in
                entry.kept.check == check.kind && entry.photos.contains { ids.contains($0) }
            }
            try await health.takeBack(kept.map(\.kept))
            print("\(count(kept.count)) taken back: the \(check.title.lowercased()) check lists them again")
        }
    }

    private static func kept(_ health: LibraryHealth, json: Bool) async throws {
        let kept = try await health.keptAnyway()
        let paths = try await paths(of: kept.flatMap(\.photos), in: health.index)
        if json {
            struct Entry: Encodable {
                let check: String
                let photos: [String]
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return try print(String(decoding: encoder.encode(kept.map { entry in
                Entry(check: entry.kept.check.rawValue, photos: entry.photos.compactMap { paths[$0] })
            }), as: UTF8.self))
        }
        guard !kept.isEmpty else { return print("Nothing is kept anyway") }
        for entry in kept {
            let photos = entry.photos.compactMap { paths[$0] }
            print("\(entry.kept.check.rawValue): " +
                (photos.isEmpty ? "no photo in the library" : photos.joined(separator: ", ")))
        }
    }

    // MARK: - Helpers

    /// Reads the duplicate candidates no recorded hash stands for whole, with its progress on stderr.
    private static func hash(_ health: LibraryHealth) async throws {
        let clock = ContinuousClock()
        let reported = Mutex(clock.now)
        let confirmation = try await health.confirmDuplicates { progress in
            let due = reported.withLock { last in
                guard clock.now - last >= .seconds(1) else { return false }
                last = clock.now
                return true
            }
            if due {
                report("\(count(progress.done)) of \(count(progress.candidates)) candidates read")
            }
        }
        report("\(count(confirmation.hashed)) duplicate candidates read whole, "
            + "\(count(confirmation.reused)) unchanged since they were")
    }

    private static func pairRule(_ text: String?) throws -> PairRule {
        guard let text else { return .keepBoth }
        guard let rule = PairRule(rawValue: text.lowercased()) else {
            throw CLIError(description: "--rule is both, raw or jpeg")
        }
        return rule
    }

    private static func check(named name: String, rule: PairRule) throws -> HealthCheck {
        switch HealthCheck.Kind(rawValue: name.lowercased()) {
        case .duplicates: return .duplicates
        case .pairs: return .pairs(rule)
        case .damaged: return .damaged
        case .extensions: return .extensions
        case nil: throw CLIError(description: "\(name) isn't a check: duplicates, pairs, damaged or extensions")
        }
    }

    /// The IDs of the photos at `paths`, in order.
    private static func ids(of paths: [String], in index: LibraryIndex) async throws -> [Int64] {
        let standardized = paths.map { LibraryIndexPath.standardized($0) }
        return try await index.read { reader in
            try standardized.map { path in
                guard let photo = try reader.photo(path: path) ?? reader
                    .photo(path: path.precomposedStringWithCanonicalMapping)
                else { throw CLIError(description: "\(path) isn't in the library") }
                return photo.id
            }
        }
    }

    /// Each photo's path, by ID.
    private static func paths(of ids: [Int64], in index: LibraryIndex) async throws -> [Int64: String] {
        let unique = Array(Set(ids))
        return try await index.read { reader in
            try Dictionary(reader.photosWithPaths(unique)
                .map { ($0.photo.id, $0.folder + "/" + $0.photo.name) }) { first, _ in
                    first
                }
        }
    }

    private static func report(_ line: String) {
        FileHandle.standardError.write(Data(("  " + line + "\n").utf8))
    }

    private static func milliseconds(_ duration: Duration) -> String {
        String(format: "%.1f ms", duration.seconds * 1000)
    }

    /// `20,000`, whatever the locale.
    private static func count(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }
}

/// A path as the index keeps it: standardised, without a trailing slash.
private enum LibraryIndexPath {
    static func standardized(_ text: String) -> String {
        let path = URL(fileURLWithPath: text).standardizedFileURL.path
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

private extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
