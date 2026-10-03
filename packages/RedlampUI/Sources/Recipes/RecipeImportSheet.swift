import RedlampRecipes
import SwiftUI

/// What an import brought in: each Lightroom preset with what was approximated and ignored,
/// folded until opened (unless it's the only one), then each file that didn't come in, with
/// the reason.
struct RecipeImportSheet: View {
    let summary: RecipeImportSummary
    let dismiss: () -> Void

    static let size = CGSize(width: 460, height: 420)

    private var presets: [(file: URL, imported: RecipeImport)] {
        summary.items.compactMap { item in
            guard case let .imported(imported) = item.outcome, imported.report != nil else { return nil }
            return (item.file, imported)
        }
    }

    var body: some View {
        let presets = presets
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.headline).font(.headline)
                if let placement = summary.placement {
                    Text(placement).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(presets.enumerated()), id: \.offset) { _, preset in
                        PresetReportRow(file: preset.file, imported: preset.imported, isExpanded: presets.count == 1)
                    }
                    if !summary.failures.isEmpty {
                        Text("Couldn't import").font(.subheadline).foregroundStyle(.secondary).padding(.top, 6)
                        ForEach(Array(summary.failures.enumerated()), id: \.offset) { _, failure in
                            Label(failure, systemImage: "exclamationmark.triangle").font(.caption)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("OK", action: dismiss).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: Self.size.width, height: Self.size.height)
    }
}

/// A preset as it came in: its name and tally, and under the disclosure what was
/// approximated, ignored and mapped, each setting with its note.
private struct PresetReportRow: View {
    let file: URL
    let imported: RecipeImport
    @State var isExpanded: Bool

    var body: some View {
        let report = imported.report.map(LightroomReportSummary.init)
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                if !imported.issues.isEmpty {
                    section("Notes", lines: imported.issues.map(\.message))
                }
                ForEach(report?.sections ?? [], id: \.title) { section in
                    self.section(section.title, lines: section.lines)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 13)
            .padding(.vertical, 4)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Text(imported.recipe.name).lineLimit(1)
                Spacer(minLength: 8)
                Text(report?.tally ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .help(file.lastPathComponent)
        }
    }

    private func section(_ title: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold))
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
