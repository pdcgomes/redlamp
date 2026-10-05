import Foundation
import Testing
@testable import RedlampLibrary

struct FolderSignatureTests {
    static let date = Date(timeIntervalSince1970: 1_759_660_000.123456)
    static let entries = [
        FileEntry(name: "DSCF0001.RAF", size: 52_000_000, modified: date, fileIdentifier: 11),
        FileEntry(name: "DSCF0001.RAF.redlamp", isDirectory: true, isPackage: true, modified: date + 60),
        FileEntry(name: "DSCF0002.RAF", size: 51_000_000, modified: date + 1, fileIdentifier: 12),
        FileEntry(name: "DSCF0002.xmp", size: 1200, modified: date + 2),
        FileEntry(name: "Selects", isDirectory: true, modified: date + 3),
    ]

    static func replacing(_ index: Int, with entry: FileEntry) -> [FileEntry] {
        var entries = entries
        entries[index] = entry
        return entries
    }

    @Test func `a listing's signature doesn't depend on the order of its entries`() {
        let signature = FolderSignature(Self.entries)
        #expect(FolderSignature(Self.entries.reversed()) == signature)
        #expect(FolderSignature(Self.entries.shuffled()) == signature)
        #expect(FolderSignature([FileEntry]()) != signature)
    }

    @Test func `signatures change with names, sizes and dates`() {
        let signature = FolderSignature(Self.entries)
        let photo = Self.entries[0]
        let changed = [
            FileEntry(name: "DSCF0003.RAF", size: photo.size, modified: photo.modified),
            FileEntry(name: "dscf0001.raf", size: photo.size, modified: photo.modified),
            FileEntry(name: photo.name, size: photo.size + 1, modified: photo.modified),
            FileEntry(name: photo.name, size: photo.size, modified: photo.modified + 0.001),
        ].map { FolderSignature(Self.replacing(0, with: $0)) }
        #expect(changed.allSatisfy { $0 != signature })
        #expect(Set(changed).count == changed.count)
        let sidecarSaved = Self.replacing(1, with: FileEntry(
            name: "DSCF0001.RAF.redlamp", isDirectory: true, isPackage: true, modified: Self.date + 61,
        ))
        #expect(FolderSignature(sidecarSaved) != signature)
        #expect(FolderSignature(Self.entries.dropLast()) != signature)
        #expect(FolderSignature(Self.entries + [FileEntry(name: "notes.txt")]) != signature)
    }

    @Test func `a subfolder counts by its name, not by its date, which changes with what's in it`() {
        let signature = FolderSignature(Self.entries)
        let touched = FileEntry(name: "Selects", isDirectory: true, modified: Self.date + 999)
        #expect(FolderSignature(Self.replacing(4, with: touched)) == signature)
        let renamed = FileEntry(name: "Picks", isDirectory: true, modified: Self.date + 3)
        #expect(FolderSignature(Self.replacing(4, with: renamed)) != signature)
    }

    @Test func `a signature survives the index as an integer`() {
        let signature = FolderSignature(Self.entries)
        #expect(FolderSignature(rawValue: signature.rawValue) == signature)
        #expect(signature.description.count <= 16)
    }
}
