import Foundation
import RedlampLibrary

/// The import window's live example (LIB-27): where a photo goes below the destination and the name it
/// gets, as the import's plan makes them were it the import's first photo and its folder empty. It's
/// planned for real, alone, in a session of its own whose destination holds nothing, so the example
/// follows the planner: levels left out when they come out empty, a raw's JPEG beside it.
enum ImportExample {
    /// `photo`'s path below the destination, with the names of the files that go with it; nil when the
    /// plan leaves it, as raw only leaves a JPEG.
    static func path(
        of photo: ImportPhoto, on source: ImportSource, settings: ImportSettings, paths: LibraryPaths,
    ) async -> String? {
        var photo = photo
        photo.choices.isChosen = true
        photo.imported = []
        if !photo.isRead {
            // Named from its file until its head is read: its name and date.
            photo.state = .read
            photo.files[0].contentKey = ContentKey(fileSize: Int(photo.primary.size), head: Data())
        }
        var settings = settings
        settings.destination = URL(
            fileURLWithPath: "/.redlamp-import-example-\(UUID().uuidString)", isDirectory: true,
        )
        settings.backup = nil
        let session = ImportSession(
            sources: [source], library: ImportLibrary(paths: paths), makesPreviews: false,
        )
        session.add([photo])
        guard let plan = try? await session.plan(settings), let item = plan.items.first,
              let first = item.copies.first
        else { return nil }
        let others = item.copies.dropFirst().filter { $0.role == .photo }.map(\.name)
        return others.isEmpty ? first.path : first.path + " (with " + others.joined(separator: ", ") + ")"
    }
}
