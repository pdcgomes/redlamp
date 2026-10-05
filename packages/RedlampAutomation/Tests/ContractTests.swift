import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampAutomation
@_spi(Harness) import RedlampUI

/// The regression suite's contract: everything the app's own catalogues name (actions,
/// parameters, panels, tools, mask kinds, Report a Bug's features) has a scenario, or an
/// exemption that says why. A feature added without a scenario fails here.
@MainActor
struct ContractTests {
    struct Exemptions: Decodable {
        struct Exemption: Decodable {
            var claim: String
            var reason: String
        }

        var exemptions: [Exemption]
    }

    static let exemptions: [String: String] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../tests/e2e/exemptions.json").standardizedFileURL
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(Exemptions.self, from: data)
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: file.exemptions.map { ($0.claim, $0.reason) })
    }()

    @Test func `scenario identifiers are unique`() {
        let ids = Catalogue.all.map(\.id)
        #expect(
            Set(ids).count == ids.count,
            "Repeated: \(Dictionary(grouping: ids) { $0 }.filter { $1.count > 1 }.keys)",
        )
    }

    @Test func `every claim the catalogues name has a scenario or an exemption`() {
        let claimed = Set(Catalogue.all.flatMap(\.claims).map(\.description))
        let missing = Catalogue.required.map(\.description)
            .filter { !claimed.contains($0) && Self.exemptions[$0] == nil }
        #expect(missing.isEmpty, "No scenario or exemption for \(missing.count): \(missing.joined(separator: ", "))")
    }

    @Test func `every exemption names a claim the catalogues require, and says why`() {
        let required = Set(Catalogue.required.map(\.description))
        #expect(!Self.exemptions.isEmpty, "tests/e2e/exemptions.json wasn't read")
        for (claim, reason) in Self.exemptions {
            #expect(required.contains(claim), "\(claim) isn't something the app offers")
            #expect(reason.count > 20, "\(claim)'s exemption needs a reason")
        }
    }

    @Test func `scenarios claim only features Report a Bug knows`() {
        let features = Set(FeedbackArea.catalog.flatMap(\.features).map(\.id))
        for scenario in Catalogue.all {
            for case let .feature(id) in scenario.claims {
                #expect(features.contains(id), "\(scenario.id) claims \(id), which isn't in docs/feedback/areas.json")
            }
        }
    }

    @Test func `every action has a check, and those that can't run here say why`() {
        #expect(ActionCheck.all.map(\.action) == ShortcutAction.allCases)
        for check in ActionCheck.all {
            if let reason = check.unavailable {
                #expect(!reason.isEmpty, "\(check.action.title) is unavailable without a reason")
            } else {
                #expect(
                    check.observe != nil || [.copySettingsAgain, .pasteSettings, .pastePrevious, .syncSettingsAgain]
                        .contains(check.action),
                    "\(check.action.title) checks nothing it changes",
                )
            }
        }
    }

    @Test func `every tier has scenarios`() {
        for tier in Tier.allCases {
            #expect(Catalogue.all.contains { $0.tiers.contains(tier) }, "No scenario in the \(tier) tier")
        }
    }
}
