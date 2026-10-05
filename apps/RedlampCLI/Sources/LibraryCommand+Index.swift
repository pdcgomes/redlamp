import Foundation
import RedlampLibrary

extension LibraryCommand {
    /// `redlamp library index`: adds folders to an index and indexes them (LIB-07), printing what it
    /// has done every second on stderr and a summary at the end.
    static func index(_ arguments: [String]) async throws {
        let options = try Arguments(arguments, valued: ["--index", "--profile"])
        guard !options.positional.isEmpty, let path = options.value("--index") else {
            throw CLIError(description: "index needs folders and --index\n\n\(usage)")
        }
        let folders = try options.positional.map { argument in
            let folder = URL(fileURLWithPath: argument, isDirectory: true).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue
            else { throw CLIError(description: "no folder at \(folder.path)") }
            return folder
        }
        var fileSystem: any LibraryFileSystem = LocalFileSystem()
        if let name = options.value("--profile") {
            guard let profile = VolumeProfile.named(name) else {
                throw CLIError(
                    description: "unknown profile \(name): \(VolumeProfile.presets.map(\.name).joined(separator: ", "))",
                )
            }
            fileSystem = SimulatedFileSystem(profile: profile)
        }
        let url = URL(fileURLWithPath: path)
        let index = try await LibraryIndex.open(at: url)
        let indexer = LibraryIndexer(index: index, fileSystem: fileSystem)

        let clock = ContinuousClock()
        let started = clock.now
        var reported = started
        var photos = (added: 0, updated: 0, removed: 0)
        var indexed = 0
        var failures = 0
        var summary = LibraryIndexerSummary()
        func report() {
            let seconds = max((clock.now - started).seconds, 1e-9)
            var line = "  \(count(photos.added)) photos added"
            if photos.updated > 0 {
                line += ", \(count(photos.updated)) updated"
            }
            if photos.removed > 0 {
                line += ", \(count(photos.removed)) removed"
            }
            line += "; \(count(indexed)) folders indexed; \(count(Int(Double(photos.added) / seconds))) photos a second"
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
        for await event in indexer.index(folders) {
            switch event {
            case let .photosInserted(ids): photos.added += ids.count
            case let .photosUpdated(ids): photos.updated += ids.count
            case let .photosRemoved(ids): photos.removed += ids.count
            case .folderIndexed: indexed += 1
            case let .failed(path, message):
                failures += 1
                if failures <= 20 {
                    FileHandle.standardError.write(Data("  couldn't index \(path): \(message)\n".utf8))
                }
            case let .volumeOffline(volume):
                FileHandle.standardError
                    .write(Data("  volume \(volume) stopped answering: its photos are offline\n".utf8))
            case let .volumeOnline(volume):
                FileHandle.standardError.write(Data("  volume \(volume) answers again\n".utf8))
            case let .finished(finished):
                summary = finished
            }
            if clock.now - reported >= .seconds(1) {
                reported = clock.now
                report()
            }
        }
        let total = try await index.read { try $0.photoCount() }
        await index.close()

        let seconds = max(summary.elapsed.seconds, 1e-9)
        var lines = [
            "\(count(total)) photos in \(url.path), indexed in \(String(format: "%.1f", seconds)) s",
            "  folders: \(count(summary.foldersListed)) listed, \(count(summary.foldersIndexed)) indexed, "
                + "\(count(summary.foldersRemoved)) removed",
            "  photos: \(count(summary.photosInserted)) added, \(count(summary.photosUpdated)) updated, "
                + "\(count(summary.photosMoved)) renamed or moved, \(count(summary.photosRemoved)) removed; "
                + "\(count(summary.headsRead)) read, \(count(Int(Double(summary.headsRead) / seconds))) a second",
        ]
        if summary.failures > 0 {
            lines.append("  \(count(summary.failures)) couldn't be read or written: run it again to retry them")
        }
        if !summary.offlineVolumes.isEmpty {
            lines.append("  offline: \(summary.offlineVolumes.joined(separator: ", "))")
        }
        print(lines.joined(separator: "\n"))
        if summary.failures > 0 || !summary.offlineVolumes.isEmpty {
            throw ExitCode(1)
        }
    }

    /// `20,000`, whatever the locale.
    private static func count(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }
}

private extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
