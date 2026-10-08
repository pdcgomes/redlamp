import CoreGraphics
import Foundation
import ImageIO
import Observation
import RedlampBench
import RedlampEngineAPI
import RedlampRecipes
import RedlampUI
import UniformTypeIdentifiers

/// Looks to evaluate (TON-38): each look reference in the bench's Done folder, fitted into
/// candidate looks as it arrives, ranked by score, then picked, named and installed. What a fit
/// found is kept beside the reference, in `lab/`, so reopening the Lab doesn't fit again.
@MainActor
@Observable
public final class LabLooks {
    public enum State: Equatable {
        case waiting
        case fitting(String)
        case ready
        case failed(String)
    }

    /// One look reference and what the Lab knows of it.
    public struct Entry: Identifiable {
        public var folder: BenchFolder
        public var state: State
        public var fit: Fit?
        public var pick: Pick?

        public var id: String {
            folder.id
        }

        public var look: BenchManifest.LookReference? {
            folder.manifest.look
        }

        /// "Prequel · Cine Film": the variants of one filter sit together.
        public var filterTitle: String {
            guard let look else { return folder.manifest.title }
            return look.app.isEmpty ? look.filter : "\(look.app) · \(look.filter)"
        }
    }

    /// `lab/candidates.json`.
    public struct Fit: Codable, Sendable {
        public struct Candidate: Codable, Sendable, Identifiable {
            public var kind: LookCandidate.Kind
            public var detail: String
            public var file: String
            public var score: LookScore
            /// The candidate's render of each photo, by the photo's name.
            public var renders: [String: String]

            public var id: String {
                kind.rawValue
            }
        }

        public static let version = 1
        public var version: Int
        public var fitted: Date
        public var summary: String
        public var warnings: [String]
        /// The measured table on a 9³ grid, to find near duplicates among captures.
        public var fingerprint: [Float]
        public var candidates: [Candidate]
        /// The app's export of each photo, by the photo's name, relative to the folder.
        public var exports: [String: String]
    }

    /// `lab/pick.json`: what the owner chose, and what it was installed as.
    public struct Pick: Codable, Sendable {
        public var kind: LookCandidate.Kind
        public var name: String
        public var group: String
        public var recipeID: String
        public var at: Date
        public var scores: [String: Double]
    }

    public private(set) var entries: [Entry] = []
    public var selectedID: String?
    public private(set) var message: String?
    @ObservationIgnored private let store: BenchStore
    @ObservationIgnored private let renderer: RecipeRenderer
    @ObservationIgnored private let catalog: RecipeCatalog
    /// Called when a reference's candidates are ready, with a line saying so.
    @ObservationIgnored public var notify: ((String) -> Void)?

    init(store: BenchStore, renderer: RecipeRenderer, catalog: RecipeCatalog) {
        self.store = store
        self.renderer = renderer
        self.catalog = catalog
        reload()
    }

    public var selected: Entry? {
        entries.first { $0.id == selectedID }
    }

    /// The references in Done, newest first, with what earlier fits found.
    public func reload() {
        let folders = store.folders(.done).filter { $0.manifest.kind == BenchManifest.Kind.lookReference }
        entries = folders.map { folder in
            let fit = Self.read(Fit.self, "candidates.json", in: folder)
                .flatMap { $0.version == Fit.version ? $0 : nil }
            var state: State = fit == nil ? .waiting : .ready
            if let existing = entries.first(where: { $0.id == folder.id }), case .fitting = existing.state {
                state = existing.state
            }
            return Entry(folder: folder, state: state, fit: fit, pick: Self.read(Pick.self, "pick.json", in: folder))
        }
        if selectedID == nil || !entries.contains(where: { $0.id == selectedID }) {
            selectedID = entries.first?.id
        }
    }

    /// References that arrived while the Lab was closed are fitted when it opens.
    public func fitWaiting() {
        for entry in entries where entry.state == .waiting && entry.folder.isComplete {
            fit(entry.id)
        }
    }

    /// A reference just filed by the hub: fit it, and say when its candidates are ready.
    public func arrived(_ arrival: BenchStore.Arrival) {
        guard arrival.folder.manifest.kind == BenchManifest.Kind.lookReference else { return }
        reload()
        fit(arrival.folder.id)
    }

