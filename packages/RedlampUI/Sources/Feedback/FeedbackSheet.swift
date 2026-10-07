import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Report a Bug or Send Feedback: a note asking people to be kind, then the report, then
/// what became of it.
struct FeedbackSheet: View {
    @Bindable var sheet: FeedbackSheetModel
    /// `size`'s height, or less on a short window: the report's fields scroll above its buttons.
    var height = Self.size.height
    let dismiss: () -> Void
    /// Closes the sheet and opens Your Reports.
    let showReports: () -> Void

    static let size = CGSize(width: 620, height: 780)

    var body: some View {
        Group {
            switch sheet.phase {
            case .note:
                FeedbackNote(accept: sheet.acceptNote, dismiss: dismiss)
            case .form, .sending:
                FeedbackForm(sheet: sheet, dismiss: dismiss, showReports: showReports)
            case let .sent(result):
                FeedbackSent(result: result, dismiss: dismiss)
            case .queued:
                FeedbackQueued(dismiss: dismiss, showReports: showReports)
            }
        }
        .frame(width: Self.size.width, height: height)
    }
}

/// Shown the first time, and again whenever its words change.
private struct FeedbackNote: View {
    let accept: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "hand.wave")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("Before you send a report")
                .font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 14) {
                Text(
                    "Redlamp is made by one person, and every report is read by that person. Bugs get looked into, and ideas shape what comes next.",
                )
                Text(
                    "Reports are posted on GitHub, in Redlamp's public issues, where anyone can read them. "
                        + "You'll see everything a report holds before you send it, and nothing that names you, "
                        + "your files or where they are goes with it unless you add it.",
                )
                Text(
                    "Please keep it friendly and constructive. Saying what you saw, and what you expected instead, helps most.",
                )
                Text("Thank you for helping make Redlamp better.")
                    .fontWeight(.medium)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 460, alignment: .leading)
            Spacer()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: dismiss).keyboardShortcut(.cancelAction)
                Button("Continue", action: accept).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }
}

private struct FeedbackForm: View {
    @Bindable var sheet: FeedbackSheetModel
    let dismiss: () -> Void
    let showReports: () -> Void
    @Environment(\.openURL) private var openURL
    @State private var choosingArea = false
    @State private var previewing = false

