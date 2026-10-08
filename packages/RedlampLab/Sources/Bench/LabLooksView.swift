import AppKit
import RedlampBench
import RedlampRecipes
import SwiftUI

/// The Lab's Looks tab (TON-38): look references made on the iPhone, each fitted into ranked
/// candidates, compared large with the app's own exports, then picked, named and installed.
struct LabLooksView: View {
    @Bindable var looks: LabLooks

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360, maxHeight: .infinity)
            Group {
                if let entry = looks.selected {
                    LookDetailView(looks: looks, entry: entry)
                        .id(entry.id)
                } else {
                    ContentUnavailableView(
                        "No look references yet",
                        systemImage: "camera.filters",
                        description: Text(
                            "Make one with New Look in Redlamp Bench on the iPhone; it's fitted here as it arrives.",
                        ),
                    )
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            looks.reload()
            looks.fitWaiting()
        }
    }

    private var list: some View {
        List(selection: $looks.selectedID) {
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.entries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.look
                                .map {
                                    [$0.variant.map { "Variant \($0)" }, $0.settings].compactMap(\.self)
                                        .joined(separator: " · ")
                                } ?? "")
                                .lineLimit(1)
                            Text(status(entry)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .tag(entry.id)
                    }
                }
            }
        }
    }

    private var groups: [(title: String, entries: [LabLooks.Entry])] {
        var order: [String] = []
        var byTitle: [String: [LabLooks.Entry]] = [:]
        for entry in looks.entries {
            if byTitle[entry.filterTitle] == nil {
                order.append(entry.filterTitle)
            }
            byTitle[entry.filterTitle, default: []].append(entry)
        }
        return order.map { ($0, byTitle[$0] ?? []) }
    }

    private func status(_ entry: LabLooks.Entry) -> String {
        if let pick = entry.pick {
            return "Installed as \(pick.name)"
        }
        switch entry.state {
        case .waiting: return entry.folder.isComplete ? "Waiting to be fitted" : "Not complete: \(entry.folder.summary)"
        case let .fitting(step): return step
        case let .failed(reason): return "Couldn't fit: \(reason)"
        case .ready:
            guard let best = entry.fit?.candidates.first else { return "No candidates" }
            return String(format: "%@ first, %.1f", best.kind.title, best.score.total)
        }
    }
}

struct LookDetailView: View {
    @Bindable var looks: LabLooks
    let entry: LabLooks.Entry
    @State private var candidateID: String?
    @State private var photo: String?
    @State private var mode = Mode.split
    @State private var split = 0.5
    @State private var against: String?
    @State private var name = ""
    @State private var group = "Captured"

    enum Mode: String, CaseIterable {
        case split = "Split"
        case sideBySide = "A | B"
        case flicker = "Flicker"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let fit = entry.fit {
                    candidates(fit)
                    if let candidate = selectedCandidate(fit) {
                        compare(fit, candidate)
                        pairwise(fit, candidate)
                        install(candidate)
                    }
                } else if case let .fitting(step) = entry.state {
                    ProgressView(step).controlSize(.small)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            name = entry.pick?.name ?? looks.suggestedName(for: entry)
            if case .waiting = entry.state, entry.folder.isComplete {
                looks.fit(entry.id)
            }
        }
    }

