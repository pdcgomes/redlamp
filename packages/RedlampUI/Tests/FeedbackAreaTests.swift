import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampUI

/// The hierarchy reports are filed under: well formed, covering every part of the UI it names,
/// and published as `docs/feedback/areas.json`. After changing the catalog, record the JSON again
/// with `TEST_RUNNER_REDLAMP_RECORD_FEEDBACK_AREAS=1`.
struct FeedbackAreaTests {
    static let jsonURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "docs/feedback/areas.json")
    static let recording = ProcessInfo.processInfo.environment["REDLAMP_RECORD_FEEDBACK_AREAS"] == "1"

    private struct Document: Encodable {
        let format = "app.redlamp.feedback-areas"
        let areas: [FeedbackArea]
    }

    @Test func `every feature ID is unique and sits under its area`() {
        let features = FeedbackArea.catalog.flatMap(\.features)
        #expect(Set(features.map(\.id)).count == features.count)
        #expect(Set(FeedbackArea.catalog.map(\.id)).count == FeedbackArea.catalog.count)
        for area in FeedbackArea.catalog {
            #expect(!area.features.isEmpty)
            for feature in area.features {
                #expect(feature.id.hasPrefix("\(area.id)."), "\(feature.id) isn't under \(area.id)")
                #expect(feature.id.range(of: #"^[a-z-]+\.[a-z0-9-]+$"#, options: .regularExpression) != nil)
                #expect(!feature.title.isEmpty)
                #expect(
                    feature.keywords.allSatisfy { $0 == $0.lowercased() },
                    "\(feature.id) has a keyword in capitals",
                )
            }
        }
    }

    @Test func `every area but Something Else ends with something else in it`() {
        for area in FeedbackArea.catalog where area.id != FeedbackArea.otherID {
            #expect(area.features.last?.id == "\(area.id).other")
            #expect(area.features.last?.title == "Something else in \(area.title)")
        }
        #expect(FeedbackArea.catalog.last?.id == FeedbackArea.otherID)
    }

    @Test func `labels fit GitHub's limits`() {
        for area in FeedbackArea.catalog {
            #expect(area.label.count <= 50)
            #expect(area.summary.count <= 100, "\(area.id)'s summary is too long for a label description")
        }
    }

    @Test func `every Develop panel and slider has a feature`() {
        for panel in PanelID.allCases {
            #expect(FeedbackArea.topic(FeedbackArea.featureID(for: panel)) != nil, "\(panel)")
            for parameter in panel.parameters {
                let id = FeedbackArea.featureID(for: parameter)
                #expect(id.flatMap(FeedbackArea.topic) != nil, "\(parameter) has no feature")
            }
        }
    }

    @Test func `sliders go to the feature their controls sit under`() {
        #expect(FeedbackArea.featureID(for: .temperature) == "develop.white-balance")
        #expect(FeedbackArea.featureID(for: .shadows) == "develop.tone")
        #expect(FeedbackArea.featureID(for: .dehaze) == "develop.presence")
        #expect(FeedbackArea.featureID(for: .noiseColor) == "develop.noise-reduction")
        #expect(FeedbackArea.featureID(for: .sharpenRadius) == "develop.sharpening")
        #expect(FeedbackArea.featureID(for: .colorChrome) == "develop.camera-recipe")
        #expect(FeedbackArea.featureID(for: .grainAmount) == "develop.effects")
    }

    @Test func `every tool, mask kind and healing choice has a feature`() {
        for tool in EditTool.allCases {
            #expect(
                FeedbackArea.featureID(for: tool).map { FeedbackArea.topic($0) != nil } ?? (tool == .edit),
                "\(tool)",
            )
        }
        for kind in MaskKind.allCases {
            #expect(FeedbackArea.topic(FeedbackArea.featureID(for: kind)) != nil, "\(kind)")
        }
        for mode in RetouchSpot.Mode.allCases {
            for pick in SpotPick.allCases {
                #expect(FeedbackArea.topic(FeedbackArea.featureID(for: mode, pick: pick)) != nil)
            }
        }
    }

    @Test func `each mask in Create New Mask has its own feature, titled as the menu titles it`() {
        let ids = MaskKind.creatable.map(FeedbackArea.featureID(for:))
        #expect(Set(ids).count == ids.count)
        for kind in MaskKind.creatable {
            #expect(FeedbackArea.topic(FeedbackArea.featureID(for: kind))?.feature.title == kind.name)
        }
    }

    @Test func `search finds features by the words people use`() {
        #expect(FeedbackArea.search("object selector").first?.id == "masking.objects")
        #expect(FeedbackArea.search("white balance").first?.id == "develop.white-balance")
        #expect(FeedbackArea.search("beach ball").first?.id == "performance.freeze")
        #expect(FeedbackArea.search("x-trans").first?.id == "raw.demosaic")
        #expect(FeedbackArea.search("masking brush").first?.id == "masking.brush")
        #expect(FeedbackArea.search("   ").isEmpty)
        #expect(FeedbackArea.search("zzzz").isEmpty)
    }

    @Test func `a topic reads as its area and feature`() {
        #expect(FeedbackArea.topic("masking.objects")?.path == "Masking › Objects")
        #expect(FeedbackArea.topic("masking.nothing") == nil)
        #expect(FeedbackArea.topic("nowhere") == nil)
    }

    @Test func `the published areas match the catalog`() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Document(areas: FeedbackArea.catalog)) + Data("\n".utf8)
        if Self.recording {
            try FileManager.default.createDirectory(
                at: Self.jsonURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            )
            try data.write(to: Self.jsonURL)
            return
        }
        let published = try? Data(contentsOf: Self.jsonURL)
        #expect(
            published == data,
            "docs/feedback/areas.json is out of date: run with TEST_RUNNER_REDLAMP_RECORD_FEEDBACK_AREAS=1",
        )
    }
}
