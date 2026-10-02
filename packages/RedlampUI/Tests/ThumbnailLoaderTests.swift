import CoreGraphics
import Foundation
import RedlampDocument
import Synchronization
import Testing
@testable import RedlampUI

/// Thumbnails: shared decodes, the memory budget, the packs, cancellation and warming.
@MainActor
struct ThumbnailLoaderTests {
    /// The photos decoded, in order.
    private final class Decodes: Sendable {
        private let names = Mutex<[String]>([])

        var all: [String] {
            names.withLock { $0 }
        }

        func append(_ name: String) {
            names.withLock { $0.append(name) }
        }

        func reset() {
            names.withLock { $0 = [] }
        }
    }

    private let directory = FileManager.default.temporaryDirectory.appending(path: "loader-\(UUID().uuidString)")
    private let decodes = Decodes()

    private func loader(budget: Int = 128 << 20, packs: ThumbnailPacks? = nil) -> ThumbnailLoader {
        let decodes = decodes
        return ThumbnailLoader(
            scheduler: WorkScheduler(widths: .machine, canRunBackground: { true }),
            packs: packs ?? ThumbnailPacks(directory: directory),
            budget: budget,
        ) { url, size in
            decodes.append(url.lastPathComponent)
            return Self.image(width: size, height: size * 2 / 3)
        }
    }

    private nonisolated static func image(width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        ) else { return nil }
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func item(_ name: String, local: Bool = true) -> LibraryItem {
        var item = LibraryItem(url: URL(fileURLWithPath: "/Photos/\(name)"))
        item.size = 100
        item.modified = Date(timeIntervalSinceReferenceDate: 800_000_000)
        item.isLocal = local
        return item
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 400 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func `requests for one photo share a decode, at the cell's size`() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let loader = loader()
        let photo = item("A.ARW")
        async let first = loader.image(for: photo)
        async let second = loader.image(for: photo)
        let images = await [first, second]
        #expect(images.allSatisfy { $0?.width == ThumbnailLoader.pixelSize })
        #expect(decodes.all == ["A.ARW"])
        #expect(loader.cached(photo) != nil)
    }

