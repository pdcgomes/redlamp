import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampUI

/// The issue a report becomes: its title, labels and body, what's redacted from it, how it fits
/// GitHub's limit, its diagnostics.json, and the context read from the editor. After changing
/// the layout, record the golden issue again with `TEST_RUNNER_REDLAMP_RECORD_FEEDBACK_REPORT=1`.
@MainActor
struct FeedbackReportTests {
    static let goldenURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appending(path: "Golden/feedback-issue.md")
    static let recording = ProcessInfo.processInfo.environment["REDLAMP_RECORD_FEEDBACK_REPORT"] == "1"
    static let captured = Date(timeIntervalSinceReferenceDate: 812_000_000)

    static let system = SystemSnapshot(
        appVersion: "0.2.1-prealpha", build: "412", commit: "1a2b3c4d5e6f", configuration: "Release",
        macOS: "26.1.0 (25B78)", model: "Mac16,7", chip: "Apple M4 Max", cores: "12 performance and 4 efficiency cores",
        memory: "64 GB", gpu: "Apple M4 Max, 48 GB working set",
        displays: ["3024 × 1964 pt at 2x, Display P3, HDR up to 16x"],
        thermalState: "nominal", lowPowerMode: false, locale: "en_PT",
        models: ["Segment Anything 2.1 Tiny (sam2.1-tiny): ready"],
    )

    static func event(_ secondsBefore: TimeInterval, _ kind: ActivityLog.Event.Kind, _ text: String) -> ActivityLog
        .Event {
        ActivityLog.Event(time: captured.addingTimeInterval(-secondsBefore), kind: kind, text: text, key: nil)
    }