    private var kind: FeedbackReport.Kind {
        sheet.report.kind
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if sheet.restoredDraft {
                    Section {
                        HStack {
                            Text("Your unsent report is back as you left it.").foregroundStyle(.secondary)
                            Spacer()
                            Button("Start Over", action: sheet.startOver)
                        }
                    }
                }
                Section {
                    Picker("Kind", selection: $sheet.report.kind) {
                        ForEach(FeedbackReport.Kind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("Area") {
                        Button {
                            choosingArea = true
                        } label: {
                            HStack(spacing: 4) {
                                Text(sheet.report.topic?.path ?? "Choose an area…")
                                Image(systemName: "chevron.up.chevron.down").font(.caption2)
                            }
                        }
                        .popover(isPresented: $choosingArea, arrowEdge: .trailing) {
                            AreaPicker(
                                featureID: $sheet.report.featureID,
                                suggestion: sheet.context.suggestedTopic,
                                done: { choosingArea = false },
                            )
                        }
                    }
                } footer: {
                    if sheet.isSuggested {
                        Text("Suggested from what you were doing. Change it if it's about something else.").formFooter()
                    }
                }

                Section {
                    TextField(titlePrompt, text: $sheet.report.title, prompt: Text(titlePlaceholder))
                    WordsField(label: bodyLabel, text: $sheet.report.body, height: 96)
                    if kind != .question {
                        WordsField(
                            label: kind == .bug ? "What did you expect?" : "How could it work?",
                            text: $sheet.report.expected,
                            height: 60,
                        )
                    }
                    if kind == .bug {
                        WordsField(label: "Steps to reproduce", text: $sheet.report.steps, height: 70)
                        HStack {
                            Spacer()
                            Button("Insert Recent Steps", action: sheet.insertRecentSteps)
                                .help("Adds the last things you did, from the activity this report includes")
                                .disabled(sheet.context.activity.isEmpty)
                        }
                        Picker("How often?", selection: $sheet.report.frequency) {
                            Text("Not sure").tag(FeedbackReport.Frequency?.none)
                            ForEach(FeedbackReport.Frequency.allCases) { Text($0.title).tag(Optional($0)) }
                        }
                        if sheet.context.photo != nil {
                            Picker("Other photos too?", selection: $sheet.report.otherPhotos) {
                                Text("Not sure").tag(FeedbackReport.OtherPhotos?.none)
                                ForEach(FeedbackReport.OtherPhotos.allCases) { Text($0.title).tag(Optional($0)) }
                            }
                        }
                    }
                }

                ScreenshotsSection(sheet: sheet)

                Section {
                    Toggle("About what I was doing just now", isOn: $sheet.aboutSession)
                    Group {
                        Toggle("The photo, its edit and its history", isOn: $sheet.report.details.photo)
                            .disabled(sheet.context.photo == nil)
                        Toggle(
                            "What I did in the last 15 minutes, and the editor's state",
                            isOn: $sheet.report.details.activity,
                        )
                        Toggle("Redlamp's log", isOn: $sheet.report.details.log)
                    }
                    .padding(.leading, 18)
                    Toggle("The Mac and the Redlamp build", isOn: $sheet.report.details.system)
                    Toggle("File names (otherwise Photo A, Photo B)", isOn: $sheet.report.details.fileNames)
                    HStack {
                        Spacer()
                        Button("Preview the Report…") { previewing = true }
                    }
                } header: {
                    Text("Included with your report")
                } footer: {
                    Text("Paths, folder names, location and serial numbers are never included.").formFooter()
                }

                Section {
                    TextField("GitHub username", text: $sheet.report.githubUsername, prompt: Text("Optional"))
                    HStack {
                        Spacer()
                        Button("Your Reports…", action: showReports)
                    }
                } header: {
                    Text("Hearing back")
                } footer: {
                    Text(
                        "With a GitHub account, you're mentioned in the report and notified of replies. Either way, Help › Your Reports lists what you've sent, with a link to each report.",
                    )
                    .formFooter()
                }
            }
            .formStyle(.grouped)

            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .disabled(sheet.phase == .sending)
        .sheet(isPresented: $previewing) {
            ReportPreview(
                title: sheet.outgoing.issueTitle, labels: sheet.outgoing.labels, issue: sheet.previewBody,
                attachments: sheet.screenshots
                    .map(\.source) + (sheet.outgoing.includesDetails ? [FeedbackReport.diagnosticsName] : []),
                done: { previewing = false },
            )
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = sheet.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.callout)
                HStack {
                    if sheet.unreachable {
                        Button("Send When Online", action: sheet.queue)
                            .help("Keep the report and send it the next time Redlamp can reach redlamp.app")
                    }
                    Button("Save Report…", action: saveReport)
                    Button("File on GitHub Instead…", action: fileOnGitHub)
                        .help("Opens GitHub's new-issue page and copies the whole report; needs a GitHub account")
                }
            }
            HStack {
                Text(sheet.dryRun
                    ? "Debug build: sending is a dry run, and files nothing."
                    : "Reports are public. Please be kind: a person reads every one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if sheet.phase == .sending {
                    ProgressView().controlSize(.small)
                }
                Button("Cancel", role: .cancel, action: dismiss).keyboardShortcut(.cancelAction)
                Button(sheet.error == nil ? "Send Report" : "Try Again") {
                    Task { await sheet.send() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!sheet.canSend)
            }
        }
    }

    private func saveReport() {
        guard let submission = try? sheet.submission() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Redlamp Report \(Date().formatted(.iso8601.year().month().day()))"
        panel.message = "Saves the report as a folder: report.md, its screenshots and diagnostics.json."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FeedbackFallbacks.save(submission, to: url)
        } catch {
            sheet.error = "The report couldn't be saved: \(error.localizedDescription)"
        }
    }

    private func fileOnGitHub() {
        guard let submission = try? sheet.submission() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(FeedbackFallbacks.clipboardText(for: submission), forType: .string)
        openURL(FeedbackFallbacks.newIssueURL(for: submission))
    }

    private var titlePrompt: String {
        "Title"
    }

    private var titlePlaceholder: String {
        switch kind {
        case .bug: "What went wrong, in a line"
        case .idea: "What you'd like, in a line"
        case .question: "Your question, in a line"
        }
    }

    private var bodyLabel: String {
        switch kind {
        case .bug: "What happened?"
        case .idea: "What would you like to do?"
        case .question: "Your question or message"
        }
    }
}

