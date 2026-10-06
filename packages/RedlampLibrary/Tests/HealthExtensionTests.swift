import Foundation
import Testing
@testable import RedlampLibrary

/// Library Health's wrong extensions (LIB-40): a file's first bytes against its extension's family.
struct HealthExtensionTests {
    @Test func `a wrong extension is found with the name its format takes`() async throws {
        let sandbox = try await HealthSandbox.make([
            "Shoot/IMG_1.JPG": HealthImages.data(.heic, seed: 1),
            "Shoot/IMG_2.cr3": HealthImages.data(.jpeg, seed: 2),
            "Shoot/IMG_3.jpg": HealthImages.data(.jpeg, seed: 3),
            "Shoot/IMG_4.png": HealthImages.data(.jpeg, seed: 4),
            "Shoot/IMG_4.jpg": HealthImages.data(.jpeg, seed: 5),
        ])
        defer { sandbox.remove() }
        await sandbox.index()
        let found = try await sandbox.library().findings(.extensions)
        #expect(try await sandbox.paths(found.photos) == ["Shoot/IMG_1.JPG", "Shoot/IMG_2.cr3", "Shoot/IMG_4.png"])
        #expect(found.findings.map(\.reason.description) == [
            "named .JPG, holds HEIC", "named .cr3, holds JPEG", "named .png, holds JPEG",
        ])
        #expect(found.findings.map(\.proposal) == [.rename(to: "IMG_1.HEIC"), .rename(to: "IMG_2.jpg"), nil])
        #expect(found.proposed == Array(found.photos.prefix(2)), "a name another photo of its folder has is left")
    }

    @Test func `a TIFF-based raw's extension is never flagged for another's`() async throws {
        let head = try HealthImages.rawHead
        let sandbox = try await HealthSandbox.make([
            "Raws/A.ARW": head, "Raws/B.NEF": head, "Raws/C.DNG": head, "Raws/D.cr2": head, "Raws/E.tif": head,
            "Raws/F.JPG": head,
        ])
        defer { sandbox.remove() }
        await sandbox.index()
        let found = try await sandbox.library().findings(.extensions)
        #expect(try await sandbox.paths(found.photos) == ["Raws/F.JPG"])
        #expect(found.findings.first?.reason.description == "named .JPG, holds TIFF")
        #expect(found.findings.first?.proposal == .rename(to: "F.ARW"), "the raw its maker writes")
    }
}
