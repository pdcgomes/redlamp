import Foundation

/// A camera's card in a folder, as the import scenario and its tests write it: `DCIM/<folder>` holding
/// camera JPEGs with their EXIF (the fixture's encoded images, padded to a camera file's size) and raws
/// cloned from the CC0 raws, each with the sidecars given for it.
enum SimulatedCard {
    struct Shot: Sendable {
        var name: String
        /// When it was taken, by the camera's clock, read as UTC.
        var captured: Date
        var folder = "100CANON"
        var make: String? = "Canon"
        var model: String? = "Canon EOS R6"
        /// Bytes after the JPEG's end, where decoders don't look: a camera JPEG's size.
        var padding = 0
        /// A raw to clone under `name`, rather than a JPEG.
        var raw: URL?
        /// What the file holds, rather than a JPEG.
        var contents: Data?
        /// Files beside it, by name, or by path for a package's.
        var sidecars: [String: Data] = [:]
    }

    /// The CC0 raws in `folder`, one of each kind.
    static func raws(in folder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var seen = Set<String>()
        return names.sorted().compactMap { name in
            let ext = NamingJob.split(name).ext.lowercased()
            guard NamingJob.isRaw(ext), seen.insert(ext).inserted else { return nil }
            return folder.appending(path: name)
        }
    }

    /// `count` shots a second apart over two days from 5 October 2026 at 09:00: JPEGs of about 300 KB,
    /// with a raw of each of `raws` beside the JPEG of every hundredth shot until they run out.
    static func shots(_ count: Int, raws: [URL]) -> [Shot] {
        let start = Date(timeIntervalSince1970: 1_791_190_800)
        var shots: [Shot] = []
        var raws = raws[...]
        var number = 1
        while shots.count < count {
            let captured = start.addingTimeInterval(Double(number) + (number > count / 2 ? 86400 : 0))
            let base = String(format: "IMG_%04d", number)
            if number % 100 == 0, let raw = raws.popFirst(), shots.count + 1 < count {
                shots.append(Shot(name: base + "." + raw.pathExtension.uppercased(), captured: captured, raw: raw))
            }
            shots.append(Shot(name: base + ".JPG", captured: captured, padding: 280_000 + number % 7 * 10000))
            number += 1
        }
        return shots
    }

    /// Writes the shots below `card`/DCIM.
    static func write(_ shots: [Shot], to card: URL) throws {
        let images = try FixtureImages.shared.get()
        for (number, shot) in shots.enumerated() {
            let folder = card.appending(path: ImportSource.cameraFolder).appending(path: shot.folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: shot.name)
            if let raw = shot.raw {
                if clonefile(raw.path, file.path, 0) != 0 {
                    try FileManager.default.copyItem(at: raw, to: file)
                }
            } else if let contents = shot.contents {
                try contents.write(to: file)
            } else {
                var data = images.data(for: photo(shot, number: number))
                var random = SeededRandom(seed: UInt64(number))
                data.append(contentsOf: (0 ..< shot.padding).map { _ in UInt8(truncatingIfNeeded: random.next()) })
                try data.write(to: file)
            }
            try FileManager.default.setAttributes(
                [.modificationDate: shot.captured.addingTimeInterval(-Double(TimeZone.current.secondsFromGMT()))],
                ofItemAtPath: file.path,
            )
            for (name, contents) in shot.sidecars {
                let sidecar = folder.appending(path: name)
                try FileManager.default.createDirectory(
                    at: sidecar.deletingLastPathComponent(), withIntermediateDirectories: true,
                )
                try contents.write(to: sidecar)
            }
        }
    }

    /// The fixture photo whose JPEG stands for `shot`.
    static func photo(_ shot: Shot, number: Int) -> FixturePhoto {
        let seconds = Int(shot.captured.timeIntervalSince1970)
        let days = Int((Double(seconds) / 86400).rounded(.down))
        return FixturePhoto(
            index: number, folder: shot.folder, name: shot.name, kind: .jpeg, make: shot.make, model: shot.model,
            lens: nil, iso: 400, aperture: 2.8, exposureTime: 1.0 / 250, focalLength: 35,
            captured: FixtureDate(days: days, seconds: seconds - days * 86400), location: nil, embeddedKeywords: [],
            caption: nil, sidecar: nil, xmp: nil, source: nil, original: nil,
        )
    }
}
