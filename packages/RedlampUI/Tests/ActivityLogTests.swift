import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampUI

/// The session's activity, as a feedback report reads it: in order, bounded, runs collapsed,
/// photos by alias, and filled by the editor as people work.
@MainActor
struct ActivityLogTests {
    private final class Clock {
        var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func advance(_ seconds: TimeInterval) {
            now += seconds
        }
    }

    private func log(capacity: Int = 100) -> (ActivityLog, Clock) {
        let clock = Clock()
        return (ActivityLog(capacity: capacity) { clock.now }, clock)
    }

    @Test func `events keep their order and times`() {
        let (log, clock) = log()
        log.record(.tool, "Tool: Masking")
        clock.advance(3)
        log.record(.mask, "Armed: Brush")
        #expect(log.events.map(\.text) == ["Tool: Masking", "Armed: Brush"])
        #expect(log.events[1].time.timeIntervalSince(log.events[0].time) == 3)
    }

    @Test func `the oldest events go first once it's full`() {
        let (log, _) = log(capacity: 3)
        for index in 1 ... 5 {
            log.record(.action, "Action \(index)")
        }
        #expect(log.events.map(\.text) == ["Action 3", "Action 4", "Action 5"])
    }

    @Test func `a run of the same event is one entry with a count`() {
        let (log, _) = log()
        log.record(.action, "Increase Setting")
        log.record(.action, "Increase Setting")
        log.record(.action, "Increase Setting")
        log.record(.action, "Undo")
        #expect(log.events.map(\.text) == ["Increase Setting", "Undo"])
        #expect(log.events[0].count == 3)
    }

    @Test func `events with a key replace each other only a moment apart`() {
        let (log, clock) = log()
        log.record(.view, "Zoom: 50%", replacing: "zoom")
        clock.advance(0.5)
        log.record(.view, "Zoom: 80%", replacing: "zoom")
        clock.advance(5)
        log.record(.view, "Zoom: 100%", replacing: "zoom")
        #expect(log.events.map(\.text) == ["Zoom: 80%", "Zoom: 100%"])
    }

    @Test func `photos are named by the order they were opened`() {
        let (log, _) = log()
        let first = URL(fileURLWithPath: "/Users/someone/Pictures/Lisbon/DSCF0001.RAF")
        let second = URL(fileURLWithPath: "/Volumes/Card/IMG_0002.CR3")
        #expect(log.alias(for: first) == "Photo A")
        #expect(log.alias(for: second) == "Photo B")
        #expect(log.alias(for: first) == "Photo A")
        #expect(log.photoNames.map(\.alias) == ["Photo A", "Photo B"])
        #expect(log.photoNames.map(\.fileName) == ["DSCF0001.RAF", "IMG_0002.CR3"])
        #expect(ActivityLog.letters(25) == "Z")
        #expect(ActivityLog.letters(26) == "AA")
        #expect(ActivityLog.letters(701) == "ZZ")
        #expect(ActivityLog.letters(702) == "AAA")
    }

    @Test func `events since a time`() {
        let (log, clock) = log()
        log.record(.action, "Early")
        clock.advance(60)
        let cut = clock.now
        log.record(.action, "Late")
        #expect(log.events(since: cut).map(\.text) == ["Late"])
    }

    @Test func `events round-trip through JSON without their keys`() throws {
        let (log, _) = log()
        log.record(.view, "Zoom: 50%", replacing: "zoom")
        let data = try JSONEncoder().encode(log.events)
        let decoded = try JSONDecoder().decode([ActivityLog.Event].self, from: data)
        #expect(decoded.map(\.text) == ["Zoom: 50%"])
        #expect(!String(decoding: data, as: UTF8.self).contains("key"))
    }

    // MARK: - The editor's activity

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 400 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func texts(_ model: EditorModel) -> [String] {
        model.activity.events.map(\.text)
    }

    @Test func `the editor records what people do, and not what didn't happen`() async throws {
        let model = EditorModel(engine: StubEngine())
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appending(path: "IMG_0001.ARW")
        #expect(texts(model).first == "Redlamp started")

        #expect(!model.perform(.autoWhiteBalance))
        #expect(!texts(model).contains("Auto White Balance"))

        model.select(photo)
        try await eventually { model.info?.url == photo }
        #expect(texts(model).contains { $0.hasPrefix("Opened Photo A: ARW, 600 × 400, unedited, in ") })
        #expect(!texts(model).contains { $0.contains("IMG_0001") })

        model.setValue(.exposure, 0.5)
        #expect(texts(model).last == "Exposure: 0.00 → +0.50")

        #expect(model.perform(.toggleFilmstrip))
        #expect(texts(model).last == ShortcutAction.toggleFilmstrip.title)

        model.activeTool = .masking
        try await eventually { texts(model).last == "Tool: Masking" }
        #expect(texts(model).last == "Tool: Masking")

        model.maskMessage = "The model isn't downloaded"
        try await eventually { texts(model).last == "Masking said: The model isn't downloaded" }
        #expect(texts(model).last == "Masking said: The model isn't downloaded")
    }
}
