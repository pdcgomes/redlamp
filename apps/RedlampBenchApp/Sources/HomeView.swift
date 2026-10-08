import RedlampBench
import SwiftUI

/// Tasks pulled from the Lab, look references made here, and the hub's state.
struct HomeView: View {
    @Bindable var model: BenchModel
    @State private var pairing = false
    @State private var newLook = false

    var body: some View {
        NavigationStack(path: $model.path) {
            List {
                hubSection
                if !model.tasks.isEmpty {
                    Section("Tasks") {
                        ForEach(model.tasks, id: \.id) { row($0) }
                            .onDelete { offsets in offsets.map { model.tasks[$0] }.forEach(model.delete) }
                    }
                }
                Section {
                    ForEach(model.looks, id: \.id) { row($0) }
                        .onDelete { offsets in offsets.map { model.looks[$0] }.forEach(model.delete) }
                    Button {
                        newLook = true
                    } label: {
                        Label("New Look", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Look references")
                } footer: {
                    Text(
                        "A filter from another app, run over the capture kit, so the Lab can rebuild it as a Redlamp look.",
                    )
                }
                if model.tasks.isEmpty, model.looks.isEmpty {
                    Section {
                        Text("Tasks from the Lab appear here by themselves while the Lab is open on your Mac.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Redlamp Bench")
            .navigationDestination(for: String.self) { id in
                FolderView(model: model, id: id)
            }
            .refreshable { await model.refresh() }
            .sheet(isPresented: $pairing) { PairView(model: model) }
            .sheet(isPresented: $newLook) {
                NewLookView(model: model) { folder in
                    newLook = false
                    model.path.append(folder.id)
                }
            }
        }
        .onChange(of: model.opened) { _, id in
            if let id {
                model.path = [id]
                model.opened = nil
            }
        }
    }

    private var hubSection: some View {
        Section {
            switch model.hub {
            case .searching:
                Label("Looking for the Lab…", systemImage: "antenna.radiowaves.left.and.right")
            case let .found(name, _):
                Button {
                    pairing = true
                } label: {
                    Label("Pair with \(name)", systemImage: "link")
                }
            case let .connected(name):
                Label(name, systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            case let .away(name):
                Label("\(name) isn't reachable; finished work waits here", systemImage: "wifi.slash")
                    .foregroundStyle(.secondary)
            case .none:
                Button {
                    pairing = true
                } label: {
                    Label("Pair with the Lab", systemImage: "link")
                }
            }
            if !model.queued.isEmpty {
                Label("\(model.queued.count) waiting to send", systemImage: "arrow.up.circle")
                    .foregroundStyle(.secondary)
            }
            if let message = model.message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ folder: BenchFolder) -> some View {
        NavigationLink(value: folder.id) {
            VStack(alignment: .leading, spacing: 3) {
                Text(folder.manifest.look?.title ?? folder.manifest.title)
                    .font(.headline)
                Text(status(folder))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func status(_ folder: BenchFolder) -> String {
        if model.isSent(folder) {
            return folder.isComplete ? "Sent to the Lab" : "Sent early; more results go when it's complete"
        }
        if model.queued.contains(folder.id) {
            return "Complete, waiting to send"
        }
        let required = folder.manifest.requiredAssets.count
        let back = required - folder.missing.count
        let who = folder.manifest.requestedBy?.workstream.map { " · for \($0)" } ?? ""
        return required == 0 ? "\(folder.results.results.count) results\(who)" : "\(back) of \(required) back\(who)"
    }
}

/// Pairing with the hub: the code the Lab's Bench tab shows, and this phone's name.
struct PairView: View {
    @Bindable var model: BenchModel
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var device = UIDevice.current.name
    @State private var address = ""
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Pairing code", text: $code)
                        .keyboardType(.numberPad)
                        .font(.title2.monospacedDigit())
                    TextField("This phone's name", text: $device)
                } footer: {
                    Text("The code is in the harness's Recipe Lab, Bench tab.")
                }
                if case .found = model.hub {} else {
                    Section {
                        TextField("Address, such as 192.168.1.20:8765", text: $address)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } footer: {
                        Text("Only if the Lab isn't found by itself.")
                    }
                }
                if let message = model.message {
                    Text(message).foregroundStyle(.red)
                }
            }
            .navigationTitle("Pair with the Lab")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Pair") {
                        working = true
                        Task {
                            if case let .found(name, url) = model.hub {
                                await model.pair(code: code, device: device, url: url, name: name)
                            } else {
                                await model.pair(code: code, device: device, address: address)
                            }
                            working = false
                            if case .connected = model.hub {
                                dismiss()
                            }
                        }
                    }
                    .disabled(code.count != 6 || working)
                }
            }
        }
    }
}
