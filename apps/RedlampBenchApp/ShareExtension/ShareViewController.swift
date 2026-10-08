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

    /// The next variant of the last look reference, offered when that one is already complete.
    private(set) var nextLook: BenchManifest.LookReference?
    static let newLookTag = "new-look"

    init(context: NSExtensionContext?) {
        self.context = context
        folders = library.all
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
            let paired = results.filter { $0.asset != nil }.count
            state = paired == results.count ? "Paired \(paired) of \(results.count)" : "Paired \(paired) of \(results.count); pair the rest in the app"
            if folder.isComplete, let client = BenchShared.client(library) {
                state += ". Sending to the Lab…"
                let outcome = await library.sendQueued(client)[folder.id]
                if case .success = outcome {
                    state = "Complete, and sent to the Lab"
                } else {
                    state = "Complete. The app sends it when the Lab is reachable"
                }
            }
        } catch {
            state = "\(error)"
        }
        working = false
        try? await Task.sleep(for: .seconds(1.2))
        finish()
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
                }
                if model.folders.isEmpty {
                    Section {
                        Text(
                            "Open Redlamp Bench first: tasks come from the Lab, and look references start with New Look.",
                        )
                    }
                } else {
                    Section("For") {
                        Picker("Task", selection: $model.target) {
                            if let next = model.nextLook {
                                Text("New: \(next.title)").tag(Optional(ShareModel.newLookTag))
                            }
                            ForEach(model.folders, id: \.id) { folder in
                                Text(folder.manifest.look?.title ?? folder.manifest.title).tag(Optional(folder.id))
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                }
                if !model.state.isEmpty {
                    Text(model.state).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Redlamp Bench")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.finish() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await model.save() } }
                        .disabled(model.working || model.target == nil || model.incoming.isEmpty)
                }
            }
        }
    }
}

struct ShareThumbnail: View {
    let url: URL
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: 84, height: 84)
        .clipped()
        .task { image = BenchShared.thumbnail(url, maxPixels: 240) }
    }
}
