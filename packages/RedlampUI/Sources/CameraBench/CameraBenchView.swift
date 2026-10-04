import RedlampEngineAPI
import RedlampRecipes
import SwiftUI

/// The Camera Bench window (CAM-15): choose photos, see how Redlamp opens them beside the camera's
/// own JPEG, answer one question per camera mode, and send the measurements.
struct CameraBenchView: View {
    @Bindable var model: CameraBenchModel
    let choose: () -> Void
    @Environment(\.openURL) private var openURL
    @State private var showsReport = false

    var body: some View {
        Group {
            switch model.phase {
            case .start: start
            case let .reading(done, total): working("Reading \(done) of \(total) files…", done, total)
            case let .testing(done, total): working("Testing \(done) of \(total) photos…", done, total)
            case .results: results
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .sheet(isPresented: $showsReport) { report }
    }

    // MARK: - Start

    private var start: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Test Your Camera").font(.title.weight(.semibold))
            Text(
                "The bench checks how Redlamp opens your camera's raw files, and compares Redlamp's rendering of each with the JPEG your camera saved inside it. It picks up to eight photos for each camera and raw mode it finds.",
            )
            .fixedSize(horizontal: false, vertical: true)
            Text(
                "Your photos stay on this Mac. Only measurements are sent, and only when you choose to, after you've seen exactly what they are.",
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Choose Photos or a Folder…", action: choose)
                    .keyboardShortcut(.defaultAction)
                if let folder = model.currentFolder() {
                    Button("Use \(folder.lastPathComponent)") { model.test([folder]) }
                }
            }
            if case let .failed(message) = model.sending {
                Text(message).foregroundStyle(.red)
            }
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: 620, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func working(_ title: String, _ done: Int, _ total: Int) -> some View {
        VStack(spacing: 14) {
            Text(title)
            ProgressView(value: Double(done), total: Double(max(total, 1)))
                .frame(width: 320)
            Button("Cancel") { model.cancel() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Results

    private var results: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                List(model.modes, selection: $model.selectedMode) { mode in
                    HStack(spacing: 8) {
                        VerdictIcon(verdict: mode.verdict)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.mode.camera)
                            Text(mode.mode.label).font(.caption).foregroundStyle(.secondary)
                            Text("\(mode.photos.count) of \(mode.candidates) tested").font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .tag(mode.id)
                }
                .frame(width: 280)
                Divider()
                if let mode = model.selected {
                    ScrollView { detail(mode).padding(20) }
                } else {
                    Text("No raw files found.").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            footer
        }
    }

    private func detail(_ mode: CameraBenchModel.Mode) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(mode.mode.camera).font(.title2.weight(.semibold))
                Text(mode.mode.label).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(mode.checks, id: \.id) { check in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VerdictIcon(verdict: check.verdict)
                        Text(Self.title(check.id)).frame(width: 150, alignment: .leading)
                        Text(check.summary + (check.tracker.map { " (\($0))" } ?? "")).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            pairs(mode)
            question(mode)
            needs(mode)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pairs(_ mode: CameraBenchModel.Mode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Redlamp's rendering, left, and your camera's JPEG").font(.headline)
            ScrollView(.horizontal) {
                HStack(spacing: 16) {
                    ForEach(mode.photos) { photo in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                pairImage(photo.ours, missing: "Not rendered")
                                pairImage(photo.theirs, missing: "No JPEG in the file")
                            }
                            HStack(spacing: 6) {
                                VerdictIcon(verdict: photo.result.verdict)
                                Text(photo.id.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func pairImage(_ image: CGImage?, missing: String) -> some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
            } else {
                Text(missing).font(.caption).foregroundStyle(.secondary).frame(width: 140)
            }
        }
        .frame(height: 140)
    }

    private func question(_ mode: CameraBenchModel.Mode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Apart from your camera's picture style, do these look like the same photos?").font(.headline)
            Picker("", selection: Binding(
                get: { model.answers[mode.id] },
                set: { model.answers[mode.id] = $0 },
            )) {
                Text("Choose an answer").tag(CameraBenchAnswer.Choice?.none)
                ForEach(CameraBenchAnswer.Choice.allCases, id: \.self) { choice in
                    Text(choice.title).tag(CameraBenchAnswer.Choice?.some(choice))
                }
            }
            .labelsHidden()
            .fixedSize()
            TextField("Anything to add (optional)", text: Binding(
                get: { model.notes[mode.id] ?? "" },
                set: { model.notes[mode.id] = $0 },
            ), axis: .vertical)
                .lineLimit(2 ... 4)
                .frame(maxWidth: 480)
            if let report = model.problemReport(mode), let onReportProblem = model.onReportProblem {
                Button("Report This Problem…") { onReportProblem(report) }
            } else if let url = model.problemURL(mode) {
                Button("Report This Problem…") { openURL(url) }
            }
        }
    }

    @ViewBuilder
    private func needs(_ mode: CameraBenchModel.Mode) -> some View {
        let needed = model.stillNeeded(mode)
        VStack(alignment: .leading, spacing: 6) {
            if !needed.isEmpty {
                Text("This camera still needs").font(.headline)
                ForEach(needed, id: \.self) { Text("• \($0.title)").foregroundStyle(.secondary) }
            }
            if !model.isVerified(mode) {
                Text(
                    "Redlamp's tests have no sample of this camera yet. If you're willing to give one photo to the public domain, raw.pixls.us collects them, and it can join the tests.",
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Link("Give a sample on raw.pixls.us", destination: URL(string: "https://raw.pixls.us")!)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            TextField("Name to credit (optional)", text: $model.credit).frame(width: 220)
            Button("Test Other Photos…", action: choose)
            Spacer()
            switch model.sending {
            case .idle: EmptyView()
            case .sending: ProgressView().controlSize(.small)
            case let .sent(
                id,
                dryRun,
            ): Text(dryRun ? "Checked by redlamp.app (a dry run; nothing kept)." :
                    "Sent. Thank you (\(id.prefix(8))).")
                    .foregroundStyle(.secondary)
            case let .failed(message): Text(message).foregroundStyle(.red).lineLimit(2)
            }
            Button("What's Sent…") { showsReport = true }
            Button("Send Results") { model.send() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSend)
        }
        .padding(12)
    }

    private var report: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What's sent").font(.headline)
            Text(
                "Measurements only: no pixels, file names, paths, GPS, serial numbers, owner fields or capture times. The contributor ID is random, kept on this Mac, and only counts contributors.",
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(model.reportJSON).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Reset Contributor ID") { model.resetContributor() }
                Spacer()
                Button("Done") { showsReport = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 560)
    }

    static func title(_ id: String) -> String {
        switch id {
        case "decode.opens": "Opens"
        case "decode.black": "Black level"
        case "decode.white": "White level"
        case "decode.colour": "Colour matrix"
        case "decode.edges": "Edges"
        case "render.default": "Default rendering"
        case "preview.orientation": "Orientation"
        case "preview.framing": "Framing"
        case "preview.structure": "Detail"
        case "preview.exposure": "Exposure"
        case "preview.cast": "Neutrals"
        case "preview.highlights": "Highlights"
        case "preview.colour": "Colours"
        default: id
        }
    }
}

private struct VerdictIcon: View {
    let verdict: BenchVerdict

    var body: some View {
        switch verdict {
        case .pass: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Passed")
        case .warn: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            .accessibilityLabel("Warning")
        case .fail: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).accessibilityLabel("Failed")
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary).accessibilityLabel("Skipped")
        }
    }
}
