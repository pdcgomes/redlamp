import AppKit
import RedlampDocument
import RedlampEngineAPI
import RedlampLibrary
import SwiftUI

/// Where the files go and what they're called.
struct ExportLocationSection: View {
    /// Where the settings put the exports, worked out when they change, not on every redraw: it
    /// reads files in the folder.
    let plan: ExportPlan
    /// The naming templates saved for renaming and importing, which exports share.
    let namingPresets: NamingPresetStore?
    @Binding var settings: ExportSettings
    @State private var chosenFolder: URL?

    private enum Choice: Hashable {
        case original, folder(URL), choose
    }

    var body: some View {
        Section("Location") {
            Picker("Export to", selection: choice) {
                Text("Same Folder as Original").tag(Choice.original)
                if let folder = settings.destinationFolder ?? chosenFolder {
                    Text(folder.lastPathComponent).tag(Choice.folder(folder))
                }
                Divider()
                Text("Choose…").tag(Choice.choose)
            }
            .automationIdentifier("export.destination")
            LabeledContent("File name") {
                ExportNamingField(store: namingPresets, naming: $settings.naming, problem: plan.problem)
            }
            ForEach(template?.textNames ?? [], id: \.self) { name in
                TextField(Self.title(ofText: name), text: text(name), prompt: Text(Self.title(ofText: name)))
            }
            if template?.tokens.contains(where: { $0.field == .sequence }) == true {
                TextField("Start numbers at", value: $settings.naming.sequenceStart, format: .number)
            }
            LabeledContent("Saves as") {
                Text(plan.savesAs)
                    .foregroundStyle(.secondary)
                    .truncationMode(.middle)
                    .lineLimit(1)
            }
            Picker("If the file exists", selection: $settings.existingFiles) {
                ForEach(ExistingFilePolicy.allCases, id: \.self) { Text($0.name).tag($0) }
            }
        }
        .onAppear { chosenFolder = settings.destinationFolder }
        .onChange(of: settings, initial: true) { plan.update(settings) }
    }

    /// The template as it's typed, for the texts and numbers it asks for.
    private var template: NamingTemplate? {
        try? NamingTemplate(parsing: settings.naming.template, asYouType: true)
    }

    /// `{text}` and `{text:shoot}`'s values.
    private func text(_ name: String) -> Binding<String> {
        Binding(
            get: { settings.naming.texts[name] ?? "" },
            set: { settings.naming.texts[name] = $0.isEmpty ? nil : $0 },
        )
    }

    /// Custom Text for `{text}`, Shoot Name for `{text:shoot}`, as Rename Photos calls them.
    static func title(ofText name: String) -> String {
        name.isEmpty ? "Custom Text" : name.capitalized + " Name"
    }

    private var choice: Binding<Choice> {
        Binding(
            get: { settings.destinationFolder.map(Choice.folder) ?? .original },
            set: { choice in
                switch choice {
                case .original:
                    settings.destinationFolder = nil
                case let .folder(url):
                    settings.destinationFolder = url
                case .choose:
                    // The picker sets its selection while its menu still tracks the mouse; the panel
                    // waits for the menu to close, as neither of these modes runs while a menu tracks.
                    RunLoop.main.perform(inModes: [.default, .modalPanel]) {
                        MainActor.assumeIsolated { chooseFolder() }
                    }
                }
            },
        )
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder exports go to."
        panel.directoryURL = settings.destinationFolder ?? plan.folder
        let chosen: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            chosenFolder = url
            settings.destinationFolder = url
        }
        // Not run modal: from a run loop block, a modal loop holds back the blocks queued with it
        // until it ends, and on macOS 27 the panel doesn't come up then.
        if let window = NSApp.modalWindow ?? NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in MainActor.assumeIsolated { chosen(response) } }
        } else {
            panel.begin { response in MainActor.assumeIsolated { chosen(response) } }
        }
    }
}

/// Format, quality or compression, bit depth and color space.
struct ExportFileSection: View {
    @Binding var settings: ExportSettings

