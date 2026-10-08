import CryptoKit
import Foundation

public struct BenchIssue: Sendable, Hashable, CustomStringConvertible {
    public enum Severity: Sendable, Hashable {
        case error, warning
    }

    public var severity: Severity
    public var message: String

    public init(_ severity: Severity, _ message: String) {
        self.severity = severity
        self.message = message
    }

    public var description: String {
        "\(severity == .error ? "error" : "warning"): \(message)"
    }
}

public enum BenchLimits {
    public static let assets = 20
    public static let results = 100
    /// For the whole folder, assets and results together.
    public static let bytes: Int64 = 1 << 30
    public static let files = 200
    /// A step's title and detail fit one phone screen.
    public static let stepTitle = 60
    public static let stepDetail = 320
}

public enum BenchError: Error, CustomStringConvertible, Equatable {
    case noManifest(String)
    case invalid([String])
    case outsideFolder(String)
    case notFound(String)

    public var description: String {
        switch self {
        case let .noManifest(path): "\(path) has no \(BenchManifest.fileName)"
        case let .invalid(messages): messages.joined(separator: "; ")
        case let .outsideFolder(path): "\(path) is outside the bench folder"
        case let .notFound(what): "\(what) not found"
        }
    }
}

/// One bench folder on disk: `task.json`, `assets/`, and once worked `results/` with
/// `results.json`. Everything a task needs travels inside it.
public struct BenchFolder: Sendable {
    public let url: URL
    public var manifest: BenchManifest
    public var results: BenchResults

    public init(url: URL, manifest: BenchManifest, results: BenchResults = BenchResults()) {
        self.url = url
        self.manifest = manifest
        self.results = results
    }

    public var id: String {
        manifest.id
    }