    private func selectedCandidate(_ fit: LabLooks.Fit) -> LabLooks.Fit.Candidate? {
        fit.candidates.first { $0.id == candidateID } ?? fit.candidates.first
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.look?.title ?? entry.folder.manifest.title).font(.title2.weight(.semibold))
                Spacer()
                Button("Fit Again") { looks.fit(entry.id) }
                    .disabled(entry.state != .ready && entry.state != .waiting && !isFailed)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([entry.folder.url])
                } label: {
                    Image(systemName: "folder")
                }
                .help("Show in Finder")
            }
            .controlSize(.small)
            if let look = entry.look {
                Text("Settings: \(look.settings ?? "defaults") · kit: \(look.kitSet.rawValue)")
                    .foregroundStyle(.secondary)
                if let screenshot = look.settingsScreenshot, let image = looks.image(screenshot, in: entry, size: 900) {
                    Image(nsImage: NSImage(cgImage: image, size: .zero)).resizable().scaledToFit().frame(maxHeight: 160)
                }
            }
            if let fit = entry.fit {
                Text(fit.summary.components(separatedBy: "\n").prefix(3).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                ForEach(fit.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }
            let twins = looks.nearDuplicates(of: entry)
            if !twins.isEmpty {
                Label(
                    "Nearly the same as \(twins.map { $0.look?.title ?? $0.id }.joined(separator: ", ")) (within ΔE 1)",
                    systemImage: "square.on.square",
                )
                .font(.caption).foregroundStyle(.orange)
            }
            if case let .failed(reason) = entry.state {
                Text(reason).foregroundStyle(.red)
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = entry.state {
            return true
        }
        return false
    }

    // MARK: - Candidates

    private func candidates(_ fit: LabLooks.Fit) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Candidates, closest first").font(.headline)
            ForEach(Array(fit.candidates.enumerated()), id: \.element.id) { index, candidate in
                Button {
                    candidateID = candidate.id
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: selectedCandidate(fit)?.id == candidate
                            .id ? "largecircle.fill.circle" : "circle")
                        Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(candidate.kind.title).fontWeight(.medium)
                                Text(String(format: "%.1f", candidate.score.total)).monospacedDigit()
                                if entry.pick?.kind == candidate.kind {
                                    Text("installed").font(.caption).foregroundStyle(.green)
                                }
                            }
                            Text(parts(candidate.score)).font(.caption).foregroundStyle(.secondary)
                            Text(candidate.detail).font(.caption).foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(6)
                .background(
                    selectedCandidate(fit)?.id == candidate.id ? Color.accentColor.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 6),
                )
            }
        }
    }

    private func parts(_ s: LookScore) -> String {
        [
            s.photoMean
                .map { String(format: "ΔE %.2f (p90 %.2f) on %@", $0, s.photoP90 ?? 0, s.basis) } ??
                "scored on \(s.basis)",
            s.grain.map { String(format: "grain %+.4f", $0) },
            s.sharpness.map { String(format: "sharpness %.2f", $0) },
            s.glow.map { String(format: "glow %+.3f", $0) },
            String(format: "%.2f from the charts", s.chartDeparture),
            s.heldOut ? "each photo held out" : nil,
        ].compactMap(\.self).joined(separator: " · ")
    }

    // MARK: - Compare

    private func photos(_ fit: LabLooks.Fit) -> [String] {
        fit.exports.keys.sorted()
    }

    private func compare(_ fit: LabLooks.Fit, _ candidate: LabLooks.Fit.Candidate) -> some View {
        let names = photos(fit).filter { candidate.renders[$0] != nil }
        let current = photo.flatMap { names.contains($0) ? $0 : nil } ?? names.first
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("The app's export against \(candidate.kind.title)").font(.headline)
                Spacer()
                Picker("Photo", selection: Binding(get: { current }, set: { photo = $0 })) {
                    ForEach(names, id: \.self) { Text($0).tag(Optional($0)) }
                }
                .frame(maxWidth: 260)
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .controlSize(.small)
            if let current,
               let export = looks.image(fit.exports[current], in: entry),
               let render = looks.image(candidate.renders[current], in: entry) {
                ComparePane(a: export, b: render, aTitle: "App", bTitle: "Redlamp", mode: mode, split: $split)
                    .frame(minHeight: 420, maxHeight: 640)
            } else {
                Text("Scored on the charts only: there's no photo to compare.").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Pairwise

    private func pairwise(_ fit: LabLooks.Fit, _ candidate: LabLooks.Fit.Candidate) -> some View {
        let others = fit.candidates.filter { $0.id != candidate.id }
        let other = others.first { $0.id == against } ?? others.first
        let current = photo ?? photos(fit).first
        return Group {
            if let other, let current,
               let a = looks.image(candidate.renders[current], in: entry),
               let b = looks.image(other.renders[current], in: entry) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Two candidates, for a close call").font(.headline)
                        Spacer()
                        Picker("Against", selection: Binding(get: { other.id }, set: { against = $0 })) {
                            ForEach(others) { Text($0.kind.title).tag($0.id) }
                        }
                        .frame(maxWidth: 220)
                    }
                    .controlSize(.small)
                    ComparePane(
                        a: a,
                        b: b,
                        aTitle: candidate.kind.title,
                        bTitle: other.kind.title,
                        mode: .sideBySide,
                        split: $split,
                    )
                    .frame(minHeight: 260, maxHeight: 360)
                    HStack {
                        Button("Left Is Closer") { looks.record(
                            winner: candidate.kind,
                            between: candidate.kind,
                            and: other.kind,
                            photo: current,
                            in: entry,
                        ) }
                        Button("About the Same") { looks.record(
                            winner: nil,
                            between: candidate.kind,
                            and: other.kind,
                            photo: current,
                            in: entry,
                        ) }
                        Button("Right Is Closer") { looks.record(
                            winner: other.kind,
                            between: candidate.kind,
                            and: other.kind,
                            photo: current,
                            in: entry,
                        ) }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Install

    private func install(_ candidate: LabLooks.Fit.Candidate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Install \(candidate.kind.title)").font(.headline)
            HStack {
                TextField("Redlamp's name for it", text: $name).frame(maxWidth: 260)
                TextField("Group", text: $group).frame(maxWidth: 160)
                Button("Install") { looks.install(candidate, in: entry, name: name, group: group) }
                    .disabled(looks.problem(with: name, for: entry) != nil)
            }
            if let problem = looks.problem(with: name, for: entry), !name.isEmpty {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            if let message = looks.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Two images of the same photo: a split with a handle, side by side, or flickering between them.
struct ComparePane: View {
    let a: CGImage
    let b: CGImage
    let aTitle: String
    let bTitle: String
    let mode: LookDetailView.Mode
    @Binding var split: Double

    var body: some View {
        switch mode {
        case .sideBySide:
            HStack(spacing: 6) {
                titled(a, aTitle)
                titled(b, bTitle)
            }
        case .split:
            VStack(spacing: 4) {
                GeometryReader { geometry in
                    let fitted = fit(CGSize(width: a.width, height: a.height), in: geometry.size)
                    ZStack(alignment: .topLeading) {
                        image(a)
                        image(b).mask(alignment: .leading) {
                            Rectangle().frame(width: fitted.width * split)
                        }
                        Rectangle().fill(.white).frame(width: 1.5, height: fitted.height)
                            .offset(x: fitted.width * split)
                    }
                    .frame(width: fitted.width, height: fitted.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                HStack {
                    Text(bTitle).font(.caption)
                    Slider(value: $split, in: 0 ... 1)
                    Text(aTitle).font(.caption)
                }
            }
        case .flicker:
            TimelineView(.periodic(from: .now, by: 0.7)) { context in
                let showA = Int(context.date.timeIntervalSinceReferenceDate / 0.7).isMultiple(of: 2)
                titled(showA ? a : b, showA ? aTitle : bTitle)
            }
        }
    }

    private func image(_ cg: CGImage) -> some View {
        Image(nsImage: NSImage(cgImage: cg, size: .zero)).resizable().scaledToFit()
    }

    private func titled(_ cg: CGImage, _ title: String) -> some View {
        VStack(spacing: 4) {
            image(cg)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func fit(_ size: CGSize, in box: CGSize) -> CGSize {
        let scale = min(box.width / max(size.width, 1), box.height / max(size.height, 1))
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}
