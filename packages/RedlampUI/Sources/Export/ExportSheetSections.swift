import AppKit
import RedlampDocument
import RedlampEngineAPI
import SwiftUI

/// Where the file goes and what it is called.
struct ExportLocationSection: View {
    let photo: URL
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
            Picker("File name", selection: $settings.naming.mode) {
                ForEach(ExportNaming.Mode.allCases, id: \.self) { Text($0.name).tag($0) }
            }
            switch settings.naming.mode {
            case .original:
                TextField("Suffix", text: $settings.naming.suffix, prompt: Text("None"))
            case .custom:
                TextField("Name", text: $settings.naming.customName, prompt: Text("Name"))
            }
            LabeledContent("Saves as") {
                Text(ExportDestination.url(for: photo, settings: settings).lastPathComponent)
                    .foregroundStyle(.secondary)
                    .truncationMode(.middle)
                    .lineLimit(1)
            }
            Picker("If the file exists", selection: $settings.existingFiles) {
                ForEach(ExistingFilePolicy.allCases, id: \.self) { Text($0.name).tag($0) }
            }
        }
        .onAppear { chosenFolder = settings.destinationFolder }
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
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.prompt = "Choose"
                    panel.message = "Choose the folder exports go to."
                    panel.directoryURL = settings.destinationFolder ?? photo.deletingLastPathComponent()
                    if panel.runModal() == .OK, let url = panel.url {
                        chosenFolder = url
                        settings.destinationFolder = url
                    }
                }
            },
        )
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
        case .png: "Lossless: every pixel kept exactly, in larger files."
        case .tiff: "Lossless, for printing and further editing. LZW and ZIP shrink the file without losing anything."
        }
    }
}

/// The exported size, and its resolution for print.
struct ExportSizeSection: View {
    let photoSize: PixelSize
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
            LabeledContent("Exported size") {
                Text(readout).monospacedDigit().foregroundStyle(.secondary)
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

    private var readout: String {
        let size = sizing.isValid ? sizing.resolve(photoSize) : photoSize
        let source = "\(photoSize.width) × \(photoSize.height)"
        return size == photoSize ? "\(source) px (full size)" : "\(source) → \(size.width) × \(size.height) px"
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
