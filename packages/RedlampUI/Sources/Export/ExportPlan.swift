import Foundation
import Observation
import RedlampDocument
import RedlampEngineAPI

/// Where the Export dialog's settings put the export: the name it saves as and what happens to
/// a file already there. Working it out reads the files there, through the decode service in
/// the app, so it is done off the main thread each time the settings change; until it arrives,
/// the name is the one the export has with no file there. A newer request supersedes an older one.
@MainActor @Observable
final class ExportPlan {
    let photo: URL
    @ObservationIgnored let files: any FileInspecting
    private(set) var savesAs = ""
    /// Where the latest settings put the export, once it has been worked out.
    private(set) var step: ExportActions.Step?
    @ObservationIgnored private var settings: ExportSettings?
    @ObservationIgnored private var latest: Task<(URL, ExportActions.Step), Never>?

    init(photo: URL, files: any FileInspecting) {
        self.photo = photo
        self.files = files
    }

    func update(_ settings: ExportSettings) {
        guard settings != self.settings else { return }
        self.settings = settings
        savesAs = ExportDestination.named(for: photo, settings: settings).lastPathComponent
        step = nil
        let (photo, files) = (photo, files)
        let request = Task.detached(priority: .userInitiated) {
            let url = ExportDestination.url(for: photo, settings: settings, reading: files)
            return (url, ExportActions.step(at: url, settings: settings))
        }
        latest = request
        Task {
            let (url, step) = await request.value
            guard request == latest else { return }
            savesAs = url.lastPathComponent
            self.step = step
        }
    }

    /// Where the latest settings put the export, waiting for it if it hasn't been worked out.
    func currentStep() async -> ExportActions.Step? {
        while let request = latest {
            let (_, step) = await request.value
            if request == latest {
                return step
            }
        }
        return nil
    }
}
