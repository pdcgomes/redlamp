import Foundation
import RedlampDocument

/// A synthetic library for the stress harness (LIB-03): photos in folders of every shape the
/// library must handle, with sidecars and other apps' `.xmp`, made from a seed. The same spec,
/// seed and raw sources always make the same photos, names, sizes and manifest.
///
/// Each photo is a pure function of the seed and its index, so photos are made on every core in
/// any order, and `manifest()` knows what every query must return without reading a file.
public struct LibraryFixture: Sendable {
    public struct Spec: Sendable, Hashable, Codable {
        public var photos: Int
        public var seed: UInt64
        /// Photos that are clones of the raw sources (none when there are no sources).
        public var rawShare: Double
        /// Of the photos that aren't raws, those that are HEIC rather than JPEG.
        public var heicShare: Double
        /// Photos with a `.redlamp` sidecar holding a rating, flag, label or edit.
        public var sidecarShare: Double
        /// Photos with another app's `.xmp` (and no `.redlamp` sidecar).
        public var xmpShare: Double
        /// Photos with a location; a raw has its source's.
        public var locationShare: Double
        /// Photos with IPTC keywords and a caption; raws and photos with an `.xmp` have none, but for
        /// duplicates of photos that have them.
        public var iptcShare: Double
        /// The folder shapes besides the years, which take the photos the others don't.
        public var shapes: [Shape]
        /// Photos that are copies of an earlier photo, byte for byte, with sidecars and `.xmp` of
        /// their own (LIB-39); nil for none, so a fixture made without them keeps its files and manifest.
        public var duplicateShare: Double?

        public init(
            photos: Int, seed: UInt64 = 1, rawShare: Double = 0.2, heicShare: Double = 0.1,
            sidecarShare: Double = 0.15, xmpShare: Double = 0.05, locationShare: Double = 1.0 / 3,
            iptcShare: Double = 0.2, shapes: [Shape] = Shape.allCases.filter { $0 != .years },
            duplicateShare: Double = 0,
        ) {
            self.photos = max(photos, 0)
            self.seed = seed
            self.rawShare = rawShare
            self.heicShare = heicShare
            self.sidecarShare = sidecarShare
            self.xmpShare = xmpShare
            self.locationShare = locationShare
            self.iptcShare = iptcShare
            self.shapes = Shape.allCases.filter { $0 != .years && shapes.contains($0) }
            self.duplicateShare = duplicateShare > 0 ? min(duplicateShare, 1) : nil
        }
    }

    public enum Shape: String, Sendable, Hashable, Codable, CaseIterable {
        /// `2019/2019-06-14 Wedding`: a folder a day, 100 to 200 photos each.
        case years
        /// `Clients/Acme Corp/2021-04-12 Catalogue`: 15% of the photos.
        case clients
        /// `Imports/2024-07-20 Card Dump`: 20,000 photos in one folder, or a fifth of a smaller library.
        case bigFolder
        /// `Archive/Level 2/…/Level 12`: photos at each of 12 levels.
        case deepTree
        /// `Voyages/Été à Montréal 2014` and `旅行/日本 2019`, holding `Café-0001.JPG` and `東京-0001.JPG`.
        case unicodeNames
        /// `Long Names/` and a folder with a 200-character name, holding photos with 200-character names.
        case longNames
    }

    /// A folder that holds photos.
    public struct Folder: Sendable, Hashable {
        enum Naming: Sendable, Hashable {
            /// `DSCF0001.JPG`, after the camera.
            case camera
            /// `Café-0001.JPG`.
            case word(String)
            /// 200 characters.
            case long
        }

        /// Below the fixture's root, `/`-separated.
        public let path: String
        public let shape: Shape
        /// The indices of its photos.
        public let photos: Range<Int>
        /// Its photos are taken on `firstDay` (days after 1 January 1970) and the `days - 1` after it.
        let firstDay: Int
        let days: Int
        /// The cameras its photos come from, by index into the catalog; empty for any camera.
        let cameras: [Int]
        /// The number in its first photo's name.
        let firstNumber: Int
        let naming: Naming
    }

    public let spec: Spec
    public let rawSources: [RawSource]
    /// Every folder that holds photos, in the order of their photos' indices.
    public let folders: [Folder]

