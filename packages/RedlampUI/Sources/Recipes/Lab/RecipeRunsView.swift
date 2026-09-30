import AppKit
import Charts
import Foundation
import Observation
import RedlampRecipes
import SwiftUI

/// The agent studio's runs, read from `build/recipe-runs/`. The view polls the run folder,
/// so a live run updates as agents write to it. Every human decision (brief approvals,
/// pairwise picks, final picks) is appended to the run's `verdicts.jsonl`.
@MainActor
@Observable
final class RecipeRunsModel {
    let root: URL
    let rater: String
    private(set) var runs: [RunStore] = []
    var selectedRun: String? {
        didSet { reload() }
    }

    private(set) var briefs: [RecipeRun.Brief] = []
    private(set) var candidates: [RecipeRun.Candidate] = []
    private(set) var critiques: [RecipeRun.Critique] = []
    private(set) var scores: [RecipeRun.Score] = []
    private(set) var shortlist: [RecipeRun.Shortlist] = []
    private(set) var verdicts: [RecipeRun.Verdict] = []
    var selectedBrief: String?
    var selectedCandidate: String?
    var pair: (a: String, b: String)?
    private(set) var message: String?
    @ObservationIgnored private var lastModified = Date.distantPast

    init(root: URL, rater: String = NSUserName()) {
        self.root = root
        self.rater = rater
        runs = RunStore.all(root: root)
        selectedRun = runs.first?.id
        reload()
    }

    var store: RunStore? {
        selectedRun.map { RunStore.named($0, root: root) }
    }

    func reload() {
        runs = RunStore.all(root: root)
        guard let store else { return }
        lastModified = store.lastModified
        briefs = store.briefs()
        candidates = store.candidates()
        critiques = store.critiques()
        scores = store.scores()
        shortlist = store.shortlist()
        verdicts = store.verdicts()
        if selectedBrief == nil || !briefs.contains(where: { $0.id == selectedBrief }) {
            selectedBrief = briefs.first?.id
        }
    }

    /// Reloads whenever anything in the run changes.
    func watch() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            if let store, store.lastModified > lastModified {
                reload()
            } else if RunStore.all(root: root).count != runs.count {
                reload()
            }
        }
    }

    func status(_ brief: RecipeRun.Brief) -> RecipeRun.BriefStatus {
        store?.briefStatus(brief) ?? brief.status
    }

    func candidates(for brief: String?) -> [RecipeRun.Candidate] {
        candidates.filter { brief == nil || $0.brief == brief }
    }

    /// Candidates in lineage order, each with its depth below its first ancestor.
    func lineage(for brief: String?) -> [(candidate: RecipeRun.Candidate, depth: Int)] {
        let list = candidates(for: brief)
        let ids = Set(list.map(\.id))
        var children: [String: [RecipeRun.Candidate]] = [:]
        var roots: [RecipeRun.Candidate] = []
        for candidate in list {
            if let parent = candidate.parent, ids.contains(parent) {
                children[parent, default: []].append(candidate)
            } else {
                roots.append(candidate)
            }
        }
        var result: [(RecipeRun.Candidate, Int)] = []
        func visit(_ candidate: RecipeRun.Candidate, _ depth: Int) {
            result.append((candidate, depth))
            for child in children[candidate.id] ?? [] {
                visit(child, depth + 1)
            }
        }
        roots.forEach { visit($0, 0) }
        return result
    }

    func critiques(for candidate: String) -> [RecipeRun.Critique] {
        critiques.filter { $0.candidate == candidate }
    }

    func renderImage(_ candidate: RecipeRun.Candidate) -> NSImage? {
        guard let store, let path = candidate.render else { return nil }
        return NSImage(contentsOf: store.directory.appendingPathComponent(path))
    }

    var humanPairwiseCount: Int {
        verdicts.filter { $0.type == .pairwise && $0.rater != "agent" }.count
    }

    func finalVerdict(_ candidate: String) -> Bool? {
        verdicts.last { $0.type == .final && $0.candidate == candidate }?.approved
    }

    // MARK: - Human decisions

    private func record(_ verdict: RecipeRun.Verdict) {
        do {
            try store?.append(verdict)
            message = nil
        } catch {
            message = "Couldn't record: \(error)"
        }
        reload()
    }

    func decide(brief: RecipeRun.Brief, approved: Bool) {
        record(.brief(brief.id, approved: approved, rater: rater))
    }

    /// Offers two candidates of the selected brief, in random order, for a pairwise pick.
    func nextPair() {
        let options = candidates(for: selectedBrief).filter { $0.lint != RecipeLint.Status.fail.rawValue }
        guard options.count >= 2 else {
            pair = nil
            message = "Needs two candidates that pass lint"
            return
        }
        let judged = Set(verdicts.filter { $0.type == .pairwise }
            .map { [$0.a ?? "", $0.b ?? ""].sorted().joined(separator: "|") })
        var pairs: [(String, String)] = []
        for (i, a) in options.enumerated() {
            for b in options[(i + 1)...] where !judged.contains([a.id, b.id].sorted().joined(separator: "|")) {
                pairs.append((a.id, b.id))
            }
        }
        guard let chosen = pairs.randomElement() else {
            pair = nil
            message = "Every pair for this brief has a human verdict"
            return
        }
        pair = Bool.random() ? chosen : (chosen.1, chosen.0)
    }

    func pick(winner: String?) {
        guard let pair else { return }
        record(.pairwise(pair.a, pair.b, winner: winner, brief: selectedBrief, rater: rater))
        nextPair()
    }

    func decide(final candidate: String, approved: Bool) {
        record(.final(candidate, approved: approved, brief: selectedBrief, rater: rater))
    }

    /// Copies a chosen candidate into My Recipes.
    func promote(_ candidate: String, into catalog: RecipeCatalog) {
        guard var recipe = store?.recipe(for: candidate) else { return }
        recipe.id = RecipeNamespace.newLocalID()
        recipe.version = 1
        recipe.group = "My Recipes"
        if catalog.save(recipe) != nil {
            message = "“\(recipe.name)” is in My Recipes"
        } else {
            message = catalog.lastError
        }
    }
}