    // MARK: - Fitting

    public func fit(_ id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        if case .fitting = entries[index].state {
            return
        }
        let folder = entries[index].folder
        entries[index].state = .fitting("Reading the exports")
        let renderer = renderer
        Task.detached(priority: .userInitiated) {
            do {
                let fit = try await Self.fit(folder, renderer: renderer) { step in
                    Task { @MainActor in self.update(id, .fitting(step)) }
                }
                await MainActor.run { self.finished(id, fit) }
            } catch {
                await MainActor.run { self.update(id, .failed("\(error)")) }
            }
        }
    }

    private func update(_ id: String, _ state: State) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].state = state
    }

    private func finished(_ id: String, _ fit: Fit) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].fit = fit
        entries[index].state = .ready
        let entry = entries[index]
        let best = fit.candidates.first
        let title = entry.look?.title ?? entry.folder.manifest.title
        notify?(
            "\(title): \(fit.candidates.count) candidates"
                + (best?.score.photoMean.map { String(format: ", best ΔE %.2f", $0) } ?? ""),
        )
    }

    /// Reads the reference, fits and scores the candidates, and writes them into `lab/`.
    nonisolated static func fit(
        _ folder: BenchFolder,
        renderer: RecipeRenderer,
        progress: @escaping @Sendable (String) -> Void,
    ) async throws -> Fit {
        let inputs = try BenchCapture.inputs(folder)
        progress("Measuring the charts")
        let result = try inputs.read()
        let name = "Capture \(folder.manifest.created.formatted(date: .abbreviated, time: .omitted))"
        let candidates = try await LookCandidates.make(
            inputs, result: result, name: name, renderer: renderer, progress: progress,
        )
        let lab = folder.url.appending(path: "lab", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: lab)
        try FileManager.default.createDirectory(
            at: lab.appending(path: "candidates"),
            withIntermediateDirectories: true,
        )
        var written: [Fit.Candidate] = []
        for candidate in candidates {
            let file = "lab/candidates/\(candidate.kind.rawValue).\(Recipe.fileExtension)"
            try RecipeFile.write(candidate.recipe, to: folder.url.appending(path: file))
            var renders: [String: String] = [:]
            for (photo, image) in candidate.renders {
                let path = "lab/renders/\(candidate.kind.rawValue)/\(BenchFile.safeName(photo)).jpg"
                try writeJPEG(image, to: folder.url.appending(path: path))
                renders[photo] = path
            }
            written.append(.init(
                kind: candidate.kind, detail: candidate.detail, file: file, score: candidate.score, renders: renders,
            ))
        }
        var exports: [String: String] = [:]
        for result in folder.results.results {
            if let asset = result.asset.flatMap(folder.manifest.asset), asset.chart == nil {
                exports[asset.label ?? asset.id] = result.file
            }
        }
        var warnings = result.report.warnings
        if result.report.tone.clipped {
            warnings.append("The app clipped some colours; they come back clipped.")
        }
        if result.report.tone.nonMonotonic {
            warnings.append("The table reverses somewhere: the filter isn't monotonic.")
        }
        let fit = Fit(
            version: Fit.version, fitted: Date(), summary: result.report.summary, warnings: warnings,
            fingerprint: LookCandidates.fingerprint(result.table), candidates: written, exports: exports,
        )
        try JSONEncoder.bench.encode(fit).write(to: lab.appending(path: "candidates.json"), options: .atomic)
        return fit
    }

    nonisolated static func writeJPEG(_ image: PixelImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let cg = image.cgImage(),
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL,
                  UTType.jpeg.identifier as CFString,
                  1,
                  nil,
              )
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, cg, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    // MARK: - Reading it back

    /// Other captures whose measured tables are within ΔE 1 of this one's.
    public func nearDuplicates(of entry: Entry) -> [Entry] {
        guard let mine = entry.fit?.fingerprint else { return [] }
        return entries.filter { other in
            guard other.id != entry.id, let theirs = other.fit?.fingerprint else { return false }
            return (LookCandidates.distance(mine, theirs) ?? .infinity) < 1
        }
    }

    public func image(_ relative: String?, in entry: Entry, size: Int = 1600) -> CGImage? {
        guard let relative, let url = entry.folder.file(relative) else { return nil }
        return BenchPairer.image(url, maxLongEdge: size)?.cgImage()
    }

    public func recipe(_ candidate: Fit.Candidate, in entry: Entry) -> Recipe? {
        entry.folder.file(candidate.file).flatMap { try? RecipeFile.read($0).recipe }
    }

    // MARK: - Choosing

    /// A name for the pick: the stem of an earlier pick of the same filter with this variant.
    public func suggestedName(for entry: Entry) -> String {
        guard let look = entry.look else { return "" }
        let earlier = entries.first { other in
            other.id != entry.id && other.pick != nil && other.look?.app == look.app && other.look?.filter == look
                .filter
        }
        guard let name = earlier?.pick?.name else { return "" }
        let stem = name.replacingOccurrences(of: #"\s+\S+$"#, with: "", options: .regularExpression)
        return [stem, look.variant].compactMap(\.self).joined(separator: " ")
    }

    /// Why a name can't be used, or nil: it must be Redlamp's own, never the app's or filter's.
    public func problem(with name: String, for entry: Entry) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Give the look a name" }
        let forbidden = [entry.look?.app, entry.look?.filter, "prequel", "lightroom"]
            .compactMap { $0?.lowercased() }.filter { !$0.isEmpty }
        if let word = forbidden.first(where: { trimmed.lowercased().contains($0) }) {
            return "The name can't contain “\(word)”: looks ship under Redlamp's own names"
        }
        return nil
    }

    /// Installs the chosen candidate under its new name, and records the pick with every
    /// candidate's score, to tune the score's weights later.
    public func install(_ candidate: Fit.Candidate, in entry: Entry, name: String, group: String) {
        if let problem = problem(with: name, for: entry) {
            message = problem
            return
        }
        guard var recipe = recipe(candidate, in: entry) else {
            message = "The candidate's recipe is missing; fit again"
            return
        }
        recipe.id = RecipeNamespace.newLocalID()
        recipe.version = 1
        recipe.name = name.trimmingCharacters(in: .whitespaces)
        recipe.baseLook?.name = recipe.name
        recipe.embeddedBaseLooks = recipe.embeddedBaseLooks.map { package in
            var package = package
            package.name = recipe.name
            return package
        }
        recipe.group = group.isEmpty ? "Captured" : group
        guard let saved = catalog.save(recipe) else {
            message = catalog.lastError ?? "Couldn't install it"
            return
        }
        let pick = Pick(
            kind: candidate.kind, name: saved.name, group: saved.group, recipeID: saved.id, at: Date(),
            scores: Dictionary(uniqueKeysWithValues: (entry.fit?.candidates ?? []).map { (
                $0.kind.rawValue,
                $0.score.total,
            ) }),
        )
        try? JSONEncoder.bench.encode(pick).write(
            to: entry.folder.url.appending(path: "lab/pick.json"),
            options: .atomic,
        )
        message = "Installed “\(saved.name)” in \(saved.group)"
        reload()
    }

    /// A pairwise choice between two candidates on one photo, for the score's weights.
    public func record(
        winner: LookCandidate.Kind?,
        between a: LookCandidate.Kind,
        and b: LookCandidate.Kind,
        photo: String,
        in entry: Entry,
    ) {
        struct Verdict: Encodable {
            var a: String
            var b: String
            var winner: String?
            var photo: String
            var at: Date
        }
        let line = Verdict(a: a.rawValue, b: b.rawValue, winner: winner?.rawValue, photo: photo, at: Date())
        guard var data = try? JSONEncoder.bench.encode(line) else { return }
        data = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\n", with: " ").utf8) + Data([0x0A])
        let url = entry.folder.url.appending(path: "lab/verdicts.jsonl")
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
        message = winner == nil ? "Recorded: about the same" : "Recorded: \(winner!.title) is closer"
    }

    private static func read<T: Decodable>(_: T.Type, _ name: String, in folder: BenchFolder) -> T? {
        (try? Data(contentsOf: folder.url.appending(path: "lab/\(name)"))).flatMap { try? JSONDecoder.bench.decode(
            T.self,
            from: $0,
        ) }
    }
}
