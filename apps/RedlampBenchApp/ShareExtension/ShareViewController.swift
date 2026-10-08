import RedlampBench
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The share extension: files what another app exports into a task or look reference, the last
/// one used unless the owner picks another, pairs each file with its reference, and sends the
/// folder to the Lab when that completes it.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareModel(context: extensionContext)
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { await model.load() }
    }
}

@MainActor
@Observable
final class ShareModel {
    struct Incoming: Identifiable {
        let id = UUID()
        let url: URL
        let name: String
    }

    let library = BenchShared.library
    private weak var context: NSExtensionContext?
    private(set) var incoming: [Incoming] = []
    private(set) var folders: [BenchFolder] = []
    var target: String?
    private(set) var state = "Reading…"
    private(set) var working = true
    private(set) var filed: [BenchResult] = []
    /// The folder the files went into, once saved.
    private(set) var saved: BenchFolder?
    private(set) var status: FolderStatus?

    /// The next variant of the last look reference, offered when that one is already complete.
    private(set) var nextLook: BenchManifest.LookReference?
    static let newLookTag = "new-look"

    init(context: NSExtensionContext?) {
        self.context = context
        let library = library
        folders = library.all.filter { $0.id == library.suggested?.id || !FolderStatus($0, in: library).isSent }
        let suggested = library.suggested
        if let suggested, var look = suggested.manifest.look, suggested.isComplete {
            look.variant = look.variant.flatMap { Int($0) }.map { "\($0 + 1)" } ?? look.variant
            look.settingsScreenshot = nil
            nextLook = look
            target = Self.newLookTag
        } else {
            target = suggested?.id
        }
    }

    var targetFolder: BenchFolder? {
        target.flatMap { id in folders.first { $0.id == id } }
    }

    func load() async {
        let providers = (context?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        for provider in providers {
            if let file = await Self.file(from: provider) {
                incoming.append(file)
            }
        }
        working = false
        state = incoming.isEmpty ? "Nothing here is an image." : ""
    }

    /// The original file, not a re-encoded image: the measurement needs the app's own bytes.
    private static func file(from provider: NSItemProvider) async -> Incoming? {
        let type = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .image) == true }
            ?? provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .data) == true }
        guard let type else { return nil }
        let suggestedName = provider.suggestedName
        return await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url else { return continuation.resume(returning: nil) }
                let copy = FileManager.default.temporaryDirectory
                    .appending(path: "share-\(UUID().uuidString)-\(url.lastPathComponent)")
                do {
                    try FileManager.default.copyItem(at: url, to: copy)
                    let name = suggestedName.map { name in
                        (name as NSString).pathExtension.isEmpty ? "\(name).\(url.pathExtension)" : name
                    } ?? url.lastPathComponent
                    continuation.resume(returning: Incoming(url: copy, name: name))
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    func save() async {
        guard var target else { return }
        working = true
        state = "Pairing…"
        do {
            if target == Self.newLookTag, let nextLook {
                target = try library.newLook(nextLook).id
            }
            let (folder, results) = try BenchShared.file(
                incoming.map { ($0.url, $0.name) },
                into: target,
                library: library,
            )
            filed = results
            saved = folder
            status = FolderStatus(folder, in: library)
            state = ""
            if folder.isComplete, let client = BenchShared.client(library) {
                status = .sending(nil)
                await library.sendQueued(client) { event in
                    if case let .progress(id, done) = event, id == folder.id {
                        Task { @MainActor [weak self] in self?.status = .sending(done) }
                    }
                }
                status = FolderStatus(folder, in: library)
            }
        } catch {
            state = "\(error)"
        }
        working = false
        if let status, status.isSent, filed.allSatisfy({ $0.asset != nil }) {
            try? await Task.sleep(for: .seconds(2))
            finish()
        }
    }

    func label(of result: BenchResult) -> String? {
        guard let asset = result.asset else { return nil }
        let manifest = saved?.manifest
        return manifest?.assets.first { $0.id == asset }.map { $0.label ?? $0.id } ?? asset
    }

    func finish() {
        for file in incoming {
            try? FileManager.default.removeItem(at: file.url)
        }
        context?.completeRequest(returningItems: nil)
    }
}

struct ShareView: View {
    @Bindable var model: ShareModel

    var body: some View {
        NavigationStack {
            Form {
                if let folder = model.saved {
                    filed(into: folder)
                } else {
                    choose
                }
                if !model.state.isEmpty {
                    Text(model.state).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Redlamp Bench")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.saved == nil {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.finish() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { Task { await model.save() } }
                            .disabled(model.working || model.target == nil || model.incoming.isEmpty)
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { model.finish() }.disabled(model.working)
                    }
                }
            }
            .sensoryFeedback(.success, trigger: model.status?.isSent == true) { _, sent in sent }
        }
    }

    @ViewBuilder
    private var choose: some View {
        Section {
            ScrollView(.horizontal) {
                HStack {
                    ForEach(model.incoming) { file in
                        VStack {
                            ShareThumbnail(url: file.url)
                            Text(file.name).font(.caption2).lineLimit(1).frame(width: 84)
                        }
                    }
                }
            }
        } footer: {
            Text("\(model.incoming.count) image\(model.incoming.count == 1 ? "" : "s")")
        }
        if model.folders.isEmpty {
            Section {
                Text("Open Redlamp Bench first: tasks come from the Lab, and look references start with New Look.")
            }
        } else {
            Section("Add to") {
                Picker("Task", selection: $model.target) {
                    if let next = model.nextLook {
                        Label("New: \(next.title)", systemImage: "plus.circle").tag(Optional(ShareModel.newLookTag))
                    }
                    ForEach(model.folders, id: \.id) { folder in
                        let status = FolderStatus(folder, in: model.library)
                        VStack(alignment: .leading) {
                            Text(folder.manifest.look?.title ?? folder.manifest.title)
                            Text(status.title(labAway: false)).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(Optional(folder.id))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
    }

    @ViewBuilder
    private func filed(into folder: BenchFolder) -> some View {
        if let status = model.status {
            Section {
                HStack(spacing: 12) {
                    FolderStatusIcon(status: status, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(folder.manifest.look?.title ?? folder.manifest.title).font(.headline)
                        Text(status.title(labAway: model.library.settings.token == nil))
                            .font(.subheadline).foregroundStyle(status.tint)
                    }
                }
                if case let .sending(progress) = status, let progress {
                    ProgressView(value: progress)
                }
            }
        }
        Section("Paired") {
            ForEach(Array(zip(model.incoming, model.filed)), id: \.0.id) { file, result in
                HStack(spacing: 10) {
                    ShareThumbnail(url: file.url, side: 44)
                    VStack(alignment: .leading) {
                        Text(file.name).font(.subheadline).lineLimit(1)
                        if let label = model.label(of: result) {
                            Text("→ \(label)").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Not paired: pair it in the app").font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Image(systemName: result.asset == nil ? "questionmark.circle" : "checkmark.circle.fill")
                        .foregroundStyle(result.asset == nil ? Color.orange : Color.green)
                }
            }
        }
    }
}

struct ShareThumbnail: View {
    let url: URL
    var side: CGFloat = 84
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task { image = BenchShared.thumbnail(url, maxPixels: 240) }
    }
}