/// A labelled text box for the person's own words.
private struct WordsField: View {
    let label: String
    @Binding var text: String
    let height: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
            TextEditor(text: $text)
                .font(.body)
                .frame(height: height)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
        }
    }
}

private struct ScreenshotsSection: View {
    @Bindable var sheet: FeedbackSheetModel

    var body: some View {
        Section {
            if let shot = sheet.windowShot {
                HStack(alignment: .top, spacing: 12) {
                    Thumbnail(jpeg: shot.jpeg)
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Include this screenshot of Redlamp's window", isOn: $sheet.includesWindowShot)
                        Text(
                            "It shows your photo and its file name, as they were when you opened this, and it will be public.",
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(sheet.report.screenshots) { shot in
                HStack(spacing: 12) {
                    Thumbnail(jpeg: shot.jpeg)
                    Text(shot.source).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Remove") { sheet.removeScreenshot(shot.id) }
                }
            }
            HStack {
                Button("Add Image…", action: chooseImages)
                Button("Paste") {
                    if let shot = Screenshots.fromPasteboard() {
                        sheet.add(shot)
                    }
                }
                Spacer()
                Text("Up to \(FeedbackReport.screenshotLimit)").font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!sheet.canAddScreenshot)
        } header: {
            Text("Screenshots")
        } footer: {
            Text(
                "Images lose their metadata, location included, before they're sent. To show a video, add it to the report on GitHub once it's sent.",
            )
            .formFooter()
        }
        .dropDestination(for: URL.self) { urls, _ in
            let shots = urls.compactMap(Screenshots.screenshot(url:))
            shots.forEach(sheet.add)
            return !shots.isEmpty
        }
    }

    private func chooseImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        panel.urls.compactMap(Screenshots.screenshot(url:)).forEach(sheet.add)
    }
}

private struct Thumbnail: View {
    let jpeg: Data

    var body: some View {
        Group {
            if let image = NSImage(data: jpeg) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Color.secondary.opacity(0.1)
            }
        }
        .frame(width: 96, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.12)))
    }
}

/// The issue exactly as it will be filed, before it's sent.
private struct ReportPreview: View {
    let title: String
    let labels: [String]
    let issue: String
    let attachments: [String]
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The report, as it will appear on GitHub").font(.headline)
            Text(title).font(.title3.weight(.semibold)).textSelection(.enabled)
            HStack(spacing: 6) {
                ForEach(labels, id: \.self) { label in
                    Text(label)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
            }
            if !attachments.isEmpty {
                Text("Attached: " + attachments.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                Text(issue)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("# \(title)\n\n\(issue)", forType: .string)
                }
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 660, height: 660)
    }
}

private struct FeedbackQueued: View {
    let dismiss: () -> Void
    let showReports: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "tray.and.arrow.up")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("Saved, to send later").font(.title2.weight(.semibold))
            Text("Redlamp sends it the next time it can reach redlamp.app. Until then it waits in Your Reports.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
                .multilineTextAlignment(.center)
            Spacer()
            HStack {
                Button("Your Reports…", action: showReports)
                Spacer()
                Button("Done", action: dismiss).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }
}

private struct FeedbackSent: View {
    let result: FeedbackResult
    let dismiss: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 18) {
            switch result {
            case let .filed(number, url):
                Spacer()
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.green)
                Text("Thank you. Report #\(number) is on GitHub.")
                    .font(.title2.weight(.semibold))
                VStack(alignment: .leading, spacing: 10) {
                    Text(
                        "Help › Your Reports lists it with its status, and links to it. You don't need a GitHub account to read it or its replies.",
                    )
                    Text(
                        "To add a video, open the report on GitHub and drag the video into a comment. That needs a GitHub account.",
                    )
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460, alignment: .leading)
                HStack {
                    Button("Copy Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                    Button("Open on GitHub") { openURL(url) }
                }
                Spacer()
            case let .dryRun(title, body, labels):
                Text("Dry run: nothing was filed").font(.title3.weight(.semibold))
                Text("The relay would have filed this issue, labelled \(labels.joined(separator: ", ")).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text("# \(title)\n\n\(body)")
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
            }
            HStack {
                Spacer()
                Button("Done", action: dismiss).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }
}
