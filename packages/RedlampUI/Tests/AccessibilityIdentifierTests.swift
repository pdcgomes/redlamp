import AppKit
import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampUI

/// The identifiers the regression suite (and VoiceOver) find the editor's controls by: every
/// panel, its header and its sliders, every tool, the histogram's regions and the left panels.
@MainActor
struct AccessibilityIdentifierTests {
    /// Panel parameters drawn as something other than a slider row, and where they are.
    static let drawnElsewhere: [ParameterID: String] = Dictionary(uniqueKeysWithValues: [
        (ParameterID.curveSplitShadows, "a handle under the curve"),
        (.curveSplitMidtones, "a handle under the curve"),
        (.curveSplitHighlights, "a handle under the curve"),
        (.frameStyle, "the frame menu"),
    ] + ColorBand.allCases.flatMap { band in
        [
            (band.saturationParameter, "the Color Mixer's Saturation mode"),
            (band.luminanceParameter, "the Color Mixer's Luminance mode"),
        ]
    } + GradingRange.allCases.flatMap { range in
        [
            (range.hueParameter, "its colour wheel"),
            (range.saturationParameter, "its colour wheel"),
            (range.luminanceParameter, "the slider under its wheel"),
        ]
    })

    private func identifiers(in view: NSView) -> Set<String> {
        var found: Set<String> = []
        if !view.accessibilityIdentifier().isEmpty {
            found.insert(view.accessibilityIdentifier())
        }
        if ["toolstrip", "histogram"].contains(view.accessibilityIdentifier()) {
            for case let element as NSAccessibilityElement in view.accessibilityChildren() ?? [] {
                if let identifier = element.accessibilityIdentifier() {
                    found.insert(identifier)
                }
            }
        }
        for child in view.subviews {
            found.formUnion(identifiers(in: child))
        }
        return found
    }

    private func showEditor() async throws -> (EditorModel, NSWindow, URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "identifiers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: folder.appending(path: "IMG_0001.ARW").path, contents: Data([1]))
        let model = EditorModel(engine: StubEngine())
        _ = NSApplication.shared
        model.open([folder])
        for _ in 0 ..< 400 where model.info == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        model.expandedPanels = Set(PanelID.allCases)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 360, height: 6000), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        let column = InspectorColumnView(model: model)
        window.contentView = column
        column.layoutSubtreeIfNeeded()
        return (model, window, folder)
    }

    @Test func `every panel, its header and its sliders carry identifiers`() async throws {
        let (model, window, folder) = try await showEditor()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(model.info != nil)
        let found = try identifiers(in: #require(window.contentView))
        for panel in PanelID.allCases {
            #expect(found.contains("panel.\(panel.rawValue)"), "no panel.\(panel.rawValue)")
            #expect(found.contains("panel.\(panel.rawValue).header"), "no header for \(panel.title)")
            for parameter in panel.parameters where Self.drawnElsewhere[parameter] == nil {
                #expect(found.contains("slider.\(parameter.rawValue)"), "no slider row for \(parameter.spec.label)")
                #expect(found.contains("slider.\(parameter.rawValue).track"), "no track for \(parameter.spec.label)")
            }
        }
    }

    @Test func `every tool has a button and the histogram a region per slider`() async throws {
        let (_, window, folder) = try await showEditor()
        defer { try? FileManager.default.removeItem(at: folder) }
        let found = try identifiers(in: #require(window.contentView))
        for tool in EditTool.allCases {
            #expect(found.contains("tool.\(tool.rawValue)"), "no button for \(tool.title)")
        }
        for parameter in [ParameterID.blacks, .shadows, .exposure, .highlights, .whites] {
            #expect(
                found.contains("histogram.\(parameter.rawValue)"),
                "no histogram region for \(parameter.spec.label)",
            )
        }
    }

    @Test func `the left panels carry identifiers`() {
        let model = EditorModel(engine: StubEngine())
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 260, height: 1200), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        let column = SidebarColumnView(model: model)
        window.contentView = column
        column.layoutSubtreeIfNeeded()
        let found = identifiers(in: column)
        for section in SidebarSection.allCases {
            #expect(found.contains("sidebar.\(section.rawValue)"), "no sidebar.\(section.rawValue)")
            #expect(found.contains("sidebar.\(section.rawValue).header"), "no header for \(section.title)")
        }
    }
}
