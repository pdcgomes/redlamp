import Photos
import PhotosUI
import RedlampBench
import SwiftUI

/// A task or look reference: its steps one at a time, or an overview of its photos and results.
struct FolderView: View {
    @Bindable var model: BenchModel
    let id: String
    @State private var showing = Mode.steps
    @State private var allSteps = false

    enum Mode: String, CaseIterable {
        case steps = "Steps"
        case photos = "Photos"
    }

    var body: some View {
        if let folder = model.folder(id) {
            VStack(spacing: 0) {
                Picker("Show", selection: $showing) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)
                if showing == .photos || folder.manifest.steps.isEmpty
                    || model.step(for: folder) + 1 < folder.manifest.steps.count {
                    StatusBanner(model: model, folder: folder)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }
                switch showing {
                case .steps where !folder.manifest.steps.isEmpty:
                    StepsView(model: model, folder: folder)
                default:
                    OverviewView(model: model, folder: folder)
                }
            }
            .navigationTitle(folder.manifest.look?.title ?? folder.manifest.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("All Steps", systemImage: "list.number") { allSteps = true }
                        if !folder.isComplete {
                            Button("Send to the Lab Now", systemImage: "arrow.up.circle") { model.sendNow(folder) }
                        }
                        if case .manual = folder.manifest.completion, folder.results.completed == nil {
                            Button("Mark Done", systemImage: "checkmark.circle") { model.markDone(folder) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $allSteps) { AllStepsView(model: model, folder: folder) }
            .sensoryFeedback(.success, trigger: model.status(folder).isSent) { _, sent in sent }
            .sensoryFeedback(.increase, trigger: folder.results.results.count)
            .onAppear { model.used(folder) }
        } else {
            ContentUnavailableView("This task is gone", systemImage: "tray")
        }
    }
}

// MARK: - One step at a time

struct StepsView: View {
    @Bindable var model: BenchModel
    let folder: BenchFolder
    @State private var forward = true

