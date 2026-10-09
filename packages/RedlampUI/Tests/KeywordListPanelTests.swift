import AppKit
import RedlampDesign
import RedlampLibrary
import Testing
@_spi(Harness) @testable import RedlampUI

/// The Keyword List panel as its keywords change (LIB-21): a keyword that appears in the list or leaves it, as a
/// painter's stroke or its Undo makes one, is put in or taken out of the outline where it goes, the rows open staying
/// open, the column laid out again only when the panel's height changes, within a frame at thousands of keywords.
@MainActor
@Suite(.serialized)
struct KeywordListPanelTests {
    /// The top of a column, counting the times its content asks to be laid out again.
    final class Host: NSView, ColumnHost {
        var laidOut = 0

        func columnContentDidChange() {
            laidOut += 1
        }
    }

    /// The panel in a window, its keywords `paths`, each on one photo.
    @MainActor
    final class Panel {
        let model = EditorModel(engine: StubEngine())
        let host = Host(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 400), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        let view: KeywordListPanelView

        init(_ paths: [String]) {
            model.showModule(.library)
            view = KeywordListPanelView(model: model, panels: model.libraryPanels)
            view.frame = host.bounds
            show(paths)
            host.addSubview(view)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
        }

        func show(_ paths: [String]) {
            model.libraryPanels.keywords = Self.keywords(paths)
        }

        /// The keywords `paths` as the library reads them, off the main thread in the app.
        static func keywords(_ paths: [String]) -> PanelKeywords {
            var counts: [KeywordPath: KeywordCount] = [:]
            for path in paths {
                counts[KeywordPath(path)!] = KeywordCount(photos: 1, count: 1)
            }
            let list = KeywordList(counts: counts, definitions: KeywordDefinitions())
            let set = KeywordSet(name: KeywordSet.recentName, keywords: [])
            return PanelKeywords(list: list, completion: KeywordCompletion(list), sets: [set], active: set)
        }

        var outline: NSOutlineView {
            func find(_ view: NSView) -> NSOutlineView? {
                view as? NSOutlineView ?? view.subviews.lazy.compactMap(find).first
            }
            return find(view)!
        }

        /// The keywords of the outline's rows, in order.
        var rows: [String] {
            (0 ..< outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? KeywordNode)?.path.text }
        }

        /// Shows `paths` and waits, turn by turn, until the outline has `rows` rows: how long that took from the list
        /// read. The panel hears of the list in a turn of its own, which the first turns waited leave it.
        func change(to paths: [String], rows count: Int) async -> Duration {
            let keywords = Self.keywords(paths)
            let clock = ContinuousClock()
            let start = clock.now
            model.libraryPanels.keywords = keywords
            for _ in 0 ..< 3 {
                await Task.yield()
            }
            while outline.numberOfRows != count, clock.now - start < .seconds(10) {
                await Task.yield()
            }
            return clock.now - start
        }
    }

    @Test func `a keyword that appears or leaves is put in or taken out in place, the column laid out only for the panel's height`(
    ) async {
        let panel = Panel(["Family", "Places/Portugal/Lisbon", "Places/Spain/Madrid"])
        let outline = panel.outline
        #expect(panel.rows == ["Family", "Places"])
        outline.expandItem(outline.item(atRow: 1), expandChildren: true)
        #expect(panel.rows == [
            "Family",
            "Places",
            "Places/Portugal",
            "Places/Portugal/Lisbon",
            "Places/Spain",
            "Places/Spain/Madrid",
        ])
        panel.host.laidOut = 0

        _ = await panel.change(
            to: ["Family", "Places/Portugal/Lisbon", "Places/Portugal/Porto", "Places/Spain/Madrid", "Zoo"], rows: 8,
        )
        #expect(panel.rows == [
            "Family",
            "Places",
            "Places/Portugal",
            "Places/Portugal/Lisbon",
            "Places/Portugal/Porto",
            "Places/Spain",
            "Places/Spain/Madrid",
            "Zoo",
        ])
        _ = await panel.change(to: ["Places/Portugal/Porto", "Places/Spain/Madrid"], rows: 5)
        #expect(panel.rows == [
            "Places",
            "Places/Portugal",
            "Places/Portugal/Porto",
            "Places/Spain",
            "Places/Spain/Madrid",
        ], "the rows open stay open")
        #expect(panel.host.laidOut == 0, "the panel's height didn't change")

        // Inside a keyword open within one closed: shown as the closed one opens.
        outline.collapseItem(outline.item(atRow: 0))
        _ = await panel.change(to: ["Places/Portugal/Faro", "Places/Portugal/Porto", "Places/Spain/Madrid"], rows: 1)
        outline.expandItem(outline.item(atRow: 0))
        #expect(panel.rows == [
            "Places",
            "Places/Portugal",
            "Places/Portugal/Faro",
            "Places/Portugal/Porto",
            "Places/Spain",
            "Places/Spain/Madrid",
        ])
        _ = await panel.change(to: ["Places/Portugal/Faro", "Places/Spain/Madrid"], rows: 5)
        #expect(panel.rows == [
            "Places",
            "Places/Portugal",
            "Places/Portugal/Faro",
            "Places/Spain",
            "Places/Spain/Madrid",
        ])

        _ = await panel.change(to: [], rows: 0)
        #expect(panel.host.laidOut == 1, "No keywords yet shown")
        _ = await panel.change(to: ["Family"], rows: 1)
        #expect(panel.rows == ["Family"] && panel.host.laidOut == 2)
    }

    @Test(.measuresSpeed)
    func `a keyword that appears in a list of thousands, or leaves it, is shown within a frame`() async {
        let base = (0 ..< 3000).map { String(format: "Keyword %04d", $0) } + ["Places/Portugal/Lisbon"]
        let panel = Panel(base)
        #expect(panel.outline.numberOfRows == 3001)
        var times: [Duration] = []
        for round in 0 ..< 5 {
            let painted = "Zebra \(round)"
            await times.append(panel.change(to: base + [painted], rows: 3002))
            #expect(panel.rows.last == painted)
            await times.append(panel.change(to: base, rows: 3001))
        }
        times.sort()
        #expect(times[times.count / 2] < .milliseconds(8), "\(times)")
    }

    @Test(.measuresSpeed)
    func `a keyword that appears among the rows on screen, or leaves them, is shown within a frame`() async {
        let base = (0 ..< 40).map { String(format: "Keyword %02d", $0) }
        let panel = Panel(base)
        #expect(panel.outline.numberOfRows == 40)
        var times: [Duration] = []
        for round in 0 ..< 5 {
            let painted = "Aardvark \(round)"
            await times.append(panel.change(to: base + [painted], rows: 41))
            #expect(panel.rows.first == painted)
            await times.append(panel.change(to: base, rows: 40))
        }
        times.sort()
        #expect(times[times.count / 2] < .milliseconds(8), "\(times)")
    }

    @Test func `a panel's height is worked out again only once it says its rows changed`() {
        let panel = PanelStackView()
        let rows = (0 ..< 3).map { PanelControls.label("Row \($0)") }
        rows.forEach(panel.addFullWidth)
        let height = panel.height(forWidth: 280)
        rows[2].isHidden = true
        #expect(panel.height(forWidth: 280) == height, "kept while another panel's change lays the column out")
        panel.rowsChanged()
        #expect(panel.height(forWidth: 280) < height)
    }
}