    /// 1 January 2006 to 31 December 2025.
    static let firstDay = FixtureDate.days(2006, 1, 1)
    static let lastDay = FixtureDate.days(2025, 12, 31)
    /// The folder `copyRawSources` puts the sources in, when the fixture is on another volume. It's
    /// hidden, so listings leave it out.
    public static let sourcesFolder = "_sources"

    public init(spec: Spec, rawSources: [RawSource] = []) {
        self.spec = spec
        self.rawSources = rawSources
        folders = Self.layout(spec)
    }

    /// Every folder below the root, those that only hold folders included, by path.
    public var allFolderPaths: [String] {
        var paths = Set<String>()
        for folder in folders {
            var path = folder.path
            while !path.isEmpty, paths.insert(path).inserted {
                path = (path as NSString).deletingLastPathComponent
            }
        }
        return paths.sorted()
    }

    // MARK: - Photos

    public func photo(at index: Int) -> FixturePhoto {
        photo(at: index, in: folders[folderIndex(of: index)])
    }

    public func photos(in folder: Folder) -> [FixturePhoto] {
        folder.photos.map { photo(at: $0, in: folder) }
    }

    func folderIndex(of index: Int) -> Int {
        var low = 0
        var high = folders.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if folders[middle].photos.lowerBound <= index {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low
    }

    func photo(at index: Int, in folder: Folder) -> FixturePhoto {
        var random = SeededRandom(seed: spec.seed, stream: UInt64(index))
        let isRaw = !rawSources.isEmpty && random.chance(spec.rawShare)
        let kind: FixturePhoto.Kind = isRaw ? .raw : random.chance(spec.heicShare) ? .heic : .jpeg
        let day = folder.firstDay + random.int(below: max(folder.days, 1))
        let captured = FixtureDate(days: day, seconds: 7 * 3600 + random.int(below: 14 * 3600))

        let source = isRaw ? random.int(below: rawSources.count) : nil
        let raw = source.map { rawSources[$0] }
        let cameraIndex = folder.cameras.isEmpty
            ? random.int(below: FixtureCatalog.cameras.count) : random.pick(folder.cameras)
        let camera = FixtureCatalog.cameras[cameraIndex]
        let lens = FixtureCatalog.lenses[random.pick(FixtureCatalog.lensesByCamera[cameraIndex])]
        let iso = FixtureCatalog.isoSpeeds[min(random.int(below: 20), random.int(below: 20))]
        let aperture = random.pick([lens.aperture] + FixtureCatalog.apertures.filter { $0 > lens.aperture })
        let exposureTime = FixtureCatalog.exposureTimes[
            random.chance(0.1) ? 12 + random.int(below: 7) : (random.int(below: 12) + random.int(below: 12)) / 2,
        ]
        let focal = lens.focal.lowerBound == lens.focal.upperBound
            ? lens.focal.lowerBound
            : Double(random.int(in: Int(lens.focal.lowerBound) ... Int(lens.focal.upperBound)))
        var location: FixturePhoto.Location?
        if random.chance(spec.locationShare) {
            let place = random.pick(FixtureCatalog.places)
            location = FixturePhoto.Location(
                latitude: place.latitude + Double(random.int(in: -5000 ... 5000)) / 100_000,
                longitude: place.longitude + Double(random.int(in: -5000 ... 5000)) / 100_000,
            )
        }

        let roll = random.unit()
        var sidecar: FixturePhoto.Sidecar?
        var xmp: FixturePhoto.OtherXMP?
        if roll < spec.sidecarShare {
            sidecar = Self.sidecar(&random)
        } else if roll < spec.sidecarShare + spec.xmpShare {
            xmp = FixturePhoto.OtherXMP(
                rating: random.int(in: 1 ... 5),
                label: random.chance(0.4) ? random.pick(ColorLabel.allCases) : nil,
                keywords: Self.keywords(&random),
            )
        }
        var keywords: [String] = []
        var caption: String?
        // Raws carry none, so the others carry more, for about `iptcShare` of the library.
        if !isRaw, xmp == nil, random.chance(spec.iptcShare / max(1 - effectiveRawShare, 0.01)) {
            keywords = Self.keywords(&random)
            caption = random.pick(FixtureCatalog.captions)
        }

        let ext = raw?.url.pathExtension ?? (kind == .heic ? "HEIC" : "JPG")
        let number = folder.firstNumber + index - folder.photos.lowerBound
        let prefix = raw.map(Self.prefix) ?? camera.prefix
        let photo = FixturePhoto(
            index: index,
            folder: folder.path,
            name: Self.name(folder.naming, number: number, prefix: prefix, ext: ext),
            kind: kind,
            make: raw.map(\.make) ?? camera.make,
            model: raw.map(\.model) ?? camera.model,
            lens: raw.map(\.lens) ?? lens.name,
            iso: raw.map(\.iso) ?? iso,
            aperture: raw.map(\.aperture) ?? aperture,
            exposureTime: raw.map(\.exposureTime) ?? exposureTime,
            focalLength: raw.map(\.focalLength) ?? focal,
            captured: captured,
            location: raw.map(\.location) ?? location,
            embeddedKeywords: keywords,
            caption: caption,
            sidecar: sidecar,
            xmp: xmp,
            source: source,
            original: nil,
        )
        guard let original = original(of: index) else { return photo }
        let copied = self.photo(at: original)
        let copyExt = (copied.name as NSString).pathExtension
        return photo.copy(of: copied, named: Self.name(folder.naming, number: number, prefix: prefix, ext: copyExt))
    }

    /// The earlier photo whose file photo `index` is a copy of, itself not a copy; nil for a photo
    /// that isn't one. Drawn from a sequence of its own, so photos are what they'd be without copies.
    func original(of index: Int) -> Int? {
        guard let share = spec.duplicateShare, index > 0 else { return nil }
        var random = SeededRandom(seed: spec.seed, stream: .max - 1 - UInt64(index))
        guard random.chance(share) else { return nil }
        let earlier = random.int(below: index)
        return original(of: earlier) ?? earlier
    }

    /// The share of raws the spec gets with these sources.
    var effectiveRawShare: Double {
        rawSources.isEmpty ? 0 : spec.rawShare
    }

    private static func sidecar(_ random: inout SeededRandom) -> FixturePhoto.Sidecar {
        let ratingRoll = random.int(below: 100)
        let rating = [15, 25, 40, 65, 85, 100].firstIndex { ratingRoll < $0 } ?? 0
        let flagRoll = random.int(below: 10)
        let flag: PhotoFlag? = flagRoll < 3 ? .pick : flagRoll < 4 ? .reject : nil
        let label: ColorLabel? = random.chance(0.5) ? random.pick(ColorLabel.allCases) : nil
        let edited = random.chance(0.5)
        // A sidecar holding nothing would be deleted by the next save, so it holds an edit.
        return FixturePhoto.Sidecar(
            rating: rating, flag: flag, label: label, edited: edited || (rating == 0 && flag == nil && label == nil),
        )
    }

    /// One to three different keywords.
    private static func keywords(_ random: inout SeededRandom) -> [String] {
        var chosen: [String] = []
        for _ in 0 ... random.int(below: 3) {
            let keyword = random.pick(FixtureCatalog.keywords)
            if !chosen.contains(keyword) {
                chosen.append(keyword)
            }
        }
        return chosen
    }

    /// A raw's name starts as its camera maker's files do.
    private static func prefix(_ source: RawSource) -> String {
        let make = source.make?.lowercased() ?? ""
        return FixtureCatalog.cameras.first { make.hasPrefix($0.make.lowercased()) }?.prefix ?? "IMG_"
    }

    private static let longStem = String(
        repeating: "A photo whose name runs to two hundred characters, to try paths, columns and sorting ",
        count: 3,
    )

    static func name(_ naming: Folder.Naming, number: Int, prefix: String, ext: String) -> String {
        switch naming {
        case .camera:
            return "\(prefix)\(digits(number, 4)).\(ext)"
        case let .word(word):
            return "\(word)-\(digits(number, 4)).\(ext)"
        case .long:
            let suffix = "-\(digits(number, 4)).\(ext)"
            return String(longStem.prefix(200 - suffix.count)) + suffix
        }
    }

    // MARK: - Layout

    /// The folders, from the seed alone: the fixed shapes first, then the years with the rest.
    static func layout(_ spec: Spec) -> [Folder] {
        var random = SeededRandom(seed: spec.seed, stream: .max)
        var folders: [Folder] = []
        var used = Set<String>()
        var next = 0
        let total = spec.photos

        func randomDay() -> Int {
            random.int(in: firstDay ... lastDay)
        }
        func cameras() -> [Int] {
            (0 ... random.int(below: 3)).map { _ in random.int(below: FixtureCatalog.cameras.count) }
        }
        func add(
            _ path: String, _ shape: Shape, count: Int, firstDay: Int, days: Int = 1, cameras: [Int] = [],
            naming: Folder.Naming = .camera,
        ) {
            var unique = path
            var copy = 2
            while !used.insert(unique).inserted {
                unique = "\(path) \(copy)"
                copy += 1
            }
            let count = min(max(count, 0), total - next)
            folders.append(Folder(
                path: unique, shape: shape, photos: next ..< next + count, firstDay: firstDay, days: days,
                cameras: cameras, firstNumber: 1 + random.int(below: 8000), naming: naming,
            ))
            next += count
        }

        if spec.shapes.contains(.bigFolder) {
            let day = randomDay()
            let name = FixtureDate(days: day, seconds: 0).dayName
            add(
                "Imports/\(name) Card Dump", .bigFolder, count: min(20000, total / 5), firstDay: day - 44, days: 45,
                cameras: cameras(),
            )
        }
        if spec.shapes.contains(.deepTree) {
            let perLevel = min(50, max(total / 2000, 1))
            var path = "Archive"
            for level in 1 ... 12 {
                if level > 1 {
                    path += "/Level \(level)"
                }
                add(
                    path, .deepTree, count: perLevel * 12 <= total / 10 ? perLevel : 0, firstDay: firstDay,
                    days: lastDay - firstDay + 1,
                )
            }
        }
        if spec.shapes.contains(.unicodeNames) {
            let count = min(200, max(total / 500, 2), total / 40)
            let montreal = randomDay()
            let japan = randomDay()
            add(
                "Voyages/Été à Montréal \(FixtureDate(days: montreal, seconds: 0).year)", .unicodeNames, count: count,
                firstDay: montreal, days: 10, naming: .word("Café"),
            )
            add(
                "旅行/日本 \(FixtureDate(days: japan, seconds: 0).year)", .unicodeNames, count: count,
                firstDay: japan, days: 10, naming: .word("東京"),
            )
        }
        if spec.shapes.contains(.longNames) {
            let name = String(String(
                repeating: "A folder whose name runs to two hundred characters, to try paths and the folder tree ",
                count: 3,
            ).prefix(200))
            add(
                "Long Names/\(name)", .longNames, count: min(100, max(total / 1000, 2), total / 40),
                firstDay: firstDay, days: lastDay - firstDay + 1, naming: .long,
            )
        }
        if spec.shapes.contains(.clients) {
            let share = total * 15 / 100
            let clients = FixtureCatalog.clients.prefix(min(12, max(2, total / 8000)))
            var jobs: [(path: String, day: Int, weight: Int)] = []
            for client in clients {
                for _ in 0 ... 1 + random.int(below: 4) {
                    let day = randomDay()
                    let job = random.pick(FixtureCatalog.jobs)
                    jobs.append((
                        "Clients/\(client)/\(FixtureDate(days: day, seconds: 0).dayName) \(job)", day,
                        1 + random.int(below: 4),
                    ))
                }
            }
            let weights = jobs.reduce(0) { $0 + $1.weight }
            var given = 0
            for (index, job) in jobs.enumerated() {
                let count = index == jobs.count - 1 ? share - given : share * job.weight / weights
                add(job.path, .clients, count: count, firstDay: job.day, cameras: cameras())
                given += count
            }
        }
        while next < total || folders.isEmpty {
            let day = randomDay()
            let date = FixtureDate(days: day, seconds: 0)
            add(
                "\(date.year)/\(date.dayName) \(random.pick(FixtureCatalog.events))", .years,
                count: random.int(in: 100 ... 200), firstDay: day, cameras: cameras(),
            )
        }
        return folders
    }
}
