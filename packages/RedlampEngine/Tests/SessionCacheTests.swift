import Foundation
import Metal
import Synchronization
import Testing
@testable import RedlampEngine

/// The decoded photos the engine keeps ready: all they hold counts against the budget, prefetches
/// stay within it, and memory pressure lets them go.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct SessionCacheTests {
    static let urls = (0 ..< 4).map { URL(fileURLWithPath: "/photos/\($0).dng") }

    /// How many decodes are running.
    final class Decodes: Sendable {
        let running = Mutex(0)
    }

    let sessions: [URL: ImageSession]

    init() throws {
        let helpers = try DetailStageTests()
        var sessions: [URL: ImageSession] = [:]
        for url in Self.urls {
            sessions[url] = try helpers.makeSession(.bayer, width: 640, height: 480)
        }
        self.sessions = sessions
    }

    /// Everything a session holds: each of its textures once, and its analysis copy.
    private func held(_ session: ImageSession) -> Int {
        var textures: [any MTLTexture] = [
            session.pyramid, session.hazeMap, session.refinedHaze, session.toneBase, session.clarityBase,
            session.glowSource, session.glowLights, session.noiseGain,
        ]
        textures += [session.hueSatMaps?.cool, session.hueSatMaps?.warm, session.gainTableMap?.texture]
            .compactMap(\.self)
        var seen = Set<ObjectIdentifier>()
        return textures.filter { seen.insert(ObjectIdentifier($0)).inserted }.map(\.allocatedSize).reduce(0, +)
            + session.analysis.pixels.withUnsafeBytes(\.count)
    }

    private func held(_ index: Int) throws -> Int {
        try held(#require(sessions[Self.urls[index]]))
    }

    private func cache(budget: Int, building: Decodes) -> SessionCache {
        SessionCache(budget: budget) { [sessions] url in
            building.running.withLock { $0 += 1 }
            defer { building.running.withLock { $0 -= 1 } }
            guard let session = sessions[url] else { throw CancellationError() }
            return session
        }
    }

    /// Waits for the decodes `cache` started to finish and be cached.
    private func settle(_ building: Decodes) async throws {
        for _ in 0 ..< 500 where building.running.withLock({ $0 }) > 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
    }

    private func cachedIndices(_ cache: SessionCache) -> [Int] {
        Self.urls.indices.filter { cache.cached(Self.urls[$0]) != nil }
    }

    @Test func `the budget counts a photo's maps and analysis copy, not only its pyramid`() async throws {
        let building = Decodes()
        let cache = cache(budget: 1 << 40, building: building)
        _ = try await cache.session(for: Self.urls[0])
        let expected = try held(0)
        #expect(cache.bytesCached == expected)
    }

    /// Every photo kept ready holds its analysis copy, so the copy takes no padding.
    @Test func `a photo's analysis copy takes 12 bytes a pixel`() throws {
        let analysis = try #require(sessions[Self.urls[0]]).analysis
        #expect(analysis.pixels.withUnsafeBytes(\.count) == analysis.width * analysis.height * 12)
    }

    @Test func `prefetches stay within the budget, the photo being opened first`() async throws {
        let size = try held(0)
        for (budget, kept) in [(size * 5 / 2, [0, 1]), (size / 2, [0])] {
            let building = Decodes()
            let cache = cache(budget: budget, building: building)
            cache.prefetch(Self.urls)
            try await settle(building)
            #expect(cachedIndices(cache) == kept)
            #expect(cache.bytesCached <= max(budget, size))
        }
    }

    @Test func `memory pressure lets go of photos not wanted, then of all but the one open`() async throws {
        let building = Decodes()
        let cache = cache(budget: 1 << 40, building: building)
        _ = try await cache.session(for: Self.urls[3])
        cache.prefetch(Array(Self.urls.prefix(3)))
        try await settle(building)
        #expect(cachedIndices(cache) == [0, 1, 2, 3])
        cache.relieve(DispatchSource.MemoryPressureEvent.warning)
        #expect(cachedIndices(cache) == [0, 1, 2])
        cache.relieve(DispatchSource.MemoryPressureEvent.critical)
        let expected = try held(0)
        #expect(cachedIndices(cache) == [0])
        #expect(cache.bytesCached == expected)
    }
}