    public static func load(_ url: URL) throws -> BenchFolder {
        let manifestURL = url.appending(path: BenchManifest.fileName)
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw BenchError.noManifest(url.lastPathComponent)
        }
        let manifest = try JSONDecoder.bench.decode(BenchManifest.self, from: data)
        let results = try (try? Data(contentsOf: url.appending(path: BenchResults.fileName)))
            .map { try JSONDecoder.bench.decode(BenchResults.self, from: $0) } ?? BenchResults()
        return BenchFolder(url: url, manifest: manifest, results: results)
    }

    public func saveManifest() throws {
        try JSONEncoder.bench.encode(manifest)
            .write(to: url.appending(path: BenchManifest.fileName), options: .atomic)
    }

    public func saveResults() throws {
        try JSONEncoder.bench.encode(results)
            .write(to: url.appending(path: BenchResults.fileName), options: .atomic)
    }

    /// An asset to copy into a new folder.
    public struct NewAsset: Sendable {
        public var file: URL
        public var id: String?
        public var label: String?
        public var chart: Int?
        public var counts: Bool

        public init(file: URL, id: String? = nil, label: String? = nil, chart: Int? = nil, counts: Bool = true) {
            self.file = file
            self.id = id
            self.label = label
            self.chart = chart
            self.counts = counts
        }
    }

    /// Writes a new folder named after the manifest's ID inside `parent`, copying the assets
    /// (APFS clones them) and recording their hashes. Pictures named by steps are copied too.
    public static func create(
        _ manifest: BenchManifest,
        assets: [NewAsset],
        pictures: [URL] = [],
        in parent: URL,
    ) throws -> BenchFolder {
        guard BenchManifest.isValidID(manifest.id) else {
            throw BenchError.invalid(["\(manifest.id) isn't a valid task ID"])
        }
        let url = parent.appending(path: manifest.id, directoryHint: .isDirectory)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else {
            throw BenchError.invalid(["\(manifest.id) already exists in \(parent.lastPathComponent)"])
        }
        let staging = parent.appending(path: ".\(manifest.id)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: staging.appending(path: "assets"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        var manifest = manifest
        var names = Set<String>()
        manifest.assets = try assets.map { asset in
            let name = unique(BenchFile.safeName(asset.file.lastPathComponent), in: &names)
            let relative = "assets/\(name)"
            try fm.copyItem(at: asset.file, to: staging.appending(path: relative))
            let id = asset.id ?? BenchFile.stem(name)
            return try BenchManifest.Asset(
                id: id, file: relative, label: asset.label,
                sha256: BenchFile.sha256(staging.appending(path: relative)),
                bytes: BenchFile.size(staging.appending(path: relative)), chart: asset.chart, counts: asset.counts,
            )
        }
        if !pictures.isEmpty {
            try fm.createDirectory(at: staging.appending(path: "pictures"), withIntermediateDirectories: true)
            for picture in pictures {
                try fm.copyItem(
                    at: picture,
                    to: staging.appending(path: "pictures/\(BenchFile.safeName(picture.lastPathComponent))"),
                )
            }
        }
        let folder = BenchFolder(url: staging, manifest: manifest)
        try folder.saveManifest()
        let errors = folder.validate().filter { $0.severity == .error }
        guard errors.isEmpty else {
            throw BenchError.invalid(errors.map(\.message))
        }
        try fm.moveItem(at: staging, to: url)
        return try load(url)
    }

    private static func unique(_ name: String, in names: inout Set<String>) -> String {
        var candidate = name, n = 2
        while names.contains(candidate.lowercased()) {
            let stem = BenchFile.stem(name), ext = (name as NSString).pathExtension
            candidate = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
            n += 1
        }
        names.insert(candidate.lowercased())
        return candidate
    }

    // MARK: - Files

    /// A file named inside the folder; nil when the path would leave it.
    public func file(_ relative: String) -> URL? {
        guard BenchFile.isSafeRelativePath(relative) else { return nil }
        return url.appending(path: relative)
    }

    // MARK: - Checks

    /// Everything wrong with the folder, as the hub and `redlamp task check` see it. With
    /// `hashes`, every asset and result is read and checked against its SHA-256.
    public func validate(hashes: Bool = true) -> [BenchIssue] {
        var issues: [BenchIssue] = []
        func error(_ message: String) {
            issues.append(BenchIssue(.error, message))
        }
        func warning(_ message: String) {
            issues.append(BenchIssue(.warning, message))
        }
        let m = manifest
        if m.format != BenchManifest.format {
            error("format is \(m.format), not \(BenchManifest.format)")
        }
        if m.version > BenchManifest.formatVersion {
            error("format version \(m.version) needs a newer Redlamp (this one reads \(BenchManifest.formatVersion))")
        }
        if !BenchManifest.isValidID(m.id) {
            error("\(m.id) isn't a valid ID: lowercase letters, digits, -, _ and . only")
        }
        if m.title.trimmingCharacters(in: .whitespaces).isEmpty {
            error("the task has no title")
        }
        if m.assets.count > BenchLimits.assets {
            error("\(m.assets.count) assets, more than \(BenchLimits.assets)")
        }
        if results.results.count > BenchLimits.results {
            error("\(results.results.count) results, more than \(BenchLimits.results)")
        }
        let assetIDs = Set(m.assets.map(\.id)), questionIDs = Set(m.questions.map(\.id))
        if assetIDs.count != m.assets.count {
            error("two assets share an ID")
        }
        func checkFile(_ relative: String, what: String, sha256: String?, bytes: Int?) {
            guard let file = file(relative) else {
                error("\(what) \(relative) is outside the folder")
                return
            }
            guard BenchFile.isRegularFile(file) else {
                error("\(what) \(relative) is missing, or isn't a plain file")
                return
            }
            if let bytes, (try? BenchFile.size(file)) != bytes {
                error("\(what) \(relative) isn't \(bytes) bytes")
            }
            if hashes, let sha256, (try? BenchFile.sha256(file)) != sha256 {
                error("\(what) \(relative) doesn't match its SHA-256")
            }
        }
        for asset in m.assets {
            checkFile(asset.file, what: "asset", sha256: asset.sha256, bytes: asset.bytes)
        }
        for result in results.results {
            checkFile(result.file, what: "result", sha256: result.sha256, bytes: result.bytes)
            if let asset = result.asset, !assetIDs.contains(asset) {
                error("result \(result.file) is paired with \(asset), which isn't an asset")
            }
        }
        if case let .assets(ids) = m.completion {
            for id in ids where !assetIDs.contains(id) {
                error("completion names \(id), which isn't an asset")
            }
        }
        if let screenshot = m.look?.settingsScreenshot {
            checkFile(screenshot, what: "settings screenshot", sha256: nil, bytes: nil)
        }
        for (index, step) in m.steps.enumerated() {
            let name = "step \(index + 1)"
            if step.title.count > BenchLimits.stepTitle {
                warning("\(name)'s title is \(step.title.count) characters; keep it under \(BenchLimits.stepTitle)")
            }
            if let detail = step.detail, detail.count > BenchLimits.stepDetail {
                warning("\(name)'s detail is \(detail.count) characters, too long for one screen; split the step")
            }
            if let picture = step.picture {
                checkFile(picture, what: "\(name)'s picture", sha256: nil, bytes: nil)
            }
            switch step.action {
            case let .answer(question) where !questionIDs.contains(question):
                error("\(name) asks question \(question), which the task doesn't have")
            case let .some(action):
                for id in action.assets ?? [] where !assetIDs.contains(id) {
                    error("\(name) names asset \(id), which the task doesn't have")
                }
            case nil:
                break
            }
        }
        if m.kind != BenchManifest.Kind.lookReference, m.kind != BenchManifest.Kind.lookKit, m.steps.isEmpty {
            warning("the task has no steps")
        }
        if let total = try? BenchFile.totalSize(url), total > BenchLimits.bytes {
            error("the folder holds \(total >> 20) MB, more than \(BenchLimits.bytes >> 20) MB")
        }
        return issues
    }

    // MARK: - Completion

    /// Required assets still without a result.
    public var missing: [String] {
        manifest.requiredAssets.filter { results.current(for: $0) == nil }
    }

    public var unansweredQuestions: [BenchManifest.Question] {
        manifest.questions.filter { $0.required && results.answers[$0.id] == nil }
    }

    /// Every required asset has a result and every required question an answer; a manual task
    /// is complete once the owner marks it done.
    public var isComplete: Bool {
        if case .manual = manifest.completion {
            return results.completed != nil && unansweredQuestions.isEmpty
        }
        return missing.isEmpty && unansweredQuestions.isEmpty
    }

    /// Whether a step's own condition is met: its results are back, or its question answered.
    public func isMet(_ step: BenchManifest.Step) -> Bool {
        switch step.action {
        case let .results(assets):
            (assets ?? manifest.requiredAssets).allSatisfy { results.current(for: $0) != nil }
        case let .answer(question):
            results.answers[question] != nil
        case .share, .save, nil:
            false
        }
    }

    /// A digest of `results.json`, so a sender can tell whether the hub has the latest results.
    public var resultsDigest: String {
        let data = (try? JSONEncoder.bench.encode(results)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Results

    /// Copies a file into `results/` and pairs it; the newest result for an asset is the current
    /// one, so a redo replaces the earlier export.
    @discardableResult
    public mutating func addResult(
        copying source: URL,
        originalName: String? = nil,
        pairer: BenchPairer? = nil,
        received: Date = Date(),
    ) throws -> BenchResult {
        let fm = FileManager.default
        let folder = url.appending(path: BenchResults.folder, directoryHint: .isDirectory)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = originalName ?? source.lastPathComponent
        let name = "\(results.results.count + 1)-\(BenchFile.safeName(original))"
        let destination = folder.appending(path: name)
        try? fm.removeItem(at: destination)
        try fm.copyItem(at: source, to: destination)
        var result = try BenchResult(
            file: "\(BenchResults.folder)/\(name)", originalName: original,
            sha256: BenchFile.sha256(destination), bytes: BenchFile.size(destination), received: received,
        )
        if let match = pairer?.pair(destination, originalName: original, in: self) {
            result.asset = match.asset
            result.pairedBy = match.method
            result.score = match.score
        }
        results.results.append(result)
        if isComplete, results.completed == nil, manifest.completion != .manual {
            results.completed = received
        }
        try saveResults()
        return result
    }

    /// Pairs a result with an asset by hand, or unpairs it with nil.
    public mutating func pair(result id: String, with asset: String?) throws {
        guard let index = results.results.firstIndex(where: { $0.id == id }) else {
            throw BenchError.notFound("result \(id)")
        }
        results.results[index].asset = asset
        results.results[index].pairedBy = asset == nil ? nil : .hand
        results.results[index].score = nil
        if !isComplete {
            results.completed = nil
        } else if results.completed == nil {
            results.completed = Date()
        }
        try saveResults()
    }

    public mutating func removeResult(_ id: String) throws {
        guard let index = results.results.firstIndex(where: { $0.id == id }) else {
            throw BenchError.notFound("result \(id)")
        }
        if let file = file(results.results[index].file) {
            try? FileManager.default.removeItem(at: file)
        }
        results.results.remove(at: index)
        if !isComplete {
            results.completed = nil
        }
        try saveResults()
    }
}

/// File helpers the folder, the store and the hub share.
public enum BenchFile {
    /// Relative, with no `..`, no empty part and nothing absolute, so it stays inside the folder.
    public static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\0"),
              !path.contains("\\") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// A file name that is safe on every file system and in a URL: letters, digits, `-`, `_`
    /// and `.`, everything else as `-`.
    public static func safeName(_ name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        var safe = String(name.map { allowed.contains($0) ? $0 : "-" })
        while safe.hasPrefix(".") {
            safe.removeFirst()
        }
        return safe.isEmpty ? "file" : String(safe.suffix(120))
    }

    public static func stem(_ name: String) -> String {
        (name as NSString).deletingPathExtension
    }

    public static func isRegularFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values?.isRegularFile == true && values?.isSymbolicLink != true
    }

    public static func size(_ url: URL) throws -> Int {
        try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    }

    /// Hex SHA-256, read in 1 MB pieces.
    public static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func totalSize(_ folder: URL) throws -> Int64 {
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        while let file = enumerator?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
