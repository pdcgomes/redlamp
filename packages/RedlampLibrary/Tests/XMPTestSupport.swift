import Foundation
import RedlampDocument
import RedlampEngineAPI
import Testing
@testable import RedlampLibrary

/// Photos in a folder of their own, their sidecars and other apps' `.xmp`, and an index of them in
/// a library folder of its own, for the XMP tests.
struct XMPSandbox {
    let folder: TemporaryFolder
    let library: TemporaryFolder
    let index: LibraryIndex

    var root: URL {
        folder.url
    }

    var xmp: LibraryXMP {
        LibraryXMP(index: index)
    }

    static func make() async throws -> XMPSandbox {
        let library = try TemporaryFolder()
        let index = try await LibraryIndex.open(at: library.url.appending(path: "Index.sqlite"), readers: 2)
        return try XMPSandbox(folder: TemporaryFolder(), library: library, index: index)
    }

    func remove() {
        index.closeAndWait()
    }

    func url(_ path: String) -> URL {
        root.appending(path: path)
    }

    /// A photo's bytes at `path`: nothing ImageIO reads, which the library indexes all the same.
    @discardableResult
    func photo(_ path: String) throws -> URL {
        let file = url(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not an image: \(path)".utf8).write(to: file)
        try setModified(path, -86400)
        return file
    }

    func write(_ path: String, _ text: String, modified: TimeInterval? = nil) throws {
        try Data(text.utf8).write(to: url(path))
        if let modified {
            try setModified(path, modified)
        }
    }

    func text(_ path: String) throws -> String {
        try String(decoding: Data(contentsOf: url(path)), as: UTF8.self)
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: url(path).path)
    }

    /// Sets the file's modification date `offset` seconds from now: other apps' writes come after
    /// Redlamp's when they're later.
    func setModified(_ path: String, _ offset: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: offset)], ofItemAtPath: url(path).path,
        )
    }

    /// Saves `metadata` in the photo's `.redlamp` through `store`, with an edit, a snapshot and a field
    /// a newer Redlamp wrote, which a merge must keep.
    func sidecar(_ path: String, _ metadata: PhotoMetadata, store: SidecarStore = SidecarStore()) throws {
        var recipe = EditRecipe()
        recipe[.exposure] = 0.35
        var sidecar = Sidecar(
            recipe: recipe, snapshots: [Snapshot(name: "Before", recipe: EditRecipe())], metadata: metadata,
            modified: Date(timeIntervalSinceNow: -3600),
        )
        sidecar.unknownFields = ["fromTheFuture": .string("kept")]
        try store.save(sidecar, for: url(path))
    }

    func indexAll() async throws {
        let run = await IndexerRun.collect(LibraryIndexer(index: index, configuration: .testing()).index([root]))
        #expect(run.failures.isEmpty, "\(run.failures)")
    }

    /// The photo's ID, by its path below the root.
    func id(_ path: String) async throws -> Int64 {
        let full = LibraryIndexer.path(url(path))
        return try #require(try await index.read { try $0.photo(path: full) }?.id)
    }

    func allIDs() async throws -> [Int64] {
        try await index.read { reader in
            var ids: [Int64] = []
            try reader.scanHotColumns { ids.append($0.id) }
            return ids
        }
    }

    func sync(_ paths: [String]? = nil, writing: Bool? = nil, dryRun: Bool = false) async throws -> XMPReport {
        var ids: [Int64] = []
        if let paths {
            for path in paths {
                try await ids.append(id(path))
            }
        } else {
            ids = try await allIDs()
        }
        return try await xmp.sync(ids, writing: writing, dryRun: dryRun)
    }

    func metadata(_ path: String, store: SidecarStore = SidecarStore()) -> PhotoMetadata? {
        store.load(for: url(path))?.metadata
    }
}

extension XMPReport {
    func photo(_ name: String) -> XMPPhotoSync? {
        photos.first { ($0.path as NSString).lastPathComponent == name }
    }
}

/// Other apps' sidecars, as they write them.
enum OtherApps {
    /// As Lightroom Classic writes one, with its develop settings, a namespace of its own and a
    /// comment beside what Redlamp reads.
    static func lightroom(rating: Int, label: String? = nil, keywords: [String] = []) -> String {
        let label = label.map { "\n   xmp:Label=\"\($0)\"" } ?? ""
        let paths = keywords.map { "     <rdf:li>\($0.replacingOccurrences(of: "/", with: "|"))</rdf:li>" }
            .joined(separator: "\n")
        return """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0-c000 1.000000, 0000/00/00-00:00:00        ">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
            xmlns:lr="http://ns.adobe.com/lightroom/1.0/"
            xmlns:acme="http://example.com/acme/1.0/"
           xmp:Rating="\(rating)"\(label)
           crs:Version="17.0"
           crs:Exposure2012='+0.35'
           acme:Reviewed="yes">
           <!-- written by Lightroom Classic -->
           <lr:hierarchicalSubject>
            <rdf:Bag>
        \(paths)
            </rdf:Bag>
           </lr:hierarchicalSubject>
           <crs:ToneCurvePV2012>
            <rdf:Seq>
             <rdf:li>0, 0</rdf:li>
             <rdf:li>255, 255</rdf:li>
            </rdf:Seq>
           </crs:ToneCurvePV2012>
           <acme:Notes><rdf:Alt><rdf:li xml:lang="x-default">Keep &amp; print</rdf:li></rdf:Alt></acme:Notes>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>

        """
    }

    /// As darktable writes its own, `IMG_1234.ARW.xmp`.
    static func darktable(rating: Int, colorLabel: Int) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="XMP Core 4.4.0-Exiv2">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:darktable="http://darktable.sf.net/"
           xmp:Rating="\(rating)"
           darktable:xmp_version="5">
           <darktable:colorlabels>
            <rdf:Seq>
             <rdf:li>\(colorLabel)</rdf:li>
            </rdf:Seq>
           </darktable:colorlabels>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>

        """
    }
}
