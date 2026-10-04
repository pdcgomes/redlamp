import SwiftUI

/// Where a report belongs: the areas on the left, their features on the right, and a search
/// across both that knows the words people use ("object selector" finds Masking › Objects).
struct AreaPicker: View {
    @Binding var featureID: String?
    let suggestion: FeedbackTopic?
    let done: () -> Void
    @State private var query = ""
    @State private var areaID: String?

    init(featureID: Binding<String?>, suggestion: FeedbackTopic?, done: @escaping () -> Void) {
        _featureID = featureID
        self.suggestion = suggestion
        self.done = done
        let current = featureID.wrappedValue.flatMap(FeedbackArea.topic) ?? suggestion
        _areaID = State(initialValue: current?.area.id ?? FeedbackArea.catalog.first?.id)
    }

    private var area: FeedbackArea? {
        areaID.flatMap(FeedbackArea.area)
    }

    private var searching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search, for example “object selector” or “export”", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            if let suggestion, !searching {
                Button {
                    choose(suggestion.feature.id)
                } label: {
                    Label("Suggested from what you were doing: \(suggestion.path)", systemImage: "sparkle")
                }
                .buttonStyle(.link)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            Divider()
            if searching {
                results
            } else {
                browser
            }
        }
        .frame(width: 580, height: 440)
    }

    private var browser: some View {
        HStack(spacing: 0) {
            List(FeedbackArea.catalog, selection: $areaID) { area in
                Label(area.title, systemImage: area.symbol).tag(area.id)
            }
            .frame(width: 220)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                if let area {
                    Text(area.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                    List(area.features) { feature in
                        row(feature.title, detail: nil, id: feature.id)
                    }
                }
            }
        }
    }

    private var results: some View {
        let found = FeedbackArea.search(query, limit: 30)
        return Group {
            if found.isEmpty {
                VStack(spacing: 6) {
                    Text("Nothing matches “\(query)”.")
                    Text("Try another word, or choose Something Else › Not Sure.").font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(found) { topic in
                    row(topic.feature.title, detail: topic.area.title, id: topic.id)
                }
            }
        }
    }

    private func row(_ title: String, detail: String?, id: String) -> some View {
        Button {
            choose(id)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    if let detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if id == featureID {
                    Image(systemName: "checkmark").foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func choose(_ id: String) {
        featureID = id
        done()
    }
}
