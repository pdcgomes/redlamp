import RedlampDocument
import RedlampEngineAPI
import SwiftUI

struct FilmstripView: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let folder = model.folder {
                    Label(folder.lastPathComponent, systemImage: "folder")
                }
                Text("\(model.library.count) photos\(model.library.includesSubfolders ? ", with subfolders" : "")")
                    .foregroundStyle(Theme.tertiaryLabel)
                if let progress = model.settingsSync.progress {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                        .frame(width: 80)
                    Text("\(progress.title): \(progress.done) of \(progress.total)")
                    Button("Cancel") { model.settingsSync.cancel() }
                        .buttonStyle(.link)
                } else if model.isMultiSelecting {
                    Text("\(model.selectedPhotos.count) selected")
                        .help("⌘-click adds or removes a photo, ⇧-click selects a range; ⌥⌘D keeps only this one")
                    Button("Sync…") { model.chooseSettingsToSync() }
                        .buttonStyle(.link)
                        .help("This photo's settings onto the other selected photos (⇧⌘S)")
                    Toggle("Auto Sync", isOn: Bindable(model.settingsSync).isAutoSyncing)
                        .toggleStyle(.checkbox)
                        .controlSize(.mini)
                        .help("Every change to this photo repeats on the other selected photos (⌥⇧⌘A)")
                }
                if let report = model.settingsSync.report {
                    Text(report)
                        .foregroundStyle(Theme.tertiaryLabel)
                        .lineLimit(1)
                        .help(report)
                }
                if let suggestion = model.stackSuggestions.first {
                    StackSuggestionBanner(suggestion: suggestion)
                }
                Spacer()
                if let selection = model.selection, SupportedFormats.isStack(selection) {
                    Button("Stack…") { model.openStackWorkspace(selection) }
                        .buttonStyle(.link)
                        .help("Change the stack's frames or method")
                }
                if let info = model.info {
                    Text(info.fileName)
                    Text("\(info.pixelSize.width) × \(info.pixelSize.height)  ·  \(info.sensorDescription)")
                        .foregroundStyle(Theme.tertiaryLabel)
                }
            }
            .font(Theme.captionFont)
            .foregroundStyle(Theme.secondaryLabel)
            .padding(.horizontal, 12)
            .frame(height: 22)
            .padding(.top, 6)

            if model.library.isOpenFolderUnavailable {
                Label(
                    "This folder isn't available. Is its disk connected?",
                    systemImage: "externaldrive.badge.questionmark",
                )
                .font(Theme.captionFont)
                .foregroundStyle(Theme.secondaryLabel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(height: FilmstripStripView.height)
            } else {
                FilmstripStripHost(model: model)
                    .frame(height: FilmstripStripView.height)
            }
        }
        .frame(height: 110)
    }
}

/// "Focus stack detected: 25 frames" with Merge and dismiss; the frame range shows as help.
private struct StackSuggestionBanner: View {
    let suggestion: StackSuggestion
    @Environment(EditorModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.stack.3d.down.right")
            Text("Focus stack detected: \(suggestion.frames.count) frames")
                .foregroundStyle(Theme.secondaryLabel)
                .help(range)
            Button("Merge") { model.mergeStack(suggestion) }
                .buttonStyle(.link)
            Button {
                model.dismissStack(suggestion)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }

    private var range: String {
        let names = suggestion.frames.map { $0.deletingPathExtension().lastPathComponent }
        return "\(names.first ?? "") – \(names.last ?? "")"
    }
}
