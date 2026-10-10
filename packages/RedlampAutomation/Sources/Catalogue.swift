#if DEBUG || REDLAMP_PROFILING
    import Foundation
    import RedlampEngineAPI
    @_spi(Harness) import RedlampUI

    /// Every scenario, and every claim the contract requires a scenario (or an exemption) for.
    public enum Catalogue {
        public static let all: [Scenario] = SmokeScenarios.all
            + DevelopScenarios.all + ViewingScenarios.all + WorkspaceScenarios.all + HistoryScenarios.all
            + MaskingScenarios.all + MasksPanelScenarios.all + PointColorScenarios.all + CropScenarios.all
            + HealingScenarios.all
            + LibraryScenarios.all + ModuleScenarios.all + OtherAppsScenarios.all + SavingScenarios.all
            + PaletteLibraryScenarios.all
            + SourceScenarios.all
            + GroupScenarios.all
            + LibraryStackScenarios.all
            + SyncScenarios.all + ExportScenarios.all
            + RecipeScenarios.all + StackScenarios.all + RawScenarios.all + FeedbackScenarios.all
            + ImportScenarios.all
            + LightroomScenarios.all
            + LibraryPanelScenarios.all
            + HealthScenarios.all
            + MissingPhotosScenarios.all
            + CollectionScenarios.all
            + PanelScenarios.all
            + RenameScenarios.all
            + MoveEditsScenarios.all
            + DragScenarios.all
            + MenuBarScenarios.all
            + ShortcutScenarios.all
            + ForeignInputScenarios.all
            + SoakScenarios.all + PerformanceScenarios.all + PanelPerformanceScenarios.all
            + LibrarySourcesPerformanceScenarios.all
            + DragPerformanceScenarios.all
            + StackPerformanceScenarios.all
            + GroupPerformanceScenarios.all
            + HealthPerformanceScenarios.all
            + MenuPerformanceScenarios.all
            + ArrowPartsScenarios.all
            + SmokeScenarios.last

        /// What the app offers, from its own catalogues: every action, parameter, panel, left
        /// panel, tool, mask kind and Report a Bug feature.
        @MainActor
        public static var required: [Claim] {
            ShortcutAction.allCases.map(Claim.action)
                + ParameterID.allCases.map(Claim.parameter)
                + PanelID.allCases.map(Claim.panel)
                + SidebarSection.allCases.map(Claim.section)
                + EditTool.allCases.map(Claim.tool)
                + MaskKind.allCases.map(Claim.mask)
                + FeedbackArea.catalog.flatMap(\.features).map { Claim.feature($0.id) }
        }

        @MainActor
        static func json() throws -> Data {
            let scenarios: [[String: Any]] = all.map { scenario in
                [
                    "id": scenario.id,
                    "title": scenario.title,
                    "tiers": scenario.tiers.map(\.rawValue).sorted(),
                    "group": scenario.group.rawValue,
                    "claims": scenario.claims.map(\.description),
                    "needsFocus": scenario.needsFocus,
                ]
            }
            let object: [String: Any] = [
                "format": "app.redlamp.e2e-catalogue",
                "scenarios": scenarios,
                "required": required.map(\.description),
            ]
            return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        }
    }
#endif
