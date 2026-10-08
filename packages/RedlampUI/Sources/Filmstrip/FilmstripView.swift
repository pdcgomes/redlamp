import RedlampDocument
import RedlampEngineAPI
import SwiftUI

struct FilmstripView: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            // Parts of their own, each reading only what it shows: a step of a held arrow key changes the active
            // photo, which only the last two read.
            HStack(spacing: 8) {
                FilmstripFolder()
                FilmstripCount()
                FilmstripSync()
                FilmstripSuggestion()
                Spacer()
                FilmstripStackButton()
                FilmstripPhotoInfo()
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
        .frame(height: PanelMetrics.filmstripHeight)
    }
}

/// The folder shown.
private struct FilmstripFolder: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        if let folder = model.folder {
            Label(folder.lastPathComponent, systemImage: "folder")
        }
    }
}

/// How many photos are shown, and of how many while a filter leaves some out.
private struct FilmstripCount: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        Text(photoCount)
            .foregroundStyle(Theme.tertiaryLabel)
            .help(filteredTotal == nil ? "" :
                "A filter hides some photos: \\ shows the filter bar in Library, ⌘L turns it off")
    }

    private var photoCount: String {
        let subfolders = model.library.includesSubfolders ? ", with subfolders" : ""
        guard let total = filteredTotal else { return "\(model.library.count) photos\(subfolders)" }
        return "\(model.library.count) of \(total) photos\(subfolders)"
    }

    /// The source's photos while a filter leaves some out.
    private var filteredTotal: Int? {
        guard model.library.isFiltered, let listed = model.libraryFilters?.listed, listed.shown < listed.total
        else { return nil }
        return listed.total
    }
}

/// A sync's progress, or with several photos selected, how many and Sync.
private struct FilmstripSync: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        if let progress = model.settingsSync.progress {
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                .frame(width: 80)
            Text("\(progress.title): \(progress.done) of \(progress.total)")
            Button("Cancel") { model.settingsSync.cancel() }
                .buttonStyle(.link)
        } else if model.isMultiSelecting {
            Text("\(model.photoSelection.count) selected")
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
    }
}

/// The first focus stack found, to merge or dismiss.
private struct FilmstripSuggestion: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        if let suggestion = model.stackSuggestions.first {
            StackSuggestionBanner(suggestion: suggestion)
        }
    }
}

/// Stack… while the active photo is a stack document.
private struct FilmstripStackButton: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        if let selection = model.selection, SupportedFormats.isStack(selection) {
            Button("Stack…") { model.openStackWorkspace(selection) }
                .buttonStyle(.link)
                .help("Change the stack's frames or method")
        }
    }
}

/// The open photo's name, size and sensor.
private struct FilmstripPhotoInfo: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        if let info = model.info {
            Text(info.fileName)
            Text("\(info.pixelSize.width) × \(info.pixelSize.height)  ·  \(info.sensorDescription)")
                .foregroundStyle(Theme.tertiaryLabel)
        }
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