struct RecipeRunsView: View {
    let model: RecipeLabModel
    @State private var runs: RecipeRunsModel?

    var body: some View {
        Group {
            if let runs {
                RunsContent(runs: runs, catalog: model.catalog)
                    .task { await runs.watch() }
            } else {
                ContentUnavailableView(
                    "No repository", systemImage: "folder.badge.questionmark",
                    description: Text("The Lab needs the checkout's root to find build/recipe-runs."),
                )
            }
        }
        .onAppear {
            if runs == nil, let root = model.root {
                runs = RecipeRunsModel(root: root)
            }
        }
    }
}

private struct RunsContent: View {
    @Bindable var runs: RecipeRunsModel
    let catalog: RecipeCatalog

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Run", selection: $runs.selectedRun) {
                    ForEach(runs.runs, id: \.id) { Text($0.id).tag(Optional($0.id)) }
                }
                .labelsHidden()
                if runs.runs.isEmpty {
                    Text("No runs yet. Start one with research/recipe-studio (see docs/recipes/agent-studio.md).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Briefs").font(.headline)
                List(selection: $runs.selectedBrief) {
                    ForEach(runs.briefs) { brief in
                        BriefRow(brief: brief, status: runs.status(brief)) { approved in
                            runs.decide(brief: brief, approved: approved)
                        }
                        .tag(brief.id)
                    }
                }
                .frame(minHeight: 200)
                Text("\(runs.humanPairwiseCount) human pairwise verdicts (about 200 before trusting critics)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(minWidth: 240, idealWidth: 280)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let message = runs.message {
                        Text(message).font(.caption).foregroundStyle(.orange)
                    }
                    progressChart
                    lineage
                    pairwise
                    shortlistSection
                }
                .padding(12)
            }
            .frame(minWidth: 360)
        }
    }

    private var progressChart: some View {
        let points = runs.scores.filter { $0.brief == runs.selectedBrief || runs.selectedBrief == nil }
        let best = Dictionary(grouping: points, by: \.iteration).map { ($0.key, $0.value.map(\.rating).max() ?? 0) }
            .sorted { $0.0 < $1.0 }
        return VStack(alignment: .leading, spacing: 4) {
            Text("Best rating by iteration").font(.headline)
            if best.isEmpty {
                Text("No scores yet").font(.caption).foregroundStyle(.secondary)
            } else {
                Chart(best, id: \.0) { point in
                    LineMark(x: .value("Iteration", point.0), y: .value("Rating", point.1))
                    PointMark(x: .value("Iteration", point.0), y: .value("Rating", point.1))
                }
                .frame(height: 120)
            }
        }
    }

    private var lineage: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Candidates").font(.headline)
            ForEach(runs.lineage(for: runs.selectedBrief), id: \.candidate.id) { entry in
                let candidate = entry.candidate
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(String(repeating: "  ", count: entry.depth) + (entry.depth > 0 ? "↳ " : "") + candidate.id)
                            .font(.caption.monospaced())
                        Text(candidate.origin).font(.caption2).foregroundStyle(.secondary)
                        if let lint = candidate.lint, let status = RecipeLint.Status(rawValue: lint) {
                            LintBadge(status: status)
                        }
                        if let rating = candidate.rating {
                            Text(String(format: "rating %.2f", rating)).font(.caption2.monospacedDigit())
                        }
                        if let distance = candidate.fingerprintDistance {
                            Text(String(format: "distance %.2f", distance)).font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(runs.selectedCandidate == candidate.id ? "Hide" : "Show") {
                            runs.selectedCandidate = runs.selectedCandidate == candidate.id ? nil : candidate.id
                        }
                        .controlSize(.mini)
                    }
                    if runs.selectedCandidate == candidate.id {
                        if let image = runs.renderImage(candidate) {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 320)
                        }
                        if let notes = candidate.notes {
                            Text(notes).font(.caption)
                        }
                        ForEach(Array(runs.critiques(for: candidate.id).enumerated()), id: \.offset) { _, critique in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(critique.critic) · " + critique.scores.sorted { $0.key < $1.key }
                                    .map { "\($0.key) \(String(format: "%.1f", $0.value))" }.joined(separator: ", "))
                                    .font(.caption2.weight(.semibold))
                                if let notes = critique.notes {
                                    Text(notes).font(.caption2)
                                }
                                ForEach(critique.changeRequests ?? [], id: \.self) {
                                    Text("→ \($0)").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var pairwise: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Pairwise").font(.headline)
                Button("Next Pair") { runs.nextPair() }.controlSize(.small)
            }
            if let pair = runs.pair,
               let a = runs.candidates.first(where: { $0.id == pair.a }),
               let b = runs.candidates.first(where: { $0.id == pair.b }) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach([a, b], id: \.id) { candidate in
                        VStack {
                            if let image = runs.renderImage(candidate) {
                                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                            }
                            Button(candidate.id == a.id ? "Left is better" : "Right is better") {
                                runs.pick(winner: candidate.id)
                            }
                        }
                    }
                }
                Button("About the same") { runs.pick(winner: nil) }.controlSize(.small)
                Text("Order is random; names are hidden on purpose.").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var shortlistSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Shortlist").font(.headline)
            let entries = runs.shortlist.filter { $0.brief == runs.selectedBrief }.flatMap(\.candidates)
            if entries.isEmpty {
                Text("The Selector hasn't shortlisted anything for this brief yet.").font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(entries, id: \.self) { id in
                HStack {
                    Text(id).font(.caption.monospaced())
                    if let verdict = runs.finalVerdict(id) {
                        Text(verdict ? "picked" : "turned down").font(.caption2)
                            .foregroundStyle(verdict ? .green : .secondary)
                    }
                    Spacer()
                    Button("Pick") { runs.decide(final: id, approved: true) }
                    Button("Turn Down") { runs.decide(final: id, approved: false) }
                    Button("Add to My Recipes") { runs.promote(id, into: catalog) }
                }
                .controlSize(.small)
            }
        }
    }
}

private struct BriefRow: View {
    let brief: RecipeRun.Brief
    let status: RecipeRun.BriefStatus
    let decide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(brief.title).font(.caption.weight(.semibold))
                Spacer()
                Text(status.rawValue).font(.caption2)
                    .foregroundStyle(status == .approved ? .green : (status == .rejected ? .red : .orange))
            }
            Text(brief.description).font(.caption2).foregroundStyle(.secondary).lineLimit(4)
            if status == .proposed {
                HStack {
                    Button("Approve") { decide(true) }
                    Button("Reject") { decide(false) }
                }
                .controlSize(.mini)
            }
        }
        .padding(.vertical, 2)
    }
}