    @Test func `a thumbnail comes back from the pack without decoding the photo`() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let photo = item("A.ARW")
        _ = await loader().image(for: photo)
        let fresh = loader()
        #expect(await fresh.image(for: photo) != nil)
        #expect(decodes.all == ["A.ARW"], "the second loader read the pack")
    }

    @Test func `photos iCloud Drive hasn't downloaded are never read`() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(await loader().image(for: item("A.ARW", local: false)) == nil)
        #expect(decodes.all.isEmpty)
    }

    @Test func `memory stays within the budget, keeping what's on screen`() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let cost = ThumbnailLoader.pixelSize * 4 * (ThumbnailLoader.pixelSize * 2 / 3)
        let loader = loader(budget: cost * 4)
        let first = item("0.ARW")
        loader.protected = [first.url]
        for index in 0 ..< 10 {
            _ = await loader.image(for: item("\(index).ARW"))
        }
        #expect(loader.memoryUsed <= cost * 4)
        #expect(loader.cached(first) != nil, "on screen")
        #expect(loader.cached(item("1.ARW")) == nil, "the oldest went first")
        #expect(loader.cached(item("9.ARW")) != nil)

        loader.trim(to: 0)
        #expect(loader.memoryUsed == cost)
    }

    @Test func `memory never passes the budget, whichever lanes ask`() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let cost = ThumbnailLoader.pixelSize * 4 * (ThumbnailLoader.pixelSize * 2 / 3)
        let loader = loader(budget: cost * 6)
        let lanes: [WorkScheduler.Lane] = [.onScreen, .lookAhead, .background]
        var highest = 0
        var remaining = 40
        for index in 0 ..< 40 {
            loader.request(item("\(index).ARW"), lane: lanes[index % 3]) { _ in
                highest = max(highest, loader.memoryUsed)
                remaining -= 1
            }
        }
        try await eventually { remaining == 0 }
        #expect(remaining == 0)
        #expect(highest <= cost * 6)
    }

    @Test func `a thumbnail kept in memory is decoded again from its pack JPEG`() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let decoded = Mutex<CGImage?>(nil)
        let loader = ThumbnailLoader(
            scheduler: WorkScheduler(),
            packs: ThumbnailPacks(directory: directory),
        ) { _, size in
            let image = Self.image(width: size, height: size * 2 / 3)
            decoded.withLock { $0 = image }
            return image
        }
        let image = try #require(await loader.image(for: item("A.ARW")))
        let bitmap = try #require(decoded.withLock { $0 })
        // ImageIO keeps a JPEG's decoded pixels in purgeable memory, which doesn't count against
        // the app; the preview's bitmap would.
        #expect(image !== bitmap)
        #expect(image.width == bitmap.width && image.height == bitmap.height)
    }

    @Test func `no more decodes run at once than the scheduler's lanes allow`() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let running = Atomic(0)
        let peak = Atomic(0)
        let packs = ThumbnailPacks(directory: directory)
        let widths = WorkScheduler.Widths(onScreen: 3, lookAhead: 2, background: 1)
        let loader = ThumbnailLoader(
            scheduler: WorkScheduler(widths: widths, canRunBackground: { true }), packs: packs,
        ) { _, size in
            _ = peak.max(running.add(1, ordering: .relaxed).newValue, ordering: .relaxed)
            usleep(2000)
            running.subtract(1, ordering: .relaxed)
            return Self.image(width: size, height: size * 2 / 3)
        }
        let photos = (0 ..< 36).map { item("\($0).ARW") }
        loader.warm(Array(photos[24...]))
        for (index, photo) in photos[..<24].enumerated() {
            loader.request(photo, lane: index.isMultiple(of: 2) ? .onScreen : .lookAhead) { _ in }
        }
        try await eventually { photos.allSatisfy { packs.contains($0.url, size: $0.size, modified: $0.modified) } }
        #expect(photos.allSatisfy { packs.contains($0.url, size: $0.size, modified: $0.modified) })
        #expect(peak.load(ordering: .relaxed) <= widths.onScreen + widths.lookAhead + widths.background)
    }

    @Test func `a cancelled request completes empty and its decode is dropped`() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = DispatchSemaphore(value: 0)
        let scheduler = WorkScheduler(widths: .init(onScreen: 1, lookAhead: 1, background: 1))
        let loader = ThumbnailLoader(scheduler: scheduler, packs: ThumbnailPacks(directory: directory)) { url, size in
            if url.lastPathComponent == "block" {
                gate.wait()
            }
            return Self.image(width: size, height: size)
        }
        loader.request(item("block")) { _ in }
        var result: CGImage?? = .none
        let id = loader.request(item("B.ARW"), lane: .onScreen) { result = .some($0) }
        loader.cancel(id)
        #expect(result == .some(nil))
        gate.signal()
        try await Task.sleep(for: .milliseconds(50))
        #expect(loader.cached(item("B.ARW")) == nil)
    }

    @Test func `warming fills the pack without holding thumbnails in memory`() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let packs = ThumbnailPacks(directory: directory)
        let loader = loader(packs: packs)
        let photos = (0 ..< 20).map { item("\($0).ARW") }
        loader.warm(photos)
        try await eventually { photos.allSatisfy { packs.contains($0.url, size: $0.size, modified: $0.modified) } }
        #expect(photos.allSatisfy { packs.contains($0.url, size: $0.size, modified: $0.modified) })
        #expect(loader.memoryUsed == 0)

        decodes.reset()
        loader.warm(photos)
        try await eventually { loader.warmingRemaining == 0 }
        try await Task.sleep(for: .milliseconds(30))
        #expect(decodes.all.isEmpty, "already in the pack")
    }
}
