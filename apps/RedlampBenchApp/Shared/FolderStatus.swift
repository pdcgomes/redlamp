import Foundation
import RedlampBench
import SwiftUI

/// Where a task or look reference stands, the same everywhere it's shown: in the list, at the
/// top of its screen, on its last step and in the share sheet.
enum FolderStatus: Equatable {
    /// Results still to come back: `back` of `of`, or of an open number when `of` is 0.
    case toDo(back: Int, of: Int)
    /// Complete, in the queue; `problem` is why the last try failed.
    case waiting(problem: String?)
    /// Being uploaded, with the share done when known.
    case sending(Double?)
    case sent(Date?)
    /// Sent before it was complete; the rest goes once it is.
    case sentEarly(back: Int, of: Int)

    init(
        _ folder: BenchFolder,
        queue: [BenchLibrary.Queued],
        sent: [String: String],
        sentAt: [String: Date],
        sending: (id: String, progress: Double?)?,
    ) {
        let required = folder.manifest.requiredAssets.count
        let back = required == 0 ? folder.results.results.count : required - folder.missing.count
        if let sending, sending.id == folder.id {
            self = .sending(sending.progress)
        } else if sent[folder.id] == folder.resultsDigest {
            self = folder.isComplete ? .sent(sentAt[folder.id]) : .sentEarly(back: back, of: required)
        } else if let entry = queue.first(where: { $0.id == folder.id }) {
            self = .waiting(problem: entry.lastError)
        } else if folder.isComplete {
            self = .waiting(problem: nil)
        } else {
            self = .toDo(back: back, of: required)
        }
    }

    init(_ folder: BenchFolder, in library: BenchLibrary) {
        self.init(folder, queue: library.queue, sent: library.sent, sentAt: library.sentAt, sending: nil)
    }

    var isSent: Bool {
        if case .sent = self {
            true
        } else {
            false
        }
    }

    /// A short line for a list row.
    func title(labAway: Bool) -> String {
        switch self {
        case let .toDo(back, of):
            if of == 0 {
                back == 0 ? "Not started" : "\(back) result\(back == 1 ? "" : "s") so far"
            } else {
                back == 0 ? "\(of) photo\(of == 1 ? "" : "s") to do" : "\(back) of \(of) back"
            }
        case let .waiting(problem):
            if problem != nil {
                "Complete · couldn't send, will try again"
            } else {
                labAway ? "Complete · sends when the Lab is reachable" : "Complete · waiting to send"
            }
        case let .sending(progress):
            progress.map { "Sending to the Lab… \(Int(($0 * 100).rounded()))%" } ?? "Sending to the Lab…"
        case let .sent(date):
            date.map { "Sent to the Lab \($0.formatted(.relative(presentation: .named)))" } ?? "Sent to the Lab"
        case let .sentEarly(back, of):
            "Sent early · \(back) of \(of) back, the rest goes when complete"
        }
    }

    var symbol: String {
        switch self {
        case .toDo: "circle.dashed"
        case let .waiting(problem): problem == nil ? "clock.arrow.circlepath" : "exclamationmark.arrow.circlepath"
        case .sending: "arrow.up.circle"
        case .sent: "checkmark.circle.fill"
        case .sentEarly: "arrow.up.circle.badge.clock"
        }
    }

    var tint: Color {
        switch self {
        case .toDo: .secondary
        case let .waiting(problem): problem == nil ? .orange : .red
        case .sending: .blue
        case .sent: .green
        case .sentEarly: .teal
        }
    }
}

/// The status's icon: a ring that fills as results come back or as the upload goes, or the
/// state's symbol.
struct FolderStatusIcon: View {
    let status: FolderStatus
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            switch status {
            case let .toDo(back, of) where of > 0:
                ring(Double(back) / Double(of), color: back == 0 ? .secondary : .accentColor)
                Text("\(back)").font(.system(size: size * 0.4, weight: .semibold).monospacedDigit())
                    .foregroundStyle(back == 0 ? .secondary : .primary)
            case let .sending(progress):
                if let progress {
                    ring(progress, color: .blue)
                    Image(systemName: "arrow.up").font(.system(size: size * 0.4, weight: .bold)).foregroundStyle(.blue)
                } else {
                    ProgressView()
                }
            default:
                Image(systemName: status.symbol)
                    .font(.system(size: size * 0.8))
                    .foregroundStyle(status.tint)
            }
        }
        .frame(width: size, height: size)
        .animation(.default, value: status)
    }

    private func ring(_ value: Double, color: Color) -> some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: size * 0.1)
            Circle().trim(from: 0, to: max(0.001, value))
                .stroke(color, style: StrokeStyle(lineWidth: size * 0.1, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}