    var body: some View {
        Section {
            Picker("Format", selection: Binding(get: { settings.format }, set: { settings.setFormat($0) })) {
                Section("Lossy") {
                    ForEach(ExportFormat.lossy, id: \.self) { Text($0.name).tag($0) }
                }
                Section("Lossless") {
                    ForEach(ExportFormat.lossless, id: \.self) { Text($0.name).tag($0) }
                }
            }
            .automationIdentifier("export.format")
            if settings.format.isLossless {
                if settings.format == .tiff {
                    Picker("Compression", selection: $settings.tiffCompression) {
                        ForEach(TIFFCompression.allCases, id: \.self) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            } else {
                LabeledContent("Quality") {
                    HStack(spacing: 8) {
                        Slider(
                            value: Binding(
                                get: { Double(settings.quality) },
                                set: { settings.quality = Int($0.rounded()) },
                            ),
                            in: 0 ... 100,
                        )
                        .controlSize(.small)
                        Text("\(settings.quality)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 32, alignment: .trailing)
                    }
                }
                .disabled(settings.limitsFileSize)
                LabeledContent {
                    HStack(spacing: 6) {
                        TextField("Limit", value: $settings.fileSizeLimitKB, format: .number.grouping(.never))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 64)
                            .disabled(!settings.limitsFileSize)
                        Text("KB").foregroundStyle(.secondary)
                    }
                } label: {
                    Toggle("Limit file size to", isOn: $settings.limitsFileSize)
                }
            }
            if settings.format.bitDepths.count > 1 {
                Picker("Bit depth", selection: $settings.bitDepth) {
                    ForEach(settings.format.bitDepths, id: \.self) { Text("\($0)-bit").tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Picker("Color space", selection: $settings.colorSpace) {
                ForEach(OutputColorSpace.allCases, id: \.self) { Text($0.name).tag($0) }
            }
        } header: {
            Text("File")
        } footer: {
            Text(footer).formFooter()
        }
    }

    private var footer: String {
        switch settings.format {
        case .jpeg: "Lossy and 8-bit: opens everywhere."
        case .heic: "Lossy, about half the size of a JPEG of the same quality. 10-bit avoids banding in skies."
        case .avif: "Lossy, smaller still than HEIC, and read by current browsers. 10-bit avoids banding in skies."
        case .jxl: "Lossy, 8 or 16 bits, in smaller files than JPEG at the same quality. Read by macOS, Safari and Chrome."
        case .png: "Lossless: every pixel kept exactly, in larger files."
        case .tiff: "Lossless, for printing and further editing. LZW and ZIP shrink the file without losing anything."
        case .jxlLossless: "Lossless: every pixel kept exactly, 8 or 16 bits, in smaller files than PNG. Read by macOS, Safari and Chrome."
        }
    }
}

/// The border each photo is exported with (EDT-35).
struct ExportBorderSection: View {
    @Binding var border: ExportBorder
    let borders: [ExportBorder]

    var body: some View {
        Section {
            Picker("Border", selection: $border) {
                Text(ExportBorder.asEdited.title).tag(ExportBorder.asEdited)
                Text(ExportBorder.none.title).tag(ExportBorder.none)
                if !borders.isEmpty {
                    Divider()
                    ForEach(borders, id: \.self) { Text($0.title).tag($0) }
                }
                // A preset's recipe that's no longer in the library still draws its border.
                if case .recipe = border, !borders.contains(border) {
                    Text(border.title).tag(border)
                }
            }
            .accessibilityIdentifier("export.border")
        } footer: {
            Text("""
            As Edited keeps each photo's own border; None leaves it out, for a lab or a client; a \
            border from Recipes › Borders goes around every photo exported. Sizes include the border.
            """)
            .formFooter()
        }
    }
}

/// The exported size, and its resolution for print.
struct ExportSizeSection: View {
    /// The photo's size, or its bordered canvas's when the export draws a border; nil while no photo is open.
    let photoSize: PixelSize?
    var bordered = false
    @Binding var sizing: ExportSizing

    var body: some View {
        Section {
            Picker("Resize", selection: $sizing.mode) {
                ForEach(ExportSizing.Mode.allCases, id: \.self) { mode in
                    Text(mode.name).tag(mode)
                    if mode == .full {
                        Divider()
                    }
                }
            }
            switch sizing.mode {
            case .full:
                EmptyView()
            case .longEdge:
                field("Long edge", value: $sizing.longEdge, unit: "px")
            case .shortEdge:
                field("Short edge", value: $sizing.shortEdge, unit: "px")
            case .dimensions:
                field("Width", value: $sizing.width, unit: "px")
                field("Height", value: $sizing.height, unit: "px")
            case .megapixels:
                LabeledContent("Megapixels") {
                    number(
                        TextField(
                            "Megapixels",
                            value: $sizing.megapixels,
                            format: .number.precision(.fractionLength(0 ... 1)),
                        ),
                        unit: "MP",
                    )
                }
            case .percentage:
                LabeledContent("Percentage") {
                    number(
                        TextField(
                            "Percentage",
                            value: $sizing.percentage,
                            format: .number.precision(.fractionLength(0)),
                        ),
                        unit: "%",
                    )
                }
            }
            if let photoSize {
                LabeledContent("Exported size") {
                    Text(readout(photoSize)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            field("Resolution", value: $sizing.ppi, unit: "ppi")
        } header: {
            Text("Size")
        } footer: {
            Text("""
            Exports are developed at full resolution and reduced last, so sharpening and texture \
            look the same at every size. They are never enlarged. Resolution only tells print \
            layouts how large to place the photo.
            """)
            .formFooter()
        }
    }

    private func readout(_ photoSize: PixelSize) -> String {
        let size = sizing.isValid ? sizing.resolve(photoSize) : photoSize
        let source = "\(photoSize.width) × \(photoSize.height)"
        let text = size == photoSize ? "\(source) px (full size)" : "\(source) → \(size.width) × \(size.height) px"
        return bordered ? "\(text), border included" : text
    }

    private func field(_ title: String, value: Binding<Int>, unit: String) -> some View {
        LabeledContent(title) {
            number(TextField(title, value: value, format: .number.grouping(.never)), unit: unit)
        }
    }

    private func number(_ field: TextField<Text>, unit: String) -> some View {
        HStack(spacing: 6) {
            field
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 72)
            Text(unit)
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .leading)
        }
    }
}
