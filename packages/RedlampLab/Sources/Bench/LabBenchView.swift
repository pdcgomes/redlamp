import AppKit
import RedlampBench
import SwiftUI
import UniformTypeIdentifiers

/// The Lab's Bench tab: the hub's address and pairing code, the phones paired with it, what
/// waits in the outbox and what came back.
struct LabBenchView: View {
    @Bindable var bench: LabBench
    @State private var dropping = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hub
                if !bench.requests.isEmpty {
                    requests
                }
                if bench.isEnabled {
                    pairing
                }
                folders("Waiting for the phone", bench.outbox, area: .outbox, empty: "Nothing in the outbox.")
                folders("Back in the Lab", bench.done, area: .done, empty: "Nothing has come back yet.")
                if !bench.events.isEmpty {
                    events
                }
            }
            .padding(16)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in bench.receive(url) }
                }
            }
            return true
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 8).strokeBorder(.tint, lineWidth: 2).padding(6)
            }
        }
        .onAppear { bench.refresh() }
    }

    private var hub: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Receive from Redlamp Bench on the local network", isOn: Binding(
                get: { bench.isEnabled },
                set: { bench.setEnabled($0) },
            ))
            .toggleStyle(.switch)
            Text(stateText).font(.callout).foregroundStyle(stateIsProblem ? .red : .secondary)
            Text("Tasks in \(bench.store.root.path)")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Drop a .redtask or a bench folder here to file it by hand.")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    private var stateText: String {
        switch bench.state {
        case .stopped: bench.isEnabled ? "Starting…" : "Off. The phone can't reach the Lab while it's off."
        case .starting: "Starting…"
        case .ready: "Listening as \(LabBench.hubName), \(bench.address ?? "")"
        case let .failed(reason): "Couldn't listen: \(reason)"
        }
    }

    private var stateIsProblem: Bool {
        if case .failed = bench.state {
            return true
        }
        return false
    }

    private var requests: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(bench.requests) { request in
                HStack {
                    Image(systemName: "iphone.radiowaves.left.and.right").foregroundStyle(.tint)
                    Text("\(request.device) asks to pair with the Lab").fontWeight(.medium)
                    Spacer()
                    Button("Don't Allow") { bench.deny(request) }
                    Button("Allow") { bench.allow(request) }.buttonStyle(.borderedProminent)
                }
                .padding(10)
                .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var pairing: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Nearby").font(.caption).foregroundStyle(.secondary)
                if bench.nearby.isEmpty {
                    Text("No phone with Redlamp Bench open.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(bench.nearby) { phone in
                    HStack {
                        Image(systemName: "iphone")
                        Text(phone.name)
                        Text(bench.isPaired(phone) ? "paired" : "not paired: tap Pair on the phone")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                Text("For a browser, the code is \(bench.code.isEmpty ? "······" : bench.code)")
                    .font(.caption).foregroundStyle(.tertiary).textSelection(.enabled)
                    .padding(.top, 6)
                Button("New Code") { bench.renewCode() }.controlSize(.mini)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Paired").font(.caption).foregroundStyle(.secondary)
                if bench.devices.isEmpty {
                    Text("No phone yet: open Redlamp Bench on the iPhone and tap Pair.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(bench.devices, id: \.name) { device in
                    HStack {
                        Text(device.name)
                        if let last = device.lastContact {
                            Text(last, style: .relative).foregroundStyle(.secondary)
                        }
                        Button("Forget") { bench.forget(device) }.controlSize(.mini)
                    }
                    .font(.callout)
                }
            }
        }
    }

    private func folders(_ title: String, _ folders: [BenchFolder], area: BenchStore.Area, empty: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Show in Finder") {
                    try? bench.store.prepare()
                    NSWorkspace.shared.open(bench.store.url(area))
                }
                .controlSize(.small)
            }
            if folders.isEmpty {
                Text(empty).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(folders, id: \.id) { folder in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(folder.manifest.look?.title ?? folder.manifest.title)
                        Text(detail(folder, area: area)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([folder.url])
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func detail(_ folder: BenchFolder, area: BenchStore.Area) -> String {
        let who = folder.manifest.requestedBy
            .map { [$0.workstream, $0.tracker].compactMap(\.self).joined(separator: ", ") }
        switch area {
        case .done:
            return folder.summary + (folder.isComplete ? "" : ", not complete")
        default:
            let what = folder.manifest.withdrawn ? "withdrawn" : "\(folder.manifest.steps.count) steps"
            return [what, who].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
        }
    }

    private var events: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent").font(.headline)
            ForEach(bench.events) { event in
                HStack(alignment: .firstTextBaseline) {
                    Text(event.at, style: .time).foregroundStyle(.secondary).monospacedDigit()
                    Text(event.text).foregroundStyle(event.isProblem ? .red : .primary)
                }
                .font(.callout)
            }
        }
    }
}
