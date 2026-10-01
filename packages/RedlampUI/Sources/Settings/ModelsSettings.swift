import RedlampEngineAPI
import SwiftUI

/// Settings › Models: the models Redlamp downloads on first use, with their size and state.
struct ModelsSettings: View {
    let engine: any EditingEngine
    @State private var models: [ModelInfo] = []
    @State private var progress: [String: Double] = [:]
    @State private var failure: String?
    @AppStorage("app.redlamp.evaluationModels") private var evaluationModels = false

    var body: some View {
        Form {
            Section {
                if models.isEmpty {
                    Text("No downloadable models.").foregroundStyle(.secondary)
                }
                ForEach(models) { model in
                    row(model)
                }
            } footer: {
                Text("""
                Subject, Background, People and Sky masks use models built into macOS. Others are \
                downloaded only when you first use them. Every model runs on this Mac: photos are never uploaded.
                """)
                .formFooter()
            }
            Section {
                Toggle("Offer models awaiting licence review", isOn: $evaluationModels)
                    .onChange(of: evaluationModels) { Task { await refresh() } }
            } footer: {
                Text("""
                For evaluation: models whose training data's terms are still being reviewed, such as \
                Segment Anything for Objects masks. Masks made with them are kept in your edits either way.
                """)
                .formFooter()
            }
            if let failure {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle")
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .task { await refresh() }
    }

    private func row(_ model: ModelInfo) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                Text(model.purpose).font(.caption).foregroundStyle(.secondary)
                if !model.isCleared {
                    Text("Awaiting licence review (\(model.decision ?? "pending")).")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            if let fraction = progress[model.id] {
                ProgressView(value: fraction).frame(width: 90)
            } else {
                switch model.state {
                case .ready:
                    Button("Remove") { Task { await remove(model) } }
                case .downloading:
                    ProgressView().controlSize(.small)
                case .notDownloaded where !model.isPublished:
                    Text("Not published").foregroundStyle(.secondary)
                case .notDownloaded:
                    Button("Download \(model.formattedSize)") { Task { await download(model) } }
                }
            }
        }
    }

    private func refresh() async {
        models = await engine.models()
    }

    private func download(_ model: ModelInfo) async {
        failure = nil
        progress[model.id] = 0
        defer { progress[model.id] = nil }
        do {
            try await engine.downloadModel(model.id) { fraction in
                Task { @MainActor in progress[model.id] = fraction }
            }
        } catch {
            failure = "\(model.name) couldn't be downloaded: \(error)"
        }
        await refresh()
    }

    private func remove(_ model: ModelInfo) async {
        failure = nil
        do {
            try await engine.removeModel(model.id)
        } catch {
            failure = "\(model.name) couldn't be removed: \(error)"
        }
        await refresh()
    }
}
