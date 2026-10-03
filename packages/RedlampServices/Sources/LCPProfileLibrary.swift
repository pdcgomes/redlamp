import Foundation
import os
import RedlampEngineAPI
import Synchronization

/// The Adobe lens profiles (LCP files) the user keeps in `Lens Profiles` under Application
/// Support/Redlamp, and its subfolders (LNS-04). The folder is listed each time a photo opens, and
/// a file is read again only when its modification date changes; a missing folder holds none.
public final class LCPProfileLibrary: Sendable {
    /// The user's profiles, which photos open with.
    public static let user = LCPProfileLibrary(directory: defaultDirectory)

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appending(path: "Redlamp/Lens Profiles", directoryHint: .isDirectory)
    }

    /// Larger files aren't lens profiles.
    static let largestFile = 32 << 20

    private struct File {
        var modified: Date
        var profile: LCPProfile?
        var issues: [String]
    }

    public let directory: URL
    private let files = Mutex<[URL: File]>([:])

    public init(directory: URL) {
        self.directory = directory
    }

    /// Files that couldn't be read, or whose sub-profiles were left out (fisheye ones), with the
    /// reasons, as of the last listing.
    public var issues: [URL: [String]] {
        files.withLock { files in files.compactMapValues { $0.issues.isEmpty ? nil : $0.issues } }
    }

    /// The correction for a raw photo from the profile for its camera and lens: one whose lens
    /// name is the one the file reports, else one whose display name is, the first by path among
    /// equals. Nil when none matches.
    public func correction(for info: ImageInfo, sensorSize: PixelSize, orientation: Int) -> LensCorrection? {
        guard let make = info.make, let lens = info.lens else { return nil }
        let matches = profiles().map { profile in
            let camera = profile.subProfiles.filter { $0.isRaw && $0.matchesCamera(make: make, model: info.model) }
            let match = camera.map { $0.lensMatch(lens, make: make) }.max() ?? .unmatched
            return (match: match, subProfiles: camera.filter { $0.lensMatch(lens, make: make) == match })
        }
        for wanted in [LCPProfile.SubProfile.LensMatch.lens, .prettyName] {
            for candidate in matches where candidate.match == wanted {
                if let correction = LCPProfile.correction(
                    candidate.subProfiles, focalLength: info.focalLength, aperture: info.aperture, size: sensorSize,
                    orientation: orientation,
                ) {
                    return correction
                }
            }
        }
        return nil
    }

    /// Every profile in the folder, by path, read again where its file changed.
    func profiles() -> [LCPProfile] {
        let listed = listing()
        return files.withLock { files in
            let paths = Set(listed.map(\.url))
            files = files.filter { paths.contains($0.key) }
            return listed.compactMap { url, modified, size in
                if files[url]?.modified != modified {
                    files[url] = Self.read(url, modified: modified, size: size)
                }
                return files[url]?.profile
            }
        }
    }

    /// The folder's LCP files with their modification dates and sizes, by path.
    private func listing() -> [(url: URL, modified: Date, size: Int)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true },
        ) else { return [] }
        return enumerator.compactMap { item -> (url: URL, modified: Date, size: Int)? in
            guard let url = item as? URL, url.pathExtension.lowercased() == "lcp",
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let modified = values.contentModificationDate
            else { return nil }
            return (url, modified, values.fileSize ?? 0)
        }.sorted { $0.url.path < $1.url.path }
    }

    private static func read(_ url: URL, modified: Date, size: Int) -> File {
        var file = File(modified: modified, profile: nil, issues: [])
        if size > largestFile {
            file.issues = ["larger than a lens profile can be"]
        } else {
            do {
                let profile = try LCPProfile(data: Data(contentsOf: url))
                file.profile = profile
                file.issues = profile.skipped
            } catch {
                file.issues = ["\(error)"]
            }
        }
        if !file.issues.isEmpty {
            Logger(subsystem: "app.redlamp.services", category: "lens-profiles").notice(
                "\(url.lastPathComponent, privacy: .public): \(file.issues.joined(separator: "; "), privacy: .public)",
            )
        }
        return file
    }
}
