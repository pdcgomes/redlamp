import AppKit
import CoreGraphics
import Foundation
import RedlampDocument
import Synchronization
import Testing
@testable import RedlampUI

/// Held arrow keys in the Library loupe and in Develop (LIB-16): the photos ahead are read in the direction of
/// travel, decoding latest-wins, so each photo shows its thumbnail the moment it's reached, never a blank frame,
/// and its preview as soon as that lands. Here thumbnails and previews take longer than a frame to decode, so a
/// photo that wasn't read ahead is blank when it's reached, and shows its preview a frame later only if it was read
/// ahead; how many do depends on the Mac's load, so only a quarter are asked for. One at a time, as they measure
/// frames.
@MainActor
@Suite(.serialized)
struct LibraryNavigationTests {
    /// Slower than a frame at 120 Hz.
    nonisolated static let thumbnailTime = 0.012
    nonisolated static let previewTime = 0.015
    /// A held arrow key's repeat at macOS's fastest setting, and a frame at 120 Hz.
    static let keyRepeat = 0.030
    static let frame = 1.0 / 120

    /// What decodes record, from the threads they run on.
    final class Record<Value: Sendable>: Sendable {
        private let values = Mutex<[Value]>([])

        func append(_ value: Value) {
            values.withLock { $0.append(value) }
        }

        var all: [Value] {
            values.withLock { $0 }
        }
    }

    /// A folder of photos open in an editor whose thumbnails and previews decode slowly, with the window's module
    /// views around it and the filmstrip hidden, so nothing but the reading ahead loads the photos ahead.
    @MainActor
    final class Fixture {
        let folder = FileManager.default.temporaryDirectory.appending(path: "navigation-\(UUID().uuidString)")
        let packs = FileManager.default.temporaryDirectory.appending(path: "navigation-packs-\(UUID().uuidString)")
        let engine = StubEngine()
        let model: EditorModel
        /// The photos whose previews were decoded, in order.
        let previewed = Record<URL>()
        private(set) var photos: [URL] = []
        private(set) var content: ModuleContentController?
        private var window: NSWindow?

        /// Lanes of its own, so the decodes of tests running beside it don't hold up its own.
        init() {
            let scheduler = WorkScheduler()
            let loader = ThumbnailLoader(scheduler: scheduler, packs: ThumbnailPacks(directory: packs)) { _, size in
                Thread.sleep(forTimeInterval: LibraryNavigationTests.thumbnailTime)
                return ModuleFixture.image(size)
            }
            model = EditorModel(engine: engine, library: FolderLibrary(scheduler: scheduler), thumbnailLoader: loader)
            engine.decodedThumbnail = { [previewed] url, size in
                Thread.sleep(forTimeInterval: LibraryNavigationTests.previewTime)
                previewed.append(url)
                return ModuleFixture.image(min(size, 1200))
            }
            _ = NSApplication.shared
        }

        func open(count: Int) async throws {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Written an hour ago: a photo written in the last two seconds may still be arriving, and isn't read.
            let written: [FileAttributeKey: Any] = [.modificationDate: Date(timeIntervalSinceNow: -3600)]
            for index in 0 ..< count {
                let url = folder.appending(path: String(format: "NAV_%05d.ARW", index))
                FileManager.default.createFile(atPath: url.path, contents: Data([1]), attributes: written)
                photos.append(url)
            }
            model.filmstripVisible = false
            model.open([folder])
            try await eventually { self.model.library.count == count && self.model.info?.url == self.photos.first }
            let content = ModuleContentController(model: model, theme: ThemeSettings(), develop: PlainViewController())
            content.view.frame = CGRect(x: 0, y: 0, width: 1400, height: 900)
            let window = NSWindow(
                contentRect: content.view.frame,
                styleMask: [.titled],
                backing: .buffered,
                defer: false,
            )
            window.contentView = content.view
            content.view.layoutSubtreeIfNeeded()
            self.content = content
            self.window = window
        }

        func eventually(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(30)
            while !condition(), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
        }

