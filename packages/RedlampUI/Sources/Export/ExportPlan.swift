import Foundation
import Observation
import RedlampDocument
import RedlampEngineAPI
import RedlampLibrary

/// A photo an export takes, by its address, its file's own edit or a version's (LIB-48), and what its name is made
/// from.
struct ExportPhoto: Sendable {
    var address: PhotoAddress
    var naming: ExportNames.Photo
}

/// Where the Export dialog's settings put the photos' exports (`ExportNames`): the names they save as and the
/// files already there. The photos' fields are read once, and the names are worked out off the main thread each
/// time the settings change, as they read the files there through the decode service in the app; until they
/// arrive, the names are the last ones worked out. A newer request supersedes an older one.
@MainActor
@Observable
final class ExportPlan {
    /// How many photos there are.
    let count: Int
    /// The folder the folder chooser starts in: the active photo's.
    let folder: URL
    @ObservationIgnored let files: any FileInspecting
    /// Where `{counter:…}` carries on from.
    @ObservationIgnored let counters: NamingCounters
    /// What the first photo saves as, and how many more there are.
    private(set) var savesAs = ""
    /// The latest settings' names, once worked out; nil while they're being worked out or don't read.
    private(set) var names: ExportNames?
    /// Why the template doesn't read, in words.
    private(set) var problem: String?
    /// The edits the names are for, in their order, once they've been read.
    @ObservationIgnored private(set) var photos: [PhotoAddress] = []
    @ObservationIgnored private let read: Task<[ExportPhoto], Never>
    @ObservationIgnored private var settings: ExportSettings?
    @ObservationIgnored private var latest: Task<Result<(ExportNames, [PhotoAddress]), NamingTemplateError>, Never>?
    @ObservationIgnored private let context = NamingContext(date: Date())

    /// `read` reads what the photos' names are made from, once, off the main thread.
    init(
        count: Int, folder: URL, files: any FileInspecting, counters: NamingCounters = NamingCounters(),
        read: @escaping @Sendable () async -> [ExportPhoto],
    ) {
        self.count = count
        self.folder = folder
        self.files = files
        self.counters = counters
        self.read = Task { await read() }
    }

    /// One photo named from its URL alone.
    convenience init(photo: URL, files: any FileInspecting) {
        self.init(count: 1, folder: photo.deletingLastPathComponent(), files: files) {
            [ExportPhoto(address: PhotoAddress(url: photo), naming: ExportNames.Photo(url: photo))]
        }
    }

    func update(_ settings: ExportSettings) {
        guard settings != self.settings else { return }
        self.settings = settings
        names = nil
        let (read, files, context, counters) = (read, files, context, counters)
        let request = Task.detached(priority: .userInitiated) {
            () -> Result<(ExportNames, [PhotoAddress]), NamingTemplateError> in
            let photos = await read.value
            return Result { () throws(NamingTemplateError) in
                try (
                    ExportNames(
                        photos.map(\.naming), settings: settings, context: context, counters: counters, reading: files,
                    ),
                    photos.map(\.address),
                )
            }
        }
        latest = request
        Task {
            let result = await request.value
            guard request == latest else { return }
            switch result {
            case let .success((names, photos)):
                self.names = names
                self.photos = photos
                problem = nil
                savesAs = Self.describe(names.targets)
            case let .failure(error):
                problem = error.message
            }
        }
    }

    /// The latest settings' names, waiting for them if they haven't been worked out; nil when the template
    /// doesn't read.
    func currentNames() async -> ExportNames? {
        while let request = latest {
            let result = await request.value
            if request == latest {
                return try? result.get().0
            }
        }
        return nil
    }

    /// "IMG_0001-redlamp.jpg", or "IMG_0001-redlamp.jpg and 11 more".
    static func describe(_ targets: [ExportNames.Target]) -> String {
        guard let first = targets.first?.url.lastPathComponent else { return "" }
        return targets.count == 1 ? first : "\(first) and \(targets.count - 1) more"
    }
}
