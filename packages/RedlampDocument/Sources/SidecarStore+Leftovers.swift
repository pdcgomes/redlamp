import Foundation

/// Sidecars are built and removed under hidden names beside the photo, so an interrupted save or
/// delete leaves the visible sidecar whole and a hidden leftover that a later folder open removes.
public extension SidecarStore {
    /// Removes what interrupted saves and deletes left in `folder`, hidden sidecars named as
    /// `hiddenSibling(of:)` names them, once unchanged for `age`: a younger one may still be
    /// being written.
    static func removeLeftovers(in folder: URL, olderThan age: TimeInterval = 60) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        let cutoff = Date(timeIntervalSinceNow: -age)
        for name in names where isLeftover(name) {
            let leftover = folder.appending(path: name)
            guard let modified = try? leftover.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate, modified < cutoff
            else { continue }
            try? writing(leftover, options: .forDeleting) { try FileManager.default.removeItem(at: $0) }
        }
    }
}

extension SidecarStore {
    /// A hidden name beside `sidecar`, `.<photo>.redlamp.<UUID>`, to build or remove it under.
    static func hiddenSibling(of sidecar: URL) -> URL {
        sidecar.deletingLastPathComponent().appending(path: ".\(sidecar.lastPathComponent).\(UUID().uuidString)")
    }

    static func isLeftover(_ name: String) -> Bool {
        let parts = name.split(separator: ".")
        return name.hasPrefix(".") && parts.count >= 3 && parts[parts.count - 2] == "redlamp"
            && UUID(uuidString: String(parts[parts.count - 1])) != nil
    }

    /// Removes the sidecar at `url` by moving it to a hidden name first, so an interrupted removal
    /// leaves it whole or gone, never a package without its edit.
    static func remove(_ url: URL) throws {
        let hidden = hiddenSibling(of: url)
        try FileManager.default.moveItem(at: url, to: hidden)
        try FileManager.default.removeItem(at: hidden)
    }
}
