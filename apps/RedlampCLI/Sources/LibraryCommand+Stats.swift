import Foundation
import RedlampLibrary

extension LibraryCommand {
    /// `redlamp library stats`: what the library at an index holds (LIB-12): its photos and folders,
    /// its roots and where each keeps its sidecars, its volumes and which are offline, how many photos
    /// are edited, rated, flagged and labelled, and its index's and store's sizes.
    static func stats(_ arguments: [String]) async throws {
        let options = try Arguments(arguments, valued: ["--index"])
        guard options.positional.isEmpty, let path = options.value("--index") else {
            throw CLIError(description: "stats needs --index\n\n\(usage)")
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError(description: "no index at \(url.path) (make one with redlamp library index)")
        }
        let index = try await LibraryIndex.open(at: url)
        let statistics = try await LibraryStatistics.read(
            index: index, paths: LibraryPaths(root: url.deletingLastPathComponent()),
        )
        await index.close()

        if options.has("--json") {
            struct Root: Encodable {
                let path: String
                let sidecars: String
                let photos: Int
            }
            struct Volume: Encodable {
                let uuid: String
                let name: String?
                let kind: String
                let offline: Bool
                let photos: Int
            }
            struct Output: Encodable {
                let index: String
                let photos: Int
                let folders: Int
                let edited: Int
                let rated: Int
                let picked: Int
                let rejected: Int
                let labelled: Int
                let roots: [Root]
                let volumes: [Volume]
                let indexBytes: Int64
                let storeBytes: Int64
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let output = Output(
                index: url.path, photos: statistics.photos, folders: statistics.folders, edited: statistics.edited,
                rated: statistics.rated, picked: statistics.picked, rejected: statistics.rejected,
                labelled: statistics.labelled,
                roots: statistics.roots.map { Root(
                    path: $0.path,
                    sidecars: placementName($0.sidecars),
                    photos: $0.photos,
                ) },
                volumes: statistics.volumes.map { volume in
                    Volume(
                        uuid: volume.uuid, name: volume.name, kind: kindName(volume.kind), offline: volume.isOffline,
                        photos: volume.photos,
                    )
                },
                indexBytes: statistics.indexBytes, storeBytes: statistics.storeBytes,
            )
            try print(String(decoding: encoder.encode(output), as: UTF8.self))
            return
        }
        var lines = [
            "\(count(statistics.photos)) photos in \(count(statistics.folders)) folders, in \(url.path)",
            "  \(count(statistics.edited)) edited, \(count(statistics.rated)) rated, \(count(statistics.picked)) picked, "
                + "\(count(statistics.rejected)) rejected, \(count(statistics.labelled)) labelled",
            "  roots:",
        ]
        lines += statistics.roots.map { root in
            "    \(root.path): \(count(root.photos)) photos, sidecars \(placementDescription(root.sidecars))"
        }
        lines.append("  volumes:")
        lines += statistics.volumes.map { volume in
            "    \(volume.name ?? volume.uuid) (\(kindName(volume.kind))): \(count(volume.photos)) photos"
                + (volume.isOffline ? ", offline" : "")
        }
        lines.append("  index \(megabytes(statistics.indexBytes)), store \(megabytes(statistics.storeBytes))")
        print(lines.joined(separator: "\n"))
    }

    /// `beside` or `mac`, as `redlamp library sidecars --move` takes them.
    static func placementName(_ placement: RootRecord.Sidecars) -> String {
        switch placement {
        case .besidePhotos: "beside"
        case .onThisMac: "mac"
        }
    }

    static func placementDescription(_ placement: RootRecord.Sidecars) -> String {
        switch placement {
        case .besidePhotos: "beside the photos"
        case .onThisMac: "on this Mac"
        }
    }

    private static func kindName(_ kind: VolumeRecord.Kind) -> String {
        switch kind {
        case .unknown: "unknown"
        case .ssd: "ssd"
        case .spinning: "spinning"
        case .network: "network"
        }
    }

    /// `12.3 MB`.
    private static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }

    /// `20,000`, whatever the locale.
    private static func count(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }
}