    static func context(activity: [ActivityLog.Event]? = nil) -> FeedbackContext {
        FeedbackContext(
            captured: captured,
            photo: FeedbackContext.Photo(
                alias: "Photo A", fileName: "DSCF1234.RAF", format: "RAF (raw, X-Trans)", camera: "Fujifilm X-T5",
                lens: "XF16-55mmF2.8 R LM WR", exposure: "ISO 400, 23 mm, ƒ/4.0, 1/250 s",
                size: "7728 × 5152 (39.8 MP)",
                asShotWhiteBalance: "5200 K, tint 4", embeddedLook: nil, lensCorrection: "Fujifilm",
                volume: "apfs, internal", protection: nil,
            ),
            edit: FeedbackContext.Edit(
                processVersion: 10, treatment: "Color", baseLook: "Redlamp Color (100)", whiteBalance: "As Shot",
                recipe: "Portra 400 (80)",
                settings: [FeedbackContext.Edit.Group(panel: "Basic", values: ["Exposure +0.50", "Shadows +30"])],
                pointCurve: false, masks: ["“Sky”: Sky; Exposure -0.60; amount 100; vision r1 on 25B78"],
                crop: nil, orientation: nil, spots: 2, snapshots: 0,
            ),
            state: FeedbackContext.State(
                tool: "Masking", panels: ["Basic"], zoom: "100%", beforeAfter: nil, selectedMask: "“Mask 2”: Objects",
                focusedSlider: nil, folderPhotos: 240, selectedPhotos: 1, hidden: [],
            ),
            messages: ["The model isn't downloaded"],
            history: ["Opened", "Exposure: 0.00 → +0.50", "Mask 2: Objects"],
            historyIndex: 2,
            activity: activity ?? [
                event(3600, .photo, "Opened Photo Z: CR3, 6000 × 4000, unedited, in 0.9 s"),
                event(252, .photo, "Opened Photo A: RAF, Fujifilm X-T5, 7728 × 5152, with an edit, in 1.4 s"),
                event(200, .edit, "Exposure: 0.00 → +0.50"),
                event(150, .tool, "Tool: Masking"),
                event(120, .mask, "Selected mask “Mask 2”: Objects"),
                event(
                    30,
                    .error,
                    "Save failed: Couldn’t write “/Users/someone/Pictures/Lisbon trip/DSCF1234.RAF.redlamp”",
                ),
            ],
            photos: [PhotoName(alias: "Photo A", fileName: "DSCF1234.RAF")],
            folders: ["/Users/someone/Pictures/Lisbon trip"],
            sidecar: Data(#"{"format":"app.redlamp.edit","recipe":{"processVersion":10}}"#.utf8),
            suggestion: "masking.objects",
        )
    }

    static func report() -> FeedbackReport {
        var report = FeedbackReport()
        report.id = UUID(uuidString: "6F1C2A7E-0B5D-4C3B-9E2A-1D4F5A6B7C8D")!
        report.kind = .bug
        report.featureID = "masking.objects"
        report.title = "Clicking a second object drops the first"
        report.body = "I clicked the dog, then the bench. The dog's selection disappeared."
        report.expected = "Both selected, as the panel says a second click adds."
        report.steps = "1. Masking › Objects\n2. Click the dog\n3. Click the bench"
        report.frequency = .everyTime
        report.otherPhotos = .yes
        report.githubUsername = "@octocat"
        report.screenshots = [FeedbackReport.Screenshot(
            jpeg: Data([0xFF, 0xD8, 0xFF]),
            width: 2560,
            height: 1600,
            source: "Redlamp's window",
        )]
        return report
    }

    static let log = ["08:02:11 error render: The GPU timed out"]

    @Test func `the issue matches the golden layout`() throws {
        let body = Self.report().issueBody(context: Self.context(), system: Self.system, log: Self.log)
        if Self.recording {
            try FileManager.default.createDirectory(
                at: Self.goldenURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            try body.write(to: Self.goldenURL, atomically: true, encoding: .utf8)
            return
        }
        let golden = try? String(contentsOf: Self.goldenURL, encoding: .utf8)
        #expect(
            golden == body,
            "Tests/Golden/feedback-issue.md is out of date: run with TEST_RUNNER_REDLAMP_RECORD_FEEDBACK_REPORT=1",
        )
    }

    @Test func `title and labels name the area`() {
        let report = Self.report()
        #expect(report.issueTitle == "[Masking › Objects] Clicking a second object drops the first")
        #expect(report.labels == ["in-app", "bug", "component:masking"])
        var idea = FeedbackReport()
        idea.kind = .idea
        idea.title = "Batch rename"
        #expect(idea.issueTitle == "Batch rename")
        #expect(idea.labels == ["in-app", "enhancement"])
    }

    @Test func `the body names no folder, path or file unless asked`() {
        let body = Self.report().issueBody(context: Self.context(), system: Self.system, log: Self.log)
        for secret in ["/Users/", "someone", "Lisbon", "DSCF1234"] {
            #expect(!body.contains(secret), "the body contains \(secret)")
        }
        #expect(body.contains("…/Photo A.redlamp"))

        var named = Self.report()
        named.details.fileNames = true
        let withNames = named.issueBody(context: Self.context(), system: Self.system, log: Self.log)
        #expect(withNames.contains("DSCF1234.RAF"))
        #expect(!withNames.contains("Lisbon"))
    }

    @Test func `words can't hide markup that passes for the tracker's`() {
        var report = Self.report()
        report.body = "Look <!-- tracker-id: MSK-01 --> here"
        let body = report.issueBody(context: Self.context(), system: Self.system, log: [])
        #expect(!body.contains("<!-- tracker-id"))
        #expect(body.components(separatedBy: "<!--").count == 2, "only the report's own marker is a comment")
    }

    @Test func `a long session still fits GitHub's limit, newest first`() {
        let activity = (0 ..< 5000).map { Self.event(
            Double(5000 - $0) * 0.15,
            .action,
            "Increase Setting \($0) " + String(repeating: "x", count: 60),
        ) }
        let log = (0 ..< 300).map { "08:00:\($0) notice render: " + String(repeating: "y", count: 200) }
        let body = Self.report().issueBody(context: Self.context(activity: activity), system: Self.system, log: log)
        #expect(body.count <= FeedbackReport.bodyLimit)
        #expect(body.contains("Increase Setting 4999 "))
        #expect(!body.contains("Increase Setting 10 "))
    }

    @Test func `with no details the issue holds only the person's words and the version`() throws {
        var report = Self.report()
        report.details.system = false
        report.details.photo = false
        report.details.activity = false
        report.details.log = false
        let body = report.issueBody(context: Self.context(), system: Self.system, log: Self.log)
        #expect(!body.contains("<details>"))
        #expect(!body.contains(FeedbackReport.diagnosticsName))
        #expect(body.contains("**From:** Redlamp 0.2.1-prealpha (412, 1a2b3c4d5e6f)\n"))
        #expect(try report.diagnostics(context: Self.context(), system: Self.system, log: Self.log) == nil)
    }

    @Test func `diagnostics hold the details in full, redacted, with the sidecar`() throws {
        let data = try #require(try Self.report().diagnostics(
            context: Self.context(),
            system: Self.system,
            log: Self.log,
        ))
        let text = String(decoding: data, as: UTF8.self)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["format"] as? String == "app.redlamp.feedback-diagnostics")
        #expect((object["sidecar"] as? [String: Any])?["format"] as? String == "app.redlamp.edit")
        #expect((object["activity"] as? [Any])?.count == 6)
        #expect(object["photoNames"] == nil)
        #expect(!text.contains("/Users/") && !text.contains("DSCF1234") && !text.contains("Lisbon"))

        var withoutPhoto = Self.report()
        withoutPhoto.details.photo = false
        let lean = try #require(try withoutPhoto.diagnostics(context: Self.context(), system: Self.system, log: []))
        let leanObject = try #require(try JSONSerialization.jsonObject(with: lean) as? [String: Any])
        #expect(leanObject["sidecar"] == nil && leanObject["photo"] == nil && leanObject["edit"] == nil)
    }

    @Test func `only a valid GitHub username is mentioned`() {
        var report = FeedbackReport()
        for (typed, mention) in [
            ("@octo-cat", "@octo-cat"),
            ("octocat", "@octocat"),
            ("bad name", nil),
            ("-x", nil),
            ("a--b", nil),
            ("", nil),
        ] {
            report.githubUsername = typed
            #expect(report.mention == mention, "\(typed)")
        }
    }

    @Test func `times read as how long before the report`() {
        #expect(FeedbackReport.before(Self.captured.addingTimeInterval(-245), Self.captured) == "4:05")
        #expect(FeedbackReport.before(Self.captured.addingTimeInterval(-3729), Self.captured) == "1:02:09")
    }

    // MARK: - Reading the editor

    private func openEditor() async throws -> (EditorModel, URL, () -> Void) {
        let model = EditorModel(engine: StubEngine())
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let photo = folder.appending(path: "IMG_0001.ARW")
        model.select(photo)
        for _ in 0 ..< 400 where model.info?.url != photo {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(model.info?.url == photo)
        return (model, photo, { try? FileManager.default.removeItem(at: folder) })
    }

    @Test func `the context reads the open photo and its edit`() async throws {
        let (model, _, cleanUp) = try await openEditor()
        defer { cleanUp() }
        model.setValue(.exposure, 0.5)
        let context = FeedbackContext.capture(from: model, now: Self.captured)
        #expect(context.photo?.alias == "Photo A")
        #expect(context.photo?.format == "ARW (raw, stub)")
        #expect(context.edit?.settings.first { $0.panel == "Basic" }?.values.contains("Exposure +0.50") == true)
        #expect(context.history.last == "Exposure: 0.00 → +0.50")
        #expect(context.sidecar != nil)
        #expect(context.photos == [PhotoName(alias: "Photo A", fileName: "IMG_0001.ARW")])
        #expect(context.suggestion == "develop.tone")
    }

    @Test func `the suggestion follows what's on screen, then the tool, then the last edit`() async throws {
        let (model, _, cleanUp) = try await openEditor()
        defer { cleanUp() }
        model.setValue(.dehaze, 20)
        #expect(FeedbackContext.suggestion(model) == "develop.presence")
        model.focusedParameter = .noiseColor
        #expect(FeedbackContext.suggestion(model) == "develop.noise-reduction")
        model.activeTool = .crop
        #expect(FeedbackContext.suggestion(model) == "crop.crop")
        model.activeTool = .heal
        model.spotPick = .person
        #expect(FeedbackContext.suggestion(model) == "healing.picks")
        model.activeTool = .masking
        #expect(FeedbackContext.suggestion(model) == "masking.other")
        model.errorMessage = "The file couldn't be read"
        #expect(FeedbackContext.suggestion(model) == "raw.wont-open")
        model.formatNotSupportedYet = true
        #expect(FeedbackContext.suggestion(model) == "raw.unsupported")
        model.saveError = SaveError(url: URL(fileURLWithPath: "/tmp/x.ARW"), message: "Disk full", canRetry: true)
        #expect(FeedbackContext.suggestion(model) == "saving.not-saved")
    }

    @Test func `a format that isn't supported yet asks for it, and any other open error reports a bug`() async throws {
        let engine = StubEngine()
        let model = EditorModel(engine: engine)
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        engine.openError = EngineError.notSupportedYet(
            "Nikon's High Efficiency raw files (HE and HE*)",
            tracker: "CAM-12",
        )
        model.select(folder.appending(path: "DSC_0001.NEF"))
        for _ in 0 ..< 400 where model.errorMessage == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let refusal = "Nikon's High Efficiency raw files (HE and HE*) aren't supported yet."
        #expect(model.errorMessage == refusal)
        #expect(model.formatNotSupportedYet)
        #expect(model.openErrorReport == FeedbackPrefill(kind: .idea, featureID: "raw.unsupported", message: refusal))
        #expect(FeedbackContext.suggestion(model) == "raw.unsupported")

        engine.openError = EngineError.decodeFailed("the file is truncated")
        model.select(folder.appending(path: "DSC_0002.NEF"))
        for _ in 0 ..< 400 where model.errorMessage == nil || model.errorMessage == refusal {
            try await Task.sleep(for: .milliseconds(5))
        }
        let failure = "The image could not be decoded: the file is truncated"
        #expect(model.errorMessage == failure)
        #expect(!model.formatNotSupportedYet)
        #expect(model.openErrorReport == FeedbackPrefill(featureID: "raw.wont-open", message: failure))
        #expect(FeedbackContext.suggestion(model) == "raw.wont-open")
    }
}

