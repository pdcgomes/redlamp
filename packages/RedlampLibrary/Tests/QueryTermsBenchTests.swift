import Foundation
import Testing
@testable import RedlampLibrary

/// `is:damaged` searched and the palette's terms completed on a copy of a large library's index (LIB-40, LIB-19):
/// skipped unless `REDLAMP_TERMS_BENCH_INDEX` names the copy's `Index.sqlite`, which xcodebuild hands to the tests from
/// `TEST_RUNNER_REDLAMP_TERMS_BENCH_INDEX`. The damaged files are those the copy's `photo_health` holds. Budgets, a
/// Release build's: a search's first page and count p95 under 16 ms; a completion p95 under 2 ms a keystroke.
struct QueryTermsBenchTests {
    /// The palette's fields when nothing names one: the library's names, then the terms' (`CommandPaletteModel`).
    static let paletteFields: [LibraryQuery.Field] = [
        .folder, .collection, .keyword, .camera, .lens, .city, .country, .state, .sublocation, .label, .trait,
        .orientation,
    ]

    private static func report(_ line: String) {
        print("TERMS-BENCH \(line)")
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        duration / .milliseconds(1)
    }

    /// p50, p95 and the slowest, in milliseconds.
    private static func spread(_ durations: [Duration]) -> String {
        let sorted = durations.sorted()
        func at(_ fraction: Double) -> Double {
            milliseconds(sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))])
        }
        return String(format: "p50 %.2f ms, p95 %.2f ms, max %.2f ms over %ld", at(0.5), at(0.95), at(1), sorted.count)
    }

    /// `text` as it's typed, a character at a time.
    private static func typed(_ text: String) -> [String] {
        (1 ... text.count).map { String(text.prefix($0)) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["REDLAMP_TERMS_BENCH_INDEX"] != nil))
    func `is:damaged and the palette's terms on a large library's index`() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["REDLAMP_TERMS_BENCH_INDEX"])
        let index = try await LibraryIndex.open(at: URL(fileURLWithPath: path))
        defer { index.closeAndWait() }
        let clock = ContinuousClock()
        let damaged = try LibraryQuery(parsing: "is:damaged")

        // The term's first search in each store, the damaged check worked out for it, then again from what's kept.
        var firsts: [Duration] = []
        var again: [Duration] = []
        var lists: [Duration] = []
        var found = 0
        for _ in 1 ... 5 {
            let engine = QueryEngine(index: index, saving: nil)
            try await engine.load()
            var started = clock.now
            found = try await engine.results(damaged).last?.count ?? 0
            firsts.append(clock.now - started)
            for _ in 1 ... 20 {
                started = clock.now
                _ = try await engine.results(damaged)
                again.append(clock.now - started)
            }
            started = clock.now
            _ = try await engine.list(.allPhotographs, matching: damaged)
            lists.append(clock.now - started)
        }
        Self.report("is:damaged finds \(found) photos")
        Self.report("is:damaged, the first search in a store: \(Self.spread(firsts))")
        Self.report("is:damaged, searched again: \(Self.spread(again))")
        Self.report("All Photographs filtered by is:damaged: \(Self.spread(lists))")

        // Typed a character at a time, as the filter bar's text and the palette's search are.
        let engine = QueryEngine(index: index, saving: nil)
        try await engine.load()
        var keys: [Duration] = []
        for text in ["is:damaged", "is:damaged rating>=3", "-is:damaged flag:pick", "is:damaged type:raw"] {
            for typed in Self.typed(text) {
                let started = clock.now
                _ = try await engine.results(LibraryQuery(parsing: typed, asYouType: true))
                keys.append(clock.now - started)
            }
        }
        Self.report("searches as is:damaged's queries are typed: \(Self.spread(keys))")

        // The palette's completions, a key at a time: the first in the store counts each trait and orientation
        // found, then from what's kept.
        let palette = QueryEngine(index: index, saving: nil)
        try await palette.load()
        var started = clock.now
        let traits = await palette.values(of: .trait)
        Self.report("is: listing every trait, counted, the first time: \(Self.milliseconds(clock.now - started)) ms")
        Self.report("traits: \(traits.map { "\($0.value) \($0.count ?? -1)" }.joined(separator: ", "))")
        started = clock.now
        _ = await palette.values(of: .trait)
        Self.report("is: again: \(Self.milliseconds(clock.now - started)) ms")
        var completions: [Duration] = []
        let texts = ["damaged files", "unreadable", "unpicked moment", "landscape", "lisbon", "portugal", "red"]
        let fielded: [(LibraryQuery.Field, String)] = [(.trait, "damaged"), (.label, "purple"), (.orientation, "po")]
        for round in 1 ... 3 {
            var times: [Duration] = []
            for text in texts {
                for typed in Self.typed(text) {
                    let started = clock.now
                    _ = await palette.completions(typed, fields: Self.paletteFields, limit: 8)
                    times.append(clock.now - started)
                }
            }
            for (field, text) in fielded {
                for typed in Self.typed(text) {
                    let started = clock.now
                    _ = await palette.completions(typed, fields: [field], limit: 8)
                    times.append(clock.now - started)
                }
            }
            Self.report("palette completions, round \(round): \(Self.spread(times))")
            if round > 1 {
                completions += times
            }
        }
        Self.report("palette completions once counted: \(Self.spread(completions))")
        #expect(found > 0)
    }
}
