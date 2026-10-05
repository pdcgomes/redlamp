import Foundation
import RedlampDocument
import Synchronization

/// Which `SidecarStore` reads and writes each photo's sidecar (LIB-11, DEC-36): one through the
/// library's locator for a photo in a folder whose sidecars are kept on this Mac, or that has some
/// there, and `SidecarStore()` for every other photo, which saves as it always has.
///
/// The library sets the locator once its index is open and again when a folder's placement
/// changes. It starts from the one it had when the app last ran, kept in the defaults, so a photo
/// that opens at launch, before the index does, saves where its edits are.
public final class SidecarPlacement: Sendable {
    private let current: Mutex<SidecarLocator>

    public init(locator: SidecarLocator = .besidePhotos) {
        current = Mutex(locator)
    }

    public var locator: SidecarLocator {
        get { current.withLock { $0 } }
        set { current.withLock { $0 = newValue } }
    }

    /// The store `photo`'s sidecar is read and written through.
    public func store(for photo: URL) -> SidecarStore {
        let locator = locator
        return locator.onThisMac(photo) == nil ? SidecarStore() : SidecarStore(locator: locator)
    }
}

extension SidecarLocator {
    /// The locator as the defaults keep it between launches.
    private struct Saved: Codable {
        struct Root: Codable {
            var path: String
            var volume: String
            var pathInVolume: String
            var onThisMac: Bool
        }

        var folder: String
        var roots: [Root]
    }

    static let defaultsKey = "library.sidecarLocator"

    /// The locator saved in `defaults`, if any.
    static func saved(in defaults: UserDefaults) -> SidecarLocator? {
        guard let data = defaults.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode(Saved.self, from: data)
        else { return nil }
        return SidecarLocator(
            folder: URL(fileURLWithPath: saved.folder, isDirectory: true),
            roots: saved.roots.map {
                Root(path: $0.path, volume: $0.volume, pathInVolume: $0.pathInVolume, onThisMac: $0.onThisMac)
            },
        )
    }

    func save(in defaults: UserDefaults) {
        guard let folder else {
            defaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        let saved = Saved(folder: folder.path, roots: roots.map {
            Saved.Root(path: $0.path, volume: $0.volume, pathInVolume: $0.pathInVolume, onThisMac: $0.onThisMac)
        })
        defaults.set(try? JSONEncoder().encode(saved), forKey: Self.defaultsKey)
    }
}
