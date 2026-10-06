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
    /// leaves it whole or gone, never a package without its edit. Damaged edits set aside stay,
    /// for recovery, with the masks they name (all of them while one can't be read): the rest of
    /// the package goes, its edit first.
    static func remove(_ url: URL) throws {
        let fileManager = FileManager.default
        let hidden = hiddenSibling(of: url)
        let copies = damagedCopies(in: url)
        guard !copies.isEmpty else {
            try fileManager.moveItem(at: url, to: hidden)
            try fileManager.removeItem(at: hidden)
            return
        }
        let kept = Set(copies.map(\.lastPathComponent) + [masksDirectory])
        let rest = try fileManager.contentsOfDirectory(atPath: url.path).filter { !kept.contains($0) }
        let masks = url.appending(path: masksDirectory)
        let written = copies.compactMap { try? Data(contentsOf: $0) }
        let bitmaps = written.count < copies
            .count ? [] : (try? fileManager.contentsOfDirectory(atPath: masks.path)) ?? []
        let unnamed = bitmaps.filter { !$0.hasSuffix(".png") || !isNamed(String($0.dropLast(4)), in: written) }
        try fileManager.createDirectory(at: hidden, withIntermediateDirectories: false)
        for name in rest.filter({ $0 == editFile }) + rest.filter({ $0 != editFile }) {
            try fileManager.moveItem(at: url.appending(path: name), to: hidden.appending(path: name))
        }
        if !unnamed.isEmpty {
            let hiddenMasks = hidden.appending(path: masksDirectory)
            try fileManager.createDirectory(at: hiddenMasks, withIntermediateDirectories: false)
            for name in unnamed {
                try fileManager.moveItem(at: masks.appending(path: name), to: hiddenMasks.appending(path: name))
            }
        }
        if fileManager.fileExists(atPath: masks.path), try fileManager.contentsOfDirectory(atPath: masks.path).isEmpty {
            try fileManager.removeItem(at: masks)
        }
        try fileManager.removeItem(at: hidden)
    }
}
