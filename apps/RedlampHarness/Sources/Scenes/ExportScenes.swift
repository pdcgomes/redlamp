import AppKit
import RedlampDocument
import RedlampEngineAPI
import RedlampUI
import SwiftUI

extension HarnessScene {
    static var exportLive: HarnessScene {
        HarnessScene(
            id: "export",
            title: "Live",
            symbol: "square.and.arrow.up",
            synopsis: "The real Export dialog on this window, exporting the sample photo to the harness's "
                + "temporary folder, and Export with Previous",
            section: .export,
        ) {
            ExportLiveScene()
        }
    }

    static var exportStates: HarnessScene {
        HarnessScene(
            id: "export-states",
            title: "States",
            symbol: "square.grid.2x2",
            synopsis: "The Export dialog for each format, size mode and problem, for review in every theme",
            section: .export,
        ) {
            ExportStatesScene()
        }
    }
}

/// Presets and the last export, kept apart from the app's.
@MainActor
private let harnessExportStore = ExportPresetStore(defaults: UserDefaults(suiteName: "app.redlamp.harness.export")!)

// MARK: - Live

private struct ExportLiveScene: View {
    private let model = HarnessEditor.model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button("Export…") { ExportActions.present(model: model, store: harnessExportStore) }
                Button("Export with Previous") { ExportActions.exportWithPrevious(
                    model: model,
                    store: harnessExportStore,
                ) }
                Button("Show Folder") {
                    if let url = model.info?.url {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
            .disabled(model.info == nil)
            LabeledContent("Photo", value: model.info?.fileName ?? "Opening…")
            LabeledContent("Status", value: model.exportStatus ?? "–")
            LabeledContent("Previous", value: previous)
            SpecimenGroup(title: "Try", note: """
            Export twice with “If the file exists” on Ask: the second asks to Replace or Keep Both. \
            Turn on a 20 KB limit at full size: the export fails with a message saying how small it can get. \
            Save a preset, change a setting and see “(edited)”, then Update and Delete it. \
            With the dialog open and no field focused, ← and → must not change the photo behind it.
            """) {
                EmptyView()
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
    }

    private var previous: String {
        guard let settings = harnessExportStore.previous else { return "None yet" }
        let preset = harnessExportStore.preset(harnessExportStore.previousPresetID)?.name ?? "Custom"
        return "\(preset): \(settings.format.name), \(settings.sizing.mode.name)"
    }
}

// MARK: - States

private struct ExportStatesScene: View {
    private let photo = URL(fileURLWithPath: "/Photos/IMG_1234.NEF")
    private let photoSize = PixelSize(width: 6000, height: 4000)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Self.specimens, id: \.title) { specimen in
                SpecimenGroup(title: specimen.title, note: specimen.note) {
                    ExportSheet(
                        photo: photo, photoSize: photoSize, store: harnessExportStore,
                        settings: specimen.settings, presetID: specimen.presetID,
                        onCancel: {}, onExport: { _, _, _ in },
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
                }
            }
        }
    }

    private struct Specimen {
        let title: String
        let note: String
        let settings: ExportSettings
        var presetID: UUID?
    }

    private static var specimens: [Specimen] {
        let builtIns = ExportPreset.builtIns
        var edited = builtIns[1].settings
        edited.quality = 70
        var heic = ExportSettings()
        heic.setFormat(.heic)
        heic.bitDepth = 10
        heic.colorSpace = .displayP3
        var dimensions = ExportSettings()
        dimensions.sizing = ExportSizing(mode: .dimensions)
        var custom = ExportSettings()
        custom.naming = ExportNaming(mode: .custom)
        var missing = ExportSettings()
        missing.destinationFolder = URL(fileURLWithPath: "/Volumes/Gone/Exports")
        return [
            Specimen(
                title: "Full Size JPEG",
                note: "The first built-in, as the dialog opens before any export: quality, the size limit off, "
                    + "and “Saves as” naming the file next to the original.",
                settings: builtIns[0].settings, presetID: builtIns[0].id,
            ),
            Specimen(
                title: "Size limit",
                note: "Quality is dimmed while the limit is on; the long edge reads 6000 × 4000 → 1600 × 1067.",
                settings: builtIns[2].settings, presetID: builtIns[2].id,
            ),
            Specimen(
                title: "Edited preset",
                note: "A built-in with one setting changed is “(edited)”; Update and Delete appear only for your own presets.",
                settings: edited, presetID: builtIns[1].id,
            ),
            Specimen(
                title: "HEIC, 10-bit, Display P3",
                note: "Bit depth offers 8 and 10, and the footer says what 10 is for.",
                settings: heic,
            ),
            Specimen(
                title: "16-bit TIFF",
                note: "No quality; Compression None, LZW and ZIP; 8 or 16 bits.",
                settings: builtIns[3].settings, presetID: builtIns[3].id,
            ),
            Specimen(
                title: "Width & height",
                note: "Two fields; 1920 × 1080 fits a 3:2 photo to 1620 × 1080.",
                settings: dimensions,
            ),
            Specimen(
                title: "Custom name, empty",
                note: "Export is disabled and the bar says why.",
                settings: custom,
            ),
            Specimen(
                title: "Folder gone",
                note: "A preset's folder that has been moved or unplugged: Export is disabled until another is chosen.",
                settings: missing,
            ),
        ]
    }
}
