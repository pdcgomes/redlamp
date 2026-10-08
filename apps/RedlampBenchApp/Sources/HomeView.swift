import RedlampBench
import SwiftUI

/// Tasks pulled from the Lab, look references made here, what's been sent, and the hub's state.
struct HomeView: View {
    @Bindable var model: BenchModel
    @State private var pairing = false
    @State private var newLook = false

    var body: some View {
        let open = model.tasks.filter { !model.status($0).isSent }
        let openLooks = model.looks.filter { !model.status($0).isSent }
        let sent = (model.tasks + model.looks).filter { model.status($0).isSent }
            .sorted { (model.sentAt[$0.id] ?? .distantPast) > (model.sentAt[$1.id] ?? .distantPast) }
        NavigationStack(path: $model.path) {
            List {
                hubSection
                if !open.isEmpty {
                    Section("To do") {
                        ForEach(open, id: \.id) { row($0) }
                            .onDelete { offsets in offsets.map { open[$0] }.forEach(model.delete) }
                    }
                }
                Section {
                    ForEach(openLooks, id: \.id) { row($0) }
                        .onDelete { offsets in offsets.map { openLooks[$0] }.forEach(model.delete) }
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
                if !sent.isEmpty {
                    Section("Sent to the Lab") {
                        ForEach(sent, id: \.id) { row($0) }
                            .onDelete { offsets in offsets.map { sent[$0] }.forEach(model.delete) }
                    }
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
            .animation(.default, value: sent.map(\.id))
        }
        .sensoryFeedback(.success, trigger: model.confirmed)
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
                    .symbolEffect(.variableColor.iterative, options: .repeating)
            case let .found(name, _):
                Button {
                    Task { await model.pairWithLab() }
                } label: {
                    Label("Pair with \(name)", systemImage: "link")
                }
            case let .asking(name):
                HStack {
                    Label("Allow this phone on \(name)", systemImage: "desktopcomputer")
                    Spacer()
                    ProgressView()
                }
            case let .connected(name):
                Label {
                    Text("Connected to \(name)")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            case let .away(name):
                Label("\(name) isn't reachable; finished work waits here", systemImage: "wifi.slash")
                    .foregroundStyle(.secondary)
            case .none:
                Label("Open the Recipe Lab on your Mac, on the same network", systemImage: "desktopcomputer")
                    .foregroundStyle(.secondary)
            }
            if let sending = model.sending, let folder = model.folder(sending.id) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Sending \(title(folder))", systemImage: "arrow.up.circle")
                    if let progress = sending.progress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else if model.waitingToSend > 0 {
                HStack {
                    Label(
                        "\(model.waitingToSend) complete, \(model.labAway ? "waiting for the Lab" : "waiting to send")",
                        systemImage: "clock.arrow.circlepath",
                    )
                    .foregroundStyle(.orange)
                    Spacer()
                    if !model.labAway {
                        Button("Send") { model.retry() }.buttonStyle(.borderless)
                    }
                }
            }
            if let message = model.message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        } footer: {
            switch model.hub {
            case .searching, .none, .found:
                Button("Pair with a code or an address…") { pairing = true }
                    .font(.footnote)
            default:
                EmptyView()
            }
        }
    }

    private func row(_ folder: BenchFolder) -> some View {
        let status = model.status(folder)
        return NavigationLink(value: folder.id) {
            HStack(spacing: 12) {
                FolderStatusIcon(status: status)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title(folder)).font(.headline)
                    Text(status.title(labAway: model.labAway))
                        .font(.subheadline)
                        .foregroundStyle(status.tint)
                    if let who = folder.manifest.requestedBy?.workstream {
                        Text("For \(who)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func title(_ folder: BenchFolder) -> String {
        folder.manifest.look?.title ?? folder.manifest.title
    }
}

/// Pairing by hand, when Bonjour can't find the Lab (another subnet, a VPN): the code the Lab's
/// Bench tab shows for a browser, and its address.
struct PairView: View {
    @Bindable var model: BenchModel
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var device = ""
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
                        Text("The Bench tab shows it too.")
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
                            if case let .found(_, url) = model.hub {
                                await model.pair(code: code, device: device, url: url)
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
            .onAppear { device = model.device }
        }
    }
}
