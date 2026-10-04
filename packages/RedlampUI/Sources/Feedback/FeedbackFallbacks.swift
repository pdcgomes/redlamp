import Foundation

/// What to do with a report the relay can't take: file it on GitHub by hand (with a GitHub
/// account), or keep it as files.
public enum FeedbackFallbacks {
    public static let newIssue = URL(string: "https://github.com/pdcgomes/redlamp/issues/new")!
    /// GitHub turns away much longer addresses.
    static let urlLimit = 7000

    /// GitHub's new-issue page with the title and as much of the report as fits in an address.
    /// The person pastes the whole report, which the sheet copies, and drags the screenshots in.
    public static func newIssueURL(for submission: FeedbackSubmission) -> URL {
        let body = linkingNothing(submission.body)
        var length = body.count
        while true {
            let shown = length < body.count
                ? String(body.prefix(length)) + "\n\n*(Shortened: paste the full report from your clipboard here.)*"
                : body
            var components = URLComponents(url: newIssue, resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "title", value: submission.title),
                URLQueryItem(name: "body", value: shown),
            ]
            if let url = components.url, url.absoluteString.count <= urlLimit || length == 0 {
                return url
            }
            length = length * 2 / 3
        }
    }

    /// The report as it would be filed, with its attachments as links to drag in by hand.
    public static func clipboardText(for submission: FeedbackSubmission) -> String {
        "# \(submission.title)\n\n" + linkingNothing(submission.body)
    }

    /// Writes the report as a folder: report.md, and beside it the screenshots and diagnostics.json
    /// it links to.
    public static func save(_ submission: FeedbackSubmission, to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let body = submission.body.replacing(/\]\(attachment:([A-Za-z0-9._-]+)\)/) { "](\($0.1))" }
        let text = "# \(submission.title)\n\nLabels: \(submission.labels.joined(separator: ", "))\n\n\(body)"
        try Data(text.utf8).write(to: folder.appending(path: "report.md"), options: .atomic)
        for attachment in submission.attachments {
            try attachment.data.write(to: folder.appending(path: attachment.name), options: .atomic)
        }
    }

    private static func linkingNothing(_ body: String) -> String {
        body.replacing(/!?\[([^\]]*)\]\(attachment:([A-Za-z0-9._-]+)\)/) { "\($0.1) (attach \($0.2) here)" }
    }
}
