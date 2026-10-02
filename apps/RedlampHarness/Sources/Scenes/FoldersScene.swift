import AppKit
import Observation
import RedlampDocument
@_spi(Harness) import RedlampUI
import SwiftUI

extension HarnessScene {
    static var folders: HarnessScene {
        HarnessScene(
            id: "folders",
            title: "Folders",
            symbol: "folder",
            synopsis: "The Folders panel and the AppKit filmstrip on a folder of real photos, with live updates",
            section: .panels,
        ) {
            FoldersScene()
        } inspector: {
            FoldersInspector()
        }
    }
}

/// An editor of its own on the harness's engine, so the scene's folder doesn't replace the other
/// scenes' photo. `--folders-root <path>` picks the folder (the raw fixtures by default).
@MainActor @Observable
final class FoldersSceneState {
    static let shared = FoldersSceneState()

    let model = EditorModel(engine: HarnessEditor.model.engine)
    var revision = 0
    @ObservationIgnored private var opened = false

    var root: URL {
        HarnessLaunch.value(after: "--folders-root").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "tests/fixtures/raw", directoryHint: .isDirectory)
    }

    func prepare() {
        guard !opened else { return }
        opened = true
        model.open([root])
    }
}

private struct FoldersScene: View {
    @State private var state = FoldersSceneState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button("Show Photos in Subfolders") {
                    state.model.setIncludesSubfolders(!state.model.library.includesSubfolders)
                }
                Text("\(state.model.library.count) photos in \(state.model.folder?.lastPathComponent ?? "—")")
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 32) {
                Specimen(caption: "The left column at 250 pt") {
                    AppKitSpecimen(width: 250, revision: state.revision) {
                        FixedHeightView(SidebarListViews.make(model: state.model), height: 420)
                    }
                }
                Specimen(caption: "The filmstrip's photos") {
                    AppKitSpecimen(width: 720, revision: state.revision) {
                        FixedHeightView(FilmstripViews.make(model: state.model), height: FilmstripViews.height)
                    }
                }
            }
        }
        .task { state.prepare() }
    }
}

private struct FoldersInspector: View {
    @State private var state = FoldersSceneState.shared

    var body: some View {
        Form {
            Section("Folder") {
                LabeledContent("Open", value: state.model.folder?.path ?? "—")
                LabeledContent("Photos", value: "\(state.model.library.count)")
                LabeledContent("Thumbnails in memory", value: "\(state.model.thumbnailLoader.memoryUsed >> 20) MB")
                Button("Rebuild Views") { state.revision += 1 }
            }
        }
        .formStyle(.grouped)
    }
}