        func cleanUp() {
            window?.contentView = nil
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: packs)
        }
    }

    /// Holds → for `steps` steps `interval` apart; a frame after each, whether what's shown is blank and whether it's
    /// the photo's preview.
    private func hold(
        _ model: EditorModel, steps: Int, interval: Double, shown: () -> (blank: Bool, preview: Bool),
    ) async throws -> (blank: Int, previews: Int) {
        let clock = ContinuousClock()
        let start = clock.now
        var (blank, previews) = (0, 0)
        var blankSteps: [Int] = []
        defer {
            if !blankSteps.isEmpty {
                print("Blank at steps \(blankSteps)")
            }
        }
        for step in 1 ... steps {
            model.perform(.nextPhoto)
            try await Task.sleep(for: .seconds(Self.frame))
            let state = shown()
            blank += state.blank ? 1 : 0
            previews += state.preview ? 1 : 0
            if state.blank {
                blankSteps.append(step)
            }
            let due = start + .seconds(interval * Double(step))
            if clock.now < due {
                try await clock.sleep(until: due)
            }
        }
        return (blank, previews)
    }

    @Test(.measuresSpeed)
    func `→ held at key-repeat speed in the loupe never shows a blank frame, each preview read ahead`() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        try await fixture.open(count: 300)
        let model = fixture.model
        let loupe = try #require(fixture.content?.library.loupe)
        model.showLibrary(.loupe)
        model.click(fixture.photos[120])
        try await fixture.eventually { loupe.showsPreview }
        try await Task.sleep(for: .milliseconds(200))
        let steps = 60
        let held = try await hold(model, steps: steps, interval: Self.keyRepeat) {
            (loupe.image == nil, loupe.showsPreview)
        }
        print("Loupe, → held at \(Int(Self.keyRepeat * 1000)) ms: \(held.blank) blank frames in \(steps) steps, "
            + "\(held.previews) previews on screen a frame after their photo was reached")
        #expect(model.selection == fixture.photos[120 + steps])
        #expect(held.blank == 0, "\(held.blank) blank frames")
        #expect(held.previews >= steps / 4, "\(held.previews) of \(steps) previews were read ahead")
    }

    @Test(.measuresSpeed)
    func `→ held at key-repeat speed in Develop never shows a blank canvas, each preview read ahead`() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        try await fixture.open(count: 300)
        let model = fixture.model
        model.select(fixture.photos[120])
        try await fixture.eventually { model.info?.url == fixture.photos[120] }
        try await Task.sleep(for: .milliseconds(200))
        let steps = 60
        let held = try await hold(model, steps: steps, interval: Self.keyRepeat) {
            let preview = model.selection.flatMap(model.previews.cached)
            return (
                !model.hasFrame && model.selectionThumbnail == nil,
                preview != nil && model.selectionThumbnail === preview,
            )
        }
        print("Develop, → held at \(Int(Self.keyRepeat * 1000)) ms: \(held.blank) blank frames in \(steps) steps, "
            + "\(held.previews) previews on screen a frame after their photo was reached")
        #expect(model.module == .develop && model.selection == fixture.photos[120 + steps])
        #expect(held.blank == 0, "\(held.blank) blank frames")
        #expect(held.previews >= steps / 4, "\(held.previews) of \(steps) previews were read ahead")
    }

    @Test(.measuresSpeed)
    func `→ held at 120 Hz in the loupe, faster than previews decode, still never shows a blank frame`()
        async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        try await fixture.open(count: 300)
        let model = fixture.model
        let loupe = try #require(fixture.content?.library.loupe)
        model.showLibrary(.loupe)
        model.click(fixture.photos[100])
        try await fixture.eventually { loupe.showsPreview }
        try await Task.sleep(for: .milliseconds(200))
        let held = try await hold(model, steps: 60, interval: Self.frame) { (loupe.image == nil, loupe.showsPreview) }
        print("Loupe, → held at 120 Hz: \(held.blank) blank frames in 60 steps")
        #expect(held.blank == 0, "\(held.blank) blank frames")
        try await fixture.eventually { loupe.showsPreview }
        #expect(loupe.showsPreview, "the photo where the key stopped shows its preview")
    }

    @Test func `a switch of module reads no previews, and a click elsewhere reads only thumbnails`() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        try await fixture.open(count: 40)
        let model = fixture.model
        try await Task.sleep(for: .milliseconds(300))
        let before = fixture.previewed.all
        for index in 0 ..< 10 {
            model.showModule(index.isMultiple(of: 2) ? .library : .develop)
            try await Task.sleep(for: .milliseconds(20))
        }
        model.showModule(.library)
        model.showLibrary(.loupe)
        model.click(fixture.photos[30])
        try await Task.sleep(for: .milliseconds(300))
        let read = fixture.previewed.all.dropFirst(before.count)
        #expect(Set(read).isSubset(of: [fixture.photos[0], fixture.photos[30]]), "previews read: \(read)")
        for photo in fixture.photos[27 ... 33] {
            let item = try #require(model.library.item(for: photo))
            #expect(model.thumbnailLoader.hasThumbnail(item), "\(photo.lastPathComponent)'s thumbnail wasn't read")
        }
    }

    // MARK: - Previews, latest wins

    @Test func `a read ahead that's no longer wanted is dropped unless it has started, and its result isn't kept`()
        async throws {
        let gate = BlockingGate()
        let (started, decoded) = (Record<String>(), Record<String>())
        let scheduler = WorkScheduler(widths: .init(onScreen: 1, lookAhead: 1, background: 1))
        let previews = PhotoPreviews(scheduler: scheduler, decode: { url, size in
            started.append(url.lastPathComponent)
            gate.pass()
            decoded.append(url.lastPathComponent)
            return ModuleFixture.image(min(size, 300))
        })
        let folder = URL(fileURLWithPath: "/nowhere")
        let items = ["A", "B", "C", "D"].map { LibraryItem(url: folder.appending(path: "\($0).ARW")) }
        let deadline = ContinuousClock.now + .seconds(10)
        func waitUntilStarted(_ name: String) async throws {
            while !started.all.contains(name), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        gate.hold()
        previews.prefetch([items[0], items[1]])
        try await waitUntilStarted("A.ARW")
        previews.prefetch([items[2]])
        #expect(!previews.isDecoding(items[1].url), "B hadn't started, so it's dropped")
        gate.release()
        while previews.cached(items[2].url) == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(previews.cached(items[2].url) != nil)
        #expect(previews.cached(items[0].url) == nil, "A finished after it stopped being wanted")
        #expect(decoded.all == ["A.ARW", "C.ARW"])

        gate.hold()
        previews.prefetch([items[3]])
        try await waitUntilStarted("D.ARW")
        var shown: CGImage?
        previews.request(items[3]) { shown = $0 }
        gate.release()
        while shown == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(
            shown != nil && decoded.all.count(where: { $0 == "D.ARW" }) == 1,
            "asking for a preview being read ahead waits for that decode",
        )
    }
}