    var body: some View {
        let steps = folder.manifest.steps
        let index = model.step(for: folder)
        let step = steps[index]
        let last = index + 1 == steps.count
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    ForEach(steps.indices, id: \.self) { i in
                        Capsule()
                            .fill(i <= index ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                            .frame(height: 4)
                    }
                }
                HStack {
                    Text("Step \(index + 1) of \(steps.count)")
                    Spacer()
                    if folder.isMet(step) {
                        Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(step.title)
                        .font(.largeTitle.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = step.detail {
                        Text(detail)
                            .font(.title3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let picture = step.picture, let url = folder.file(picture) {
                        FileImage(url: url, maxPixels: 1200)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    if last {
                        CompletionCard(model: model, folder: folder)
                    }
                    if let action = step.action {
                        StepActionView(model: model, folder: folder, action: action)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(step.id)
            .transition(.push(from: forward ? .trailing : .leading))
            HStack {
                Button {
                    go(to: index - 1, forward: false)
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .disabled(index == 0)
                Spacer()
                if !last {
                    Button {
                        go(to: index + 1, forward: true)
                    } label: {
                        HStack(spacing: 4) {
                            Text("Next")
                            Image(systemName: "chevron.right")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                } else if model.status(folder).isSent {
                    Button("Done") { model.path.removeAll { $0 == folder.id } }
                        .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.large)
        }
        .padding()
        .clipped()
        .sensoryFeedback(.selection, trigger: index)
    }

    private func go(to index: Int, forward: Bool) {
        self.forward = forward
        withAnimation(.snappy) {
            model.setStep(index, for: folder)
        }
    }
}

/// A line at the top of a folder's screen: how far it is, and whether it's waiting, going or
/// gone to the Lab.
struct StatusBanner: View {
    @Bindable var model: BenchModel
    let folder: BenchFolder

    var body: some View {
        let status = model.status(folder)
        HStack(spacing: 10) {
            FolderStatusIcon(status: status, size: 24)
            Text(status.title(labAway: model.labAway))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(status.tint)
            Spacer()
            if case .waiting = status, !model.labAway {
                Button("Send") { model.retry() }.buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(status.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .animation(.default, value: status)
    }
}

/// The last step's summary: what's still to come back, or that the folder is on its way to the
/// Lab or there, and what's left to do.
struct CompletionCard: View {
    @Bindable var model: BenchModel
    let folder: BenchFolder

    var body: some View {
        let status = model.status(folder)
        HStack(alignment: .top, spacing: 14) {
            FolderStatusIcon(status: status, size: 44)
            VStack(alignment: .leading, spacing: 6) {
                Text(headline(status)).font(.headline)
                Text(detail(status)).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                switch status {
                case let .sending(progress):
                    if let progress {
                        ProgressView(value: progress)
                    }
                case .waiting where !model.labAway:
                    Button("Send Now") { model.retry() }.buttonStyle(.bordered)
                case let .toDo(back, _) where back > 0:
                    Button("Send What's Back Now") { model.sendNow(folder) }.buttonStyle(.bordered)
                default:
                    EmptyView()
                }
            }
            Spacer(minLength: 0)
        }
        .padding()
        .background(status.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .animation(.default, value: status)
    }

    private func headline(_ status: FolderStatus) -> String {
        switch status {
        case let .toDo(back, of): of == 0 ? "Not done yet" : "\(back) of \(of) back"
        case .waiting: "Complete"
        case .sending: "Sending to the Lab…"
        case .sent: "Sent to the Lab"
        case .sentEarly: "Sent early"
        }
    }

    private func detail(_ status: FolderStatus) -> String {
        let app = folder.manifest.app ?? folder.manifest.look?.app ?? "the other app"
        switch status {
        case let .toDo(back, of):
            if of == 0 {
                return "Mark it done from the ⋯ menu when you've finished."
            }
            let left = of - back
            return "Share \(left == 1 ? "the last export" : "the other \(left) exports") from \(app) to Redlamp Bench. Each one finds its photo by itself, and the task goes to the Lab as soon as the last is in."
        case let .waiting(problem):
            if let problem {
                return "The last try failed (\(problem)). It tries again when the Lab is reachable."
            }
            return model.labAway
                ? "It goes to the Lab as soon as the Lab is reachable: open the Recipe Lab on your Mac."
                : "It's next to go."
        case .sending:
            return "Keep the app open until it's done; it carries on for a while in the background."
        case let .sent(date):
            let when = date.map { " \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
            return "The Lab has it\(when.isEmpty ? "" : ", since\(when)"). Nothing else to do here."
        case let .sentEarly(back, of):
            return "\(back) of \(of) back went to the Lab. The rest goes when the task is complete."
        }
    }
}

/// What a step's screen offers.
struct StepActionView: View {
    @Bindable var model: BenchModel
    let folder: BenchFolder
    let action: BenchManifest.Action
    @State private var saved: String?

    var body: some View {
        let assets = action.assets.map { ids in folder.manifest.assets.filter { ids.contains($0.id) } } ?? folder
            .manifest.assets
        switch action {
        case .share:
            VStack(alignment: .leading, spacing: 10) {
                AssetStrip(folder: folder, assets: assets)
                ShareLink(items: urls(assets)) {
                    Label(shareTitle(assets.count), systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                saveButton(assets)
            }
        case .save:
            VStack(alignment: .leading, spacing: 10) {
                AssetStrip(folder: folder, assets: assets)
                saveButton(assets)
                    .buttonStyle(.borderedProminent)
            }
        case let .answer(id):
            if let question = folder.manifest.questions.first(where: { $0.id == id }) {
                QuestionView(model: model, folder: folder, question: question)
            }
        case .results:
            ResultsProgressView(folder: folder, assets: assets)
        }
    }

    private func urls(_ assets: [BenchManifest.Asset]) -> [URL] {
        assets.compactMap { folder.file($0.file) }
    }

    private func shareTitle(_ count: Int) -> String {
        let what = count == 1 ? "the photo" : "the \(count) photos"
        return "Share \(what)\(folder.manifest.app.map { " to \($0)" } ?? "")"
    }

    private func saveButton(_ assets: [BenchManifest.Asset]) -> some View {
        Button {
            Task { saved = await PhotoSaver.save(urls(assets)) }
        } label: {
            Label(saved ?? "Save to Photos", systemImage: saved == nil ? "photo.badge.plus" : "checkmark")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }
}

struct QuestionView: View {
    @Bindable var model: BenchModel
    let folder: BenchFolder
    let question: BenchManifest.Question

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(question.text).font(.headline)
            ForEach(question.choices, id: \.self) { choice in
                Button {
                    model.answer(folder, question: question.id, with: choice)
                } label: {
                    HStack {
                        Text(choice)
                        Spacer()
                        if folder.results.answers[question.id] == choice {
                            Image(systemName: "checkmark")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

/// Which results are back, with each reference and its result side by side.
struct ResultsProgressView: View {
    let folder: BenchFolder
    let assets: [BenchManifest.Asset]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(assets) { asset in
                let result = folder.results.current(for: asset.id)
                HStack(spacing: 8) {
                    if let url = folder.file(asset.file) {
                        FileImage(url: url).frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    Group {
                        if let result, let url = folder.file(result.file) {
                            FileImage(url: url)
                        } else {
                            RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary, style: StrokeStyle(dash: [4]))
                        }
                    }
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(asset.label ?? asset.id).font(.subheadline).lineLimit(2)
                        Text(result == nil ? "Waiting" : "Back")
                            .font(.caption).foregroundStyle(result == nil ? .secondary : Color.green)
                    }
                    Spacer()
                    Image(systemName: result == nil ? "circle.dashed" : "checkmark.circle.fill")
                        .foregroundStyle(result == nil ? .secondary : Color.green)
                        .font(.title3)
                }
                .transition(.opacity)
            }
        }
        .animation(.default, value: folder.results.results.count)
    }
}

struct AllStepsView: View {
    @Bindable var model: BenchModel
    let folder: BenchFolder
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(Array(folder.manifest.steps.enumerated()), id: \.element.id) { index, step in
                Button {
                    model.setStep(index, for: folder)
                    dismiss()
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(step.title).foregroundStyle(.primary)
                            if let detail = step.detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer()
                        if folder.isMet(step) || index < model.step(for: folder) {
                            Image(systemName: "checkmark").foregroundStyle(.green)
                        }
                    }
                }
            }
            .navigationTitle("Steps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

// MARK: - Overview

struct OverviewView: View {
    @Bindable var model: BenchModel
    let folder: BenchFolder
    @State private var selection = Set<String>()
    @State private var selecting = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var note = ""

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 6)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(folder.manifest.assets) { asset in
                        AssetCell(
                            folder: folder,
                            asset: asset,
                            selecting: selecting,
                            selected: selection.contains(asset.id),
                        )
                        .onTapGesture {
                            if selecting {
                                selection.formSymmetricDifference([asset.id])
                            }
                        }
                        .contextMenu { pairMenu(for: asset) }
                    }
                }
                if !folder.results.unpaired.isEmpty {
                    unpaired
                }
                ForEach(folder.manifest.questions) { question in
                    QuestionView(model: model, folder: folder, question: question)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Note for the agent").font(.headline)
                    TextField("Anything worth knowing", text: $note, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.note(folder, note) }
                }
                PhotosPicker(selection: $picked, matching: .images, photoLibrary: .shared()) {
                    Label("Add Results from Photos", systemImage: "photo.on.rectangle")
                }
            }
            .padding()
        }
        .safeAreaInset(edge: .bottom) {
            if selecting {
                HStack {
                    ShareLink(items: selectedURLs) {
                        Label("Share \(selection.count)", systemImage: "square.and.arrow.up")
                    }
                    .disabled(selection.isEmpty)
                    Spacer()
                    Button("Save to Photos", systemImage: "photo.badge.plus") {
                        Task { _ = await PhotoSaver.save(selectedURLs) }
                    }
                    .disabled(selection.isEmpty)
                }
                .padding()
                .background(.bar)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(selecting ? "Done" : "Select") {
                    selecting.toggle()
                    selection = []
                }
            }
        }
        .onAppear { note = folder.results.note ?? "" }
        .onDisappear {
            if note != (folder.results.note ?? "") {
                model.note(folder, note)
            }
        }
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            Task {
                let files = await PhotoSaver.load(items)
                model.add(files, to: folder)
                picked = []
            }
        }
    }

    private var selectedURLs: [URL] {
        folder.manifest.assets.filter { selection.contains($0.id) }.compactMap { folder.file($0.file) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let look = folder.manifest.look {
                Text(look.title).font(.title2.bold())
                Text(look.settings.map { "Settings: \($0)" } ?? "Default settings").foregroundStyle(.secondary)
                if let screenshot = look.settingsScreenshot, let url = folder.file(screenshot) {
                    FileImage(url: url, maxPixels: 900).frame(maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            } else {
                Text(folder.manifest.title).font(.title2.bold())
                if let who = folder.manifest.requestedBy {
                    Text(["For", who.workstream, who.tracker].compactMap(\.self).joined(separator: " "))
                        .foregroundStyle(.secondary)
                }
                if let note = folder.manifest.note {
                    Text(note)
                }
            }
            Text(folder.summary).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var unpaired: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Not paired yet").font(.headline)
            Text("Hold a photo above and choose its result, or hold a result to pair it.").font(.caption)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack {
                    ForEach(folder.results.unpaired) { result in
                        if let url = folder.file(result.file) {
                            FileImage(url: url).frame(width: 96, height: 96).clipped()
                                .contextMenu {
                                    ForEach(folder.manifest.assets) { asset in
                                        Button("Result for \(asset.label ?? asset.id)") {
                                            model.pair(result, with: asset.id, in: folder)
                                        }
                                    }
                                    Button("Remove", role: .destructive) { model.remove(result, from: folder) }
                                }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func pairMenu(for asset: BenchManifest.Asset) -> some View {
        if let current = folder.results.current(for: asset.id) {
            Button("Unpair Its Result", systemImage: "link.badge.plus") { model.pair(current, with: nil, in: folder) }
            Button("Remove Its Result", systemImage: "trash", role: .destructive) { model.remove(current, from: folder)
            }
        }
        ForEach(folder.results.unpaired) { result in
            Button("Pair with \(result.originalName)") { model.pair(result, with: asset.id, in: folder) }
        }
    }
}

struct AssetCell: View {
    let folder: BenchFolder
    let asset: BenchManifest.Asset
    let selecting: Bool
    let selected: Bool

    var body: some View {
        let result = folder.results.current(for: asset.id)
        ZStack(alignment: .bottomTrailing) {
            if let url = folder.file(result?.file ?? asset.file) {
                FileImage(url: url)
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fill)
                    .clipped()
            }
            if result != nil {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.multicolor)
                    .padding(4)
            }
            if selecting {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(.white, .tint)
                    .padding(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .overlay(alignment: .bottomLeading) {
            Text(asset.label ?? asset.id)
                .font(.caption2)
                .lineLimit(1)
                .padding(3)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 3))
                .padding(3)
        }
    }
}

/// A row of a step's photos.
struct AssetStrip: View {
    let folder: BenchFolder
    let assets: [BenchManifest.Asset]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(assets) { asset in
                    if let url = folder.file(asset.file) {
                        FileImage(url: url).frame(width: 84, height: 84).clipped()
                    }
                }
            }
        }
    }
}

/// An image file, downsampled once and cached.
struct FileImage: View {
    let url: URL
    var maxPixels = 480
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .task(id: url) {
            image = await ThumbnailCache.shared.image(url, maxPixels: maxPixels)
        }
    }
}

actor ThumbnailCache {
    static let shared = ThumbnailCache()
    private var images: [String: CGImage] = [:]

    func image(_ url: URL, maxPixels: Int) -> CGImage? {
        let key = "\(url.path)#\(maxPixels)"
        if let image = images[key] {
            return image
        }
        let image = BenchShared.thumbnail(url, maxPixels: maxPixels)
        if images.count > 200 {
            images.removeAll()
        }
        images[key] = image
        return image
    }
}

/// Saving to Photos, and reading picked photos back as files.
enum PhotoSaver {
    /// Returns what to say on the button afterwards.
    static func save(_ urls: [URL]) async -> String {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return "Photos access is off in Settings" }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for url in urls {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: nil)
                }
            }
            return urls.count == 1 ? "Saved to Photos" : "Saved \(urls.count) to Photos"
        } catch {
            return "Couldn't save: \(error.localizedDescription)"
        }
    }

    /// The picked photos as files, with their original names where Photos gives them.
    static func load(_ items: [PhotosPickerItem]) async -> [(url: URL, name: String)] {
        var files: [(URL, String)] = []
        for item in items {
            guard let file = try? await item.loadTransferable(type: PickedFile.self) else { continue }
            files.append((file.url, file.name))
        }
        return files
    }
}

/// A picked photo's original file, copied out of the picker's temporary location.
struct PickedFile: Transferable {
    let url: URL
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let copy = FileManager.default.temporaryDirectory
                .appending(path: "picked-\(UUID().uuidString)-\(received.file.lastPathComponent)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedFile(url: copy, name: received.file.lastPathComponent)
        }
    }
}
