import AppKit
import SwiftUI

/// Help › Your Reports: what this Mac has sent and what's waiting to be, each opening on GitHub,
/// where anyone can read it and its replies.
struct YourReportsView: View {
    @Bindable var history: FeedbackHistory
    let dismiss: () -> Void
    /// Reports with news when the list opened; seen once it has.
    @State private var news: Set<UUID> = []
    @Environment(\.openURL) private var openURL

    static let size = CGSize(width: 620, height: 540)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your Reports").font(.title3.weight(.semibold))
                Spacer()
                if history.isRefreshing {
                    ProgressView().controlSize(.small)
                }
                Button("Check Now") { Task { await history.refresh(force: true) } }
                    .disabled(history.reports.isEmpty || history.isRefreshing)
            }
            Text(
                "Reports sent from this Mac. Each opens on GitHub, where anyone can read it and its replies, with or without an account.",
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if history.reports.isEmpty, history.queued.isEmpty {
                Text("Nothing sent from this Mac yet. Reports you send appear here.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !history.queued.isEmpty {
                        Section("Waiting to send") {
                            ForEach(history.queued) { item in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.submission.title).lineLimit(2)
                                        Text(
                                            "Saved \(item.queued.formatted(date: .abbreviated, time: .shortened)); sends when redlamp.app can be reached",
                                        )
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Send Now") { Task { await history.sendQueued() } }
                                }
                                .contextMenu {
                                    Button("Delete", role: .destructive) { history.forget(item.id) }
                                }
                            }
                        }
                    }
                    if !history.reports.isEmpty {
                        Section("Sent") {
                            ForEach(history.reports) { report in
                                Button {
                                    openURL(report.status?.url ?? report.url)
                                } label: {
                                    ReportRow(report: report, isNew: news.contains(report.id))
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Open on GitHub") { openURL(report.status?.url ?? report.url) }
                                    Button("Copy Link") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(
                                            (report.status?.url ?? report.url).absoluteString,
                                            forType: .string,
                                        )
                                    }
                                    Divider()
                                    Button("Remove from List") { history.forget(report.id) }
                                }
                            }
                        }
                    }
                }
            }
            HStack {
                Toggle("Check for replies and changes", isOn: $history.checksForReplies)
                    .help("Asks redlamp.app every few hours how your reports are doing")
                Spacer()
                Button("Done", action: dismiss).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: Self.size.width, height: Self.size.height)
        .task {
            await history.sendQueued()
            await history.refresh(force: true)
            news = Set(history.reports.filter(\.hasNews).map(\.id))
            history.markSeen()
        }
    }
}

private struct ReportRow: View {
    let report: SentReport
    let isNew: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(report.status?.title ?? report.title).lineLimit(2)
                Text(details).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isNew {
                Text("New")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.2)))
            }
        }
        .contentShape(Rectangle())
    }

    private var symbol: String {
        switch report.kind {
        case .bug: "ladybug"
        case .idea: "lightbulb"
        case .question: "questionmark.bubble"
        }
    }

    /// "#12 · Open · 2 replies · Tracked as MSK-18 · Phase 3 · sent 4 Oct 2026".
    private var details: String {
        var parts = ["#\(report.number)"]
        if let status = report.status {
            parts.append(status.summary)
            if status.comments > 0 {
                parts.append(status.comments == 1 ? "1 reply" : "\(status.comments) replies")
            }
            if let tracker = status.trackerID {
                parts.append("Tracked as \(tracker)")
            }
            if let milestone = status.milestone {
                parts.append(milestone)
            }
        }
        parts.append("sent \(report.sent.formatted(date: .abbreviated, time: .omitted))")
        return parts.joined(separator: " · ")
    }
}
