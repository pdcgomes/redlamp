import CoreGraphics
import Foundation
import ImageIO
import RedlampDocument
import RedlampEngineAPI
import Testing
@testable import RedlampLibrary

struct FixtureTests {
    static let rawFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "tests/fixtures/raw")
    static let sources = (try? RawSource.sources(in: rawFolder)) ?? []
    static let spec = LibraryFixture.Spec(photos: 300, seed: 42)

    /// A fixture written on the raws' own volume, where its raws are clones of them.
    static func written(
        _ spec: LibraryFixture.Spec = spec,
    ) throws -> (folder: TemporaryFolder, fixture: LibraryFixture, summary: LibraryFixture.WriteSummary) {
        try #require(!sources.isEmpty, "the CC0 raws in tests/fixtures/raw")
        let folder = try TemporaryFolder(on: rawFolder)
        let fixture = LibraryFixture(spec: spec, rawSources: sources)
        return try (folder, fixture, fixture.write(to: folder.url))
    }

    /// Every file below `root`, packages' contents included, by path, with its size.
    static func files(in root: URL) throws -> [String: Int] {
        var found: [String: Int] = [:]
        for path in try FileManager.default.subpathsOfDirectory(atPath: root.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: root.path + "/" + path)
            if attributes[.type] as? FileAttributeType == .typeRegular {
                found[path] = (attributes[.size] as? NSNumber)?.intValue
            }
        }
        return found
    }

    static func properties(_ url: URL) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    @Test func `a fixture made twice from one seed has the same files, sizes and manifest`() throws {
        let first = try Self.written()
        let second = try Self.written()
        let files = try Self.files(in: first.folder.url)
        #expect(files.count > 300)
        #expect(try Self.files(in: second.folder.url) == files)
        #expect(second.summary.manifest == first.summary.manifest)
        #expect(
            try Data(contentsOf: first.folder.url.appending(path: FixtureManifest.fileName))
                == Data(contentsOf: second.folder.url.appending(path: FixtureManifest.fileName)),
        )
        #expect(first.summary.manifest == first.fixture.manifest())
        #expect(first.summary.written == 300 && first.summary.skipped == 0)
        let reseeded = LibraryFixture(spec: .init(photos: 300, seed: 43), rawSources: Self.sources)
        #expect(reseeded.manifest().queries != first.summary.manifest.queries)
    }

    @Test func `the JPEGs and HEICs carry the EXIF, TIFF, GPS and IPTC their records say`() throws {
        let (folder, fixture, _) = try Self.written()
        let photos = (0 ..< 300).map(fixture.photo(at:)).filter { $0.kind != .raw }
        #expect(photos.contains { $0.kind == .heic })
        #expect(photos.contains { $0.location != nil } && photos.contains { $0.caption != nil })
        for photo in photos {
            let url = folder.url.appending(path: photo.path)
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            #expect(CGImageSourceGetType(source) as String? == (photo.kind == .heic ? "public.heic" : "public.jpeg"))
            let properties = try Self.properties(url)
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            let aux = properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
            let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
            let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
            #expect(tiff[kCGImagePropertyTIFFMake] as? String == photo.make, "\(photo.path)")
            #expect(tiff[kCGImagePropertyTIFFModel] as? String == photo.model)
            let lens = exif[kCGImagePropertyExifLensModel] ?? aux[kCGImagePropertyExifAuxLensModel]
            #expect(lens as? String == photo.lens)
            #expect(exif[kCGImagePropertyExifDateTimeOriginal] as? String == photo.captured.exif)
            #expect((exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first == photo.iso)
            #expect(isNear(exif[kCGImagePropertyExifFNumber], photo.aperture))
            #expect(isNear(exif[kCGImagePropertyExifExposureTime], photo.exposureTime))
            #expect(isNear(exif[kCGImagePropertyExifFocalLength], photo.focalLength))
            if let location = photo.location {
                let latitude = (gps[kCGImagePropertyGPSLatitude] as? Double ?? 0)
                    * (gps[kCGImagePropertyGPSLatitudeRef] as? String == "S" ? -1 : 1)
                let longitude = (gps[kCGImagePropertyGPSLongitude] as? Double ?? 0)
                    * (gps[kCGImagePropertyGPSLongitudeRef] as? String == "W" ? -1 : 1)
                #expect(abs(latitude - location.latitude) < 1e-4 && abs(longitude - location.longitude) < 1e-4)
            } else {
                #expect(gps[kCGImagePropertyGPSLatitude] == nil)
            }
            #expect(iptc[kCGImagePropertyIPTCKeywords] as? [String] ?? [] == photo.embeddedKeywords)
            #expect(iptc[kCGImagePropertyIPTCCaptionAbstract] as? String == photo.caption)
        }
    }

    @Test func `raws are clones of their sources with their own capture date rewritten in place`() throws {
        let (folder, fixture, _) = try Self.written()
        let raws = (0 ..< 300).map(fixture.photo(at:)).filter { $0.kind == .raw }
        #expect(raws.count > 30)
        #expect(Set(raws.compactMap(\.source)).count == Self.sources.count)
        var read = Set<Int>()
        for raw in raws {
            let index = try #require(raw.source)
            let source = Self.sources[index]
            let url = folder.url.appending(path: raw.path)
            let header = try LocalFileSystem().read(url, range: 0 ..< RawSource.headerSize)
            #expect(RawSource.dateOffsets(in: header) == source.dateOffsets)
            for offset in source.dateOffsets {
                #expect(String(decoding: header[offset ..< offset + 19], as: UTF8.self) == raw.captured.exif)
            }
            #expect(try LocalFileSystem().attributes(of: url).size == source.size)
            #expect(raw.name.hasSuffix("." + source.url.pathExtension))
            // ImageIO takes tens of milliseconds a raw, so it reads one clone of each source.
            guard read.insert(index).inserted else { continue }
            let properties = try Self.properties(url)
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            #expect(exif[kCGImagePropertyExifDateTimeOriginal] as? String == raw.captured.exif, "\(raw.name)")
            #expect(tiff[kCGImagePropertyTIFFModel] as? String == source.model)
        }
        for source in Self.sources {
            #expect(try RawSource.load(source.url) == source)
        }
    }

    @Test func `a fixture on another volume clones its raws from copies in a hidden folder`() throws {
        let source = try #require(Self.sources.min { $0.size < $1.size })
        let folder = try TemporaryFolder()
        let fixture = LibraryFixture(spec: .init(photos: 12, seed: 3, rawShare: 1, shapes: []), rawSources: [source])
        let summary = try fixture.write(to: folder.url)
        #expect(summary.manifest.totals.raws == 12)
        let files = LocalFileSystem()
        let elsewhere = try files.volume(of: folder.url).uuid != files.volume(of: Self.rawFolder).uuid
        let copies = folder.url.appending(path: LibraryFixture.sourcesFolder, directoryHint: .isDirectory)
        #expect(FileManager.default.fileExists(atPath: copies.appending(path: source.name).path) == elsewhere)
        if elsewhere {
            #expect(try copies.resourceValues(forKeys: [.isHiddenKey]).isHidden == true)
        }
        #expect(try !files.contentsOfDirectory(at: folder.url).contains { $0.name == LibraryFixture.sourcesFolder })
        let raw = fixture.photo(at: 0)
        let exif = try Self.properties(folder.url.appending(path: raw.path))[kCGImagePropertyExifDictionary]
        #expect((exif as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] as? String == raw.captured.exif)
    }

    @Test func `the manifest counts what each query must return, as a count over the photos does`() {
        let fixture = LibraryFixture(spec: Self.spec, rawSources: Self.sources)
        let manifest = fixture.manifest()
        let photos = (0 ..< 300).map(fixture.photo(at:))
        let raw = SupportedFormats.rawExtensions
        // Counted here without the corpus's own predicates.
        let expected: [String: Int] = [
            "rating>=3": photos.count { ($0.sidecar?.rating ?? $0.xmp?.rating ?? 0) >= 3 },
            "flag:pick": photos.count { $0.sidecar?.flag == .pick },
            "-flag:reject": photos.count { $0.sidecar?.flag != .reject },
            "label:red,blue": photos.count { [.red, .blue].contains($0.sidecar?.label ?? $0.xmp?.label) },
            "edited:yes": photos.count { $0.sidecar?.edited == true },
            "camera:\"X-T5\"": photos.count { $0.model == "X-T5" },
            "iso<=800": photos.count { $0.iso.map { $0 <= 800 } ?? false },
            "date:2019-06..2019-08": photos
                .count { ["2019:06", "2019:07", "2019:08"].contains($0.captured.exif.prefix(7)) },
            "has:gps": photos.count { $0.location != nil },
            "kw:birds": photos
                .count { $0.embeddedKeywords.contains("birds") || $0.xmp?.keywords.contains("birds") == true },
            "type:raw": photos.count { raw.contains(($0.name as NSString).pathExtension.lowercased()) },
            "in:\"Clients\"": photos.count { $0.folder.hasPrefix("Clients/") },
            "sunset": photos
                .count { $0.keywords.contains("sunset") || $0.caption?.lowercased().contains("sunset") == true },
        ]
        for (query, count) in expected {
            #expect(manifest.count(of: query) == count, "\(query)")
        }
        for query in FixtureQuery.corpus {
            #expect(manifest.count(of: query.text) == photos.count(where: query.matches), "\(query.text)")
        }
        #expect(manifest.queries.count == FixtureQuery.corpus.count && manifest.queries.count >= 30)
        #expect(manifest.queries.filter { $0.count == 0 }.count < 5)

        let totals = manifest.totals
        #expect(totals.photos == 300 && totals.raws + totals.jpegs + totals.heics == 300)
        #expect(manifest.folders.reduce(0) { $0 + $1.photos } == 300)
        #expect(totals.folders == manifest.folders.count)
        #expect((40 ... 85).contains(totals.raws))
        #expect((25 ... 70).contains(totals.sidecars))
        #expect((5 ... 30).contains(totals.xmpSidecars))
        #expect((70 ... 130).contains(totals.withLocation))
        #expect(photos.allSatisfy { $0.sidecar == nil || $0.xmp == nil })
    }

    @Test func `the folders take every shape: days, clients, one big folder, a deep tree, Unicode and long names`() {
        let fixture = LibraryFixture(spec: .init(photos: 2000, seed: 5))
        let paths = fixture.allFolderPaths
        let photos = (0 ..< 2000).map(fixture.photo(at:))
        #expect(fixture.folders.first { $0.shape == .bigFolder }?.photos.count == 400)
        #expect(paths.contains { $0.hasPrefix("Imports/") && $0.hasSuffix(" Card Dump") })
        #expect(paths.contains { $0.hasPrefix("Archive/") && $0.split(separator: "/").count == 12 })
        #expect(paths.contains { $0.contains("Été à Montréal") } && paths.contains { $0.contains("日本") })
        #expect(photos.contains { $0.name.hasPrefix("Café-") } && photos.contains { $0.name.hasPrefix("東京-") })
        #expect(paths.contains { $0.split(separator: "/").contains { $0.count == 200 } })
        #expect(photos.contains { $0.name.count == 200 })
        #expect(paths.contains { $0.hasPrefix("Clients/") && $0.split(separator: "/").count == 3 })
        let days = fixture.folders.filter { $0.shape == .years }
        #expect(days.count > 3 && days.dropLast().allSatisfy { (100 ... 200).contains($0.photos.count) })
        #expect(days.allSatisfy { $0.path.wholeMatch(of: /\d{4}\/\d{4}-\d\d-\d\d [A-Za-z ]+( \d+)?/) != nil })
        for folder in fixture.folders {
            let names = photos[folder.photos].map(\.name)
            #expect(Set(names).count == names.count && Set(photos[folder.photos].map(\.xmpName)).count == names.count)
        }
        let large = LibraryFixture(spec: .init(photos: 100_000, seed: 1))
        #expect(large.folders.first { $0.shape == .bigFolder }?.photos.count == 20000)
        #expect(large.folders.last?.photos.upperBound == 100_000)
    }

    @Test func `sidecars read back through SidecarStore, and other apps' .xmp through ImageIO`() throws {
        let (folder, fixture, _) = try Self.written()
        let photos = (0 ..< 300).map(fixture.photo(at:))
        for photo in photos {
            let url = folder.url.appending(path: photo.path)
            let package = SidecarStore().url(for: url)
            #expect(FileManager.default.fileExists(atPath: package.path) == (photo.sidecar != nil))
            if let sidecar = photo.sidecar {
                let loaded = try #require(SidecarStore().load(for: url))
                #expect(loaded.metadata?.rating == sidecar.rating)
                #expect(loaded.metadata?.flag == sidecar.flag && loaded.metadata?.label == sidecar.label)
                #expect(loaded.recipe.isPristine == !sidecar.edited)
                #expect(loaded.recipe.processVersion == EditRecipe.currentProcessVersion)
            }
            let xmpURL = folder.url.appending(path: photo.folder + "/" + photo.xmpName)
            #expect(FileManager.default.fileExists(atPath: xmpURL.path) == (photo.xmp != nil))
            if let xmp = photo.xmp {
                let metadata = try #require(CGImageMetadataCreateFromXMPData(Data(contentsOf: xmpURL) as CFData))
                #expect(CGImageMetadataCopyStringValueWithPath(metadata, nil, "xmp:Rating" as CFString) as String? ==
                    "\(xmp.rating)")
                #expect(
                    CGImageMetadataCopyStringValueWithPath(metadata, nil, "xmp:Label" as CFString) as String?
                        == xmp.label.map(\.rawValue.capitalized),
                )
                let keywords = (0 ..< 5).compactMap {
                    CGImageMetadataCopyStringValueWithPath(metadata, nil, "dc:subject[\($0)]" as CFString) as String?
                }
                #expect(keywords == xmp.keywords)
            }
        }
    }

    @Test func `writing a fixture again finishes what's missing and keeps what's there`() throws {
        let (folder, fixture, first) = try Self.written(.init(photos: 120, seed: 9))
        let files = try Self.files(in: folder.url)
        let photos = (0 ..< 120).map(fixture.photo(at:))
        let withSidecar = try #require(photos.first { $0.sidecar != nil })
        let kept = folder.url.appending(path: photos[8].path)
        let keptDate = try LocalFileSystem().attributes(of: kept).modified
        try FileManager.default.removeItem(at: folder.url.appending(path: photos[7].path))
        try FileManager.default.removeItem(at: folder.url.appending(path: withSidecar.path + ".redlamp"))
        try FileManager.default.removeItem(at: folder.url.appending(path: FixtureManifest.fileName))

        let again = try fixture.write(to: folder.url)
        #expect(again.written == 1 && again.skipped == 119)
        #expect(again.manifest == first.manifest)
        #expect(try Self.files(in: folder.url) == files)
        #expect(try LocalFileSystem().attributes(of: kept).modified == keptDate)
    }

    @Test func `a fixture isn't written over a different one`() throws {
        let (folder, _, _) = try Self.written(.init(photos: 40, seed: 9))
        let other = LibraryFixture(spec: .init(photos: 40, seed: 10), rawSources: Self.sources)
        #expect(throws: FixtureError.self) { try other.write(to: folder.url) }
    }
}

/// Whether ImageIO's number is `expected`, give or take what a rational loses.
private func isNear(_ value: Any?, _ expected: Double?) -> Bool {
    guard let value = value as? Double, let expected else { return value == nil && expected == nil }
    return abs(value - expected) <= abs(expected) * 1e-4
}