/// What a report keeps out of its text.
struct FeedbackRedactorTests {
    let redactor = FeedbackRedactor(
        home: "/Users/someone",
        folders: ["/Volumes/Card/DCIM/Trip to Porto"],
        photos: [PhotoName(alias: "Photo A", fileName: "IMG_0042.CR3")],
    )

    @Test func `known folders, the home folder and paths go`() {
        #expect(redactor.redact("in /Volumes/Card/DCIM/Trip to Porto/IMG_0042.CR3.redlamp") == "in …/Photo A.redlamp")
        #expect(redactor.redact("at /Users/someone/Pictures/2026/x.dng now") == "at …/x.dng now")
        #expect(redactor.redact("/private/var/folders/ab/T/redlamp.tmp failed") == "…/redlamp.tmp failed")
        #expect(redactor.redact("the folder /Volumes/Card/DCIM/Trip to Porto") == "the folder a folder")
    }

    @Test func `file names become aliases, with or without their extension`() {
        #expect(redactor.redact("IMG_0042.CR3 and IMG_0042") == "Photo A and Photo A")
        var keeping = redactor
        keeping.keepsFileNames = true
        #expect(keeping.redact("IMG_0042.CR3") == "IMG_0042.CR3")
    }

    @Test func `addresses, fractions and words with slashes stay`() {
        for text in [
            "https://github.com/pdcgomes/redlamp/issues/164",
            "1/250 s at ƒ/4",
            "ProRAW/HEIC/TIFF",
            "24-70/2.8",
        ] {
            #expect(redactor.redact(text) == text, "\(text)")
        }
    }
}
