#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import Carbon.HIToolbox
    import RedlampEngineAPI
    @_spi(Harness) import RedlampUI

    /// Compare (C) and Survey (N) in the Library module (LIB-16), worked by keys and clicks on the working folder's
    /// grid from the library, its culling taken back after.
    enum CompareScenarios {
        static let all: [Scenario] = [compare, survey]

        private static let ratings: [ShortcutAction] = [.rating0, .rating1, .rating2, .rating3, .rating4, .rating5]

        /// Compare's select and candidate, by name.
        @MainActor private static func compared(_ model: EditorModel) -> [String] {
            [model.libraryCompare.select, model.libraryCompare.candidate].map { $0?.lastPathComponent ?? "-" }
        }

        @MainActor private static func firstResponder() -> String {
            Views.editorWindow?.firstResponder.map { "\(Swift.type(of: $0))" } ?? ""
        }

        private static func arrow(_ key: Int) -> String {
            UnicodeScalar(key).map(String.init) ?? ""
        }

        static let compare = Scenario(
            "library.compare",
            "C shows the active photo beside the next as the select and the candidate: ← and → change the candidate, ↓ "
                + "swaps them and ↑ makes the candidate the select; a click makes the candidate active and a rating "
                + "reaches it alone; Z zooms the two together until the lock unlinks them; E and G go back",
            claims: [
                .action(.compareView), .action(.nextPhoto), .action(.previousPhoto), .action(.toggleZoom),
                .feature("library.ratings"),
            ],
        ) { app in
            try app.withCulling { _ in
                let cells = try app.gridCells()
                try app.expect(cells.count >= 4, "The grid has \(cells.count) cells")
                let (first, second, third) = (cells[0][0], cells[1][0], cells[2][0])
                try app.click(.identifier("grid.\(first)"))
                try app
                    .wait("\(first)'s cell alone") { Set($0.selectedPhotos.map(\.lastPathComponent)) == Set(cells[0]) }
                try app.press(.compareView)
                try app.wait("Compare") { $0.libraryView == .compare }
                try app.expect(try app.exists(.identifier("library.compare")), "Compare isn't on screen")
                try app.wait("\(first) beside \(second)") { compared($0) == [first, second] }
                try app.wait("Compare to take the keyboard") { _ in firstResponder() == "LibraryCompareView" }
                try app.wait("both photos shown") { _ in
                    ["select", "candidate"].allSatisfy { side in
                        Views.editorWindow.flatMap { Views.find("library.compare.\(side)", in: $0) } != nil
                    }
                }
                try app.expect(
                    try app.main { Set($0.selectedPhotos.map(\.lastPathComponent)) } == Set(cells[0] + cells[1]),
                    "Both cells aren't selected",
                )

                try app.press(.nextPhoto)
                try app.wait("→: \(third) the candidate") { compared($0) == [first, third] }
                try app.press(.previousPhoto)
                try app.wait("←: \(second) the candidate again") { compared($0) == [first, second] }
                try app.pressGridKey(kVK_DownArrow, characters: arrow(NSDownArrowFunctionKey))
                try app.wait("↓: the two swapped") { compared($0) == [second, first] }
                try app.pressGridKey(kVK_DownArrow, characters: arrow(NSDownArrowFunctionKey))
                try app.wait("↓ again: back") { compared($0) == [first, second] }
                try app.pressGridKey(kVK_UpArrow, characters: arrow(NSUpArrowFunctionKey))
                try app.wait("↑: \(second) the select, \(third) the candidate") { compared($0) == [second, third] }
                try app.expect(try app.main { $0.selection?.lastPathComponent } == second, "The select isn't active")

                try app.click(.identifier("library.compare.candidate"))
                try app.wait("a click: the candidate active") { $0.selection?.lastPathComponent == third }
                let kept = try app.shown(second).rating
                let stars = try app.shown(third).rating == 4 ? 2 : 4
                try app.press(ratings[stars])
                try app.wait("\(stars) stars on \(third)'s photos alone") { model in
                    let shown = CullingScenarios.ratings(of: cells[1] + cells[2], in: model)
                    return cells[2].allSatisfy { shown[$0] == stars } && cells[1].allSatisfy { shown[$0] == kept }
                }
                try app.waitWritten()
                app.covered(.feature("library.ratings"), via: .key)

                try app.press(.toggleZoom)
                try app.wait("Z: both at 1:1") { model in
                    model.compareZoom(of: .select).zoom == .actual && model.compareZoom(of: .candidate).zoom == .actual
                }
                try app.clickView("library.compare.link")
                try app.wait("the lock: unlinked") { !$0.libraryCompare.isLinked }
                try app.press(.toggleZoom)
                try app.wait("Z unlinked: the candidate alone fits") { model in
                    model.compareZoom(of: .candidate).zoom == .fit && model.compareZoom(of: .select).zoom == .actual
                }
                try app.clickView("library.compare.link")
                try app.wait("the lock again: both fit") { model in
                    model.libraryCompare.isLinked && model.compareZoom(of: .select).zoom == .fit
                }

                try app.press(.loupeView)
                try app.wait("E: the candidate in the loupe") { model in
                    model.libraryView == .loupe && model.selection?.lastPathComponent == third
                }
                try app.press(.compareView)
                try app.wait("C again") { $0.libraryView == .compare && compared($0) == [third, second] }
                try app.press(.gridView)
                try app.wait("G: the grid") { $0.libraryView == .grid }
                try app.main { $0.deselectOtherPhotos() }
            }
        }

        static let survey = Scenario(
            "library.survey",
            "N lays out the photos selected, the active one marked: ← and → move between them, a click makes another "
                + "active and a rating reaches it alone, and a photo's × takes it out of the selection while Survey "
                + "stays; Esc goes back to the grid",
            claims: [.action(.surveyView), .action(.nextPhoto), .action(.previousPhoto), .feature("library.ratings")],
        ) { app in
            try app.withCulling { _ in
                let cells = try app.selectFromKeyboard(4)
                let shown = cells.prefix(4).map { $0[0] }
                try app.press(.surveyView)
                try app.wait("Survey") { $0.libraryView == .survey }
                try app.expect(try app.exists(.identifier("library.survey")), "Survey isn't on screen")
                try app.wait("the four cells' photos laid out") { $0.surveyPhotos.map(\.lastPathComponent) == shown }
                try app.wait("Survey to take the keyboard") { _ in firstResponder() == "LibrarySurveyView" }
                try app.wait("each photo on screen") { _ in
                    shown
                        .allSatisfy { name in
                            Views.editorWindow.flatMap { Views.find("survey.\(name)", in: $0) } != nil
                        }
                }
                try app.expect(
                    try app.main { $0.surveyActivePhoto?.lastPathComponent } == shown[3],
                    "The last isn't active",
                )

                try app.press(.previousPhoto)
                try app.wait("←: \(shown[2]) active") { $0.surveyActivePhoto?.lastPathComponent == shown[2] }
                try app.press(.nextPhoto)
                try app.wait("→: \(shown[3]) active") { $0.surveyActivePhoto?.lastPathComponent == shown[3] }
                try app.click(.identifier("survey.\(shown[1])"))
                try app.wait("a click: \(shown[1]) active") { $0.surveyActivePhoto?.lastPathComponent == shown[1] }

                let others = cells[0] + cells[2]
                let kept = try others.map { try app.shown($0).rating }
                let stars = try app.shown(shown[1]).rating == 4 ? 2 : 4
                try app.press(ratings[stars])
                try app.wait("\(stars) stars on \(shown[1])'s photos alone") { model in
                    let rated = CullingScenarios.ratings(of: cells[1] + others, in: model)
                    return cells[1].allSatisfy { rated[$0] == stars } && others.map { rated[$0] ?? -1 } == kept
                }
                try app.waitWritten()
                app.covered(.feature("library.ratings"), via: .key)

                try app.clickView("survey.remove.\(shown[1])")
                try app.wait("×: \(shown[1]) out of the selection, Survey staying") { model in
                    model.libraryView == .survey && !model.selectedPhotos
                        .contains { cells[1].contains($0.lastPathComponent) }
                        && model.surveyPhotos.map(\.lastPathComponent) == [shown[0], shown[2], shown[3]]
                }
                try app.expect(
                    try app.main { $0.surveyActivePhoto?.lastPathComponent } == shown[2],
                    "\(shown[2]) isn't active",
                )
                try app.press(KeyCombo(.escape))
                try app.wait("Esc: the grid") { $0.libraryView == .grid }
                try app.main { $0.deselectOtherPhotos() }
            }
        }
    }
#endif
