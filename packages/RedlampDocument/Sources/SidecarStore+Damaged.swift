import Foundation

/// A damaged edit (`SidecarProtection.damaged`) is set aside in its package, never deleted, so the
/// photo can start a new edit and the old one can still be recovered by hand.
public extension SidecarStore {
    /// Moves the image's damaged edit aside in its sidecar as `edit.damaged-<date>.json`, so the
    /// photo opens with no edit and its next save starts a new one; its history and masks stay.
    /// A single-file sidecar becomes a package holding it. Returns the copy, or nil when there is
    /// no damaged edit (another app replaced it, say), leaving the sidecar as it is.
    @discardableResult
    func setAsideDamagedEdit(for image: URL, at date: Date = Date()) throws -> URL? {
        let destination = url(for: image)
        let options: NSFileCoordinator.WritingOptions = Self.isPackage(destination) ? [] : .forReplacing
        return try Self.writing(destination, options: options) { sidecar in
            guard let data = try Self.editData(inSidecar: sidecar), Self.isDamaged(data) else { return nil }
            let fileManager = FileManager.default
            if Self.isPackage(sidecar) {
                let copy = Self.damagedCopy(in: sidecar, at: date)
                try fileManager.moveItem(at: Self.editURL(inSidecar: sidecar), to: copy)
                return copy
            }
            // Built beside it, then moved in: an interrupted one leaves the file as it was.
            let staging = Self.hiddenSibling(of: sidecar)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
            do {
                let name = Self.damagedCopy(in: staging, at: date).lastPathComponent
                try fileManager.copyItem(at: sidecar, to: staging.appending(path: name))
                _ = try fileManager.replaceItemAt(sidecar, withItemAt: staging)
                return sidecar.appending(path: name)
            } catch {
                try? fileManager.removeItem(at: staging)
                throw error
            }
        }
    }
}

extension SidecarStore {
    static let damagedPrefix = "edit.damaged-"

    /// The damaged edits set aside in the package at `sidecar`, oldest first.
    static func damagedCopies(in sidecar: URL) -> [URL] {
        guard isPackage(sidecar), let names = try? FileManager.default.contentsOfDirectory(atPath: sidecar.path)
        else { return [] }
        return names.filter { $0.hasPrefix(damagedPrefix) && $0.hasSuffix(".json") }.sorted()
            .map { sidecar.appending(path: $0) }
    }

    /// `edit.damaged-2026-10-06-071500.json`, or `…-2.json` and on when one by that name is there.
    private static func damagedCopy(in package: URL, at date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let stamp = formatter.string(from: date)
        var copy = package.appending(path: "\(damagedPrefix)\(stamp).json")
        var number = 2
        while FileManager.default.fileExists(atPath: copy.path) {
            copy = package.appending(path: "\(damagedPrefix)\(stamp)-\(number).json")
            number += 1
        }
        return copy
    }
}
