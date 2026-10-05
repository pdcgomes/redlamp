#if DEBUG || REDLAMP_PROFILING
    import Foundation
    import RedlampEngineAPI
    @_spi(Harness) import RedlampUI

    /// The runs a scenario belongs to: smoke is the quick check, full every feature, soak the
    /// random walks; the release tier is full plus soak (and the performance pass).
    public enum Tier: String, Codable, Sendable, CaseIterable {
        case smoke, full, soak, performance
    }

    /// Something the suite promises to exercise. The contract tests require every one the
    /// catalogues name to be claimed by a scenario or exempted with a reason, and the runner
    /// records which were exercised, and by which input path.
    public enum Claim: Hashable, Sendable, CustomStringConvertible {
        case action(ShortcutAction)
        case parameter(ParameterID)
        case panel(PanelID)
        case section(SidebarSection)
        case tool(EditTool)
        case mask(MaskKind)
        /// A feature of Report a Bug's catalogue (`docs/feedback/areas.json`), such as `masking.sky`.
        case feature(String)

        public var description: String {
            switch self {
            case let .action(action): "action.\(action.rawValue)"
            case let .parameter(parameter): "parameter.\(parameter.rawValue)"
            case let .panel(panel): "panel.\(panel.rawValue)"
            case let .section(section): "section.\(section.rawValue)"
            case let .tool(tool): "tool.\(tool.rawValue)"
            case let .mask(kind): "mask.\(kind.rawValue)"
            case let .feature(id): "feature.\(id)"
            }
        }
    }

    /// The way an input reached the app, for the coverage report.
    public enum InputPath: String, Codable, Sendable {
        case key, menu, palette, mouse, model
        /// A ⌘ shortcut with ⇧ or ⌥ whose menu item carries the registry's key: synthetic events
        /// don't reach SwiftUI's handling of those, so the item's action runs from the menu.
        case binding
    }

    /// A launch of the app: scenarios in one group share a process, in order; the next group
    /// starts the app again on the same home, as a person reopening it would.
    public enum LaunchGroup: String, Codable, Sendable, CaseIterable {
        /// Opened on the run's photo folder.
        case main
        /// Opened with no arguments, so it restores what the previous launch left.
        case relaunch
    }

    public struct Scenario: Sendable, Identifiable {
        public let id: String
        public let title: String
        public let tiers: Set<Tier>
        public let group: LaunchGroup
        public let claims: [Claim]
        /// Steps need a key window (SwiftUI gestures on the canvas), which needs the app active.
        /// Without focus allowed, the scenario takes the model's path and the coverage says so.
        public let needsFocus: Bool
        public let run: @Sendable (RunningApp) throws -> Void

        public init(
            _ id: String, _ title: String, tiers: Set<Tier> = [.full], group: LaunchGroup = .main,
            claims: [Claim], needsFocus: Bool = false, run: @escaping @Sendable (RunningApp) throws -> Void,
        ) {
            self.id = id
            self.title = title
            self.tiers = tiers
            self.group = group
            self.claims = claims
            self.needsFocus = needsFocus
            self.run = run
        }
    }

    /// A scenario's failure: what was expected, and what the app did instead.
    public struct ScenarioFailure: Error, CustomStringConvertible {
        public var message: String
        public init(_ message: String) {
            self.message = message
        }

        public var description: String {
            message
        }
    }

    /// A scenario that can't run here, such as one whose model isn't downloaded.
    public struct ScenarioSkip: Error, CustomStringConvertible {
        public var reason: String
        public init(_ reason: String) {
            self.reason = reason
        }

        public var description: String {
            reason
        }
    }
#endif
