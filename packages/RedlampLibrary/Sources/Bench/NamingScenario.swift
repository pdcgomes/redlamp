import Foundation

public extension BenchScenarios {
    /// Adds the naming scenario (LIB-25) after the others.
    static func registerNaming(photos: Int = NamingScenario.defaultPhotos, many: Int = NamingScenario.defaultMany) {
        register(NamingScenario(photos: photos, many: many))
    }
}

/// Names synthetic photos as the file operations' preview does (LIB-25, LIB-26): `photos` files renamed
/// in their folders while templates are typed a character at a time, every collision resolved, each
/// keystroke's names within a frame (p95 under 16 ms); then `many` files at once, off the main thread,
/// the job made and named in under 2 s. The photos are the fixture generator's, in memory: a fifth of
/// them a raw beside its JPEG, times to the millisecond, and a file already in each folder besides
/// the photos and their sidecars. Every name must be the only one in its folder, and no raw may part
/// from its JPEG. Nothing is read from the fixture, so its volume doesn't matter.
public struct NamingScenario: BenchScenario {
    public static let defaultPhotos = 10000
    public static let defaultMany = 1_000_000
    static let previewBudget = 16.0
    static let manyBudget = 2000.0

    /// The templates typed, one character at a time.
    static let typed = [
        "{date:yyyyMMdd-HHmmss.SSS}-{camera|lower|replace:\" \"}",
        "{text:shoot}-{sequence:4:folder}",
        "{folder}-{original:-4..}",
        "{date:yyyy-MM-dd} {caption|default:Untitled|range:..20} ({sequence} of {total})",
        "{date}",
    ]

    public let name = "naming"
    public let photos: Int
    public let many: Int

    public init(photos: Int = NamingScenario.defaultPhotos, many: Int = NamingScenario.defaultMany) {
        self.photos = max(photos, 1)
        self.many = max(many, 1)
    }

    public func run(_ context: BenchContext) async throws -> [BenchResult] {
        try await measure(seed: context.manifest.spec.seed)
    }

    public func measure(seed: UInt64 = 1) async throws -> [BenchResult] {
        let clock = ContinuousClock()
        let context = NamingContext(texts: ["shoot": "Lisbon"])
        let (files, existing) = Self.photos(photos, seed: seed)
        let job = NamingJob(files, existing: existing)
        var keystrokes: [Duration] = []
        var unsound = (duplicates: 0, split: 0)
        var numbered = 0
        for text in Self.typed {
            let characters = Array(text)
            for length in 1 ... characters.count {
                let started = clock.now
                let template = try NamingTemplate(parsing: String(characters[..<length]), asYouType: true)
                let batch = job.names(template, context: context)
                keystrokes.append(clock.now - started)
                if length == characters.count {
                    let found = Self.check(batch, of: files)
                    unsound.duplicates += found.duplicates
                    unsound.split += found.split
                    numbered += batch.collisions
                }
            }
        }

        let many = many
        let seed = seed
        let (made, named, manyNumbered, manyUnsound) = try await Task.detached(priority: .userInitiated) {
            let (files, existing) = Self.photos(many, seed: seed)
            let template = try NamingTemplate(parsing: "{date:yyyyMMdd-HHmmss}-{camera|lower|replace:\" \"}")
            let making = clock.now
            let job = NamingJob(files, existing: existing)
            let made = clock.now - making
            let naming = clock.now
            let batch = job.names(template, context: context)
            return (made, clock.now - naming, batch.collisions, Self.check(batch, of: files))
        }.value

        let label = BenchResult.grouped(photos)
        let manyLabel = BenchResult.grouped(many)
        return [
            BenchResult(
                scenario: name, id: "library-naming-preview-p50",
                name: "\(label) files named as a template is typed, p50 of \(keystrokes.count) keystrokes",
                value: QueryScenario.percentile(keystrokes, 0.5), unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-naming-preview", name: "\(label) files named as a template is typed, p95",
                value: QueryScenario.percentile(keystrokes, 0.95), unit: "ms", budget: .below(Self.previewBudget, "ms"),
            ),
            BenchResult(
                scenario: name, id: "library-naming-preview-numbered",
                name: "Files numbered to tell them apart, over the \(Self.typed.count) templates",
                value: Double(numbered),
                unit: "files",
            ),
            BenchResult(
                scenario: name, id: "library-naming-many-job", name: "\(manyLabel) files: the job made",
                value: made.seconds * 1000, unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-naming-many-names", name: "\(manyLabel) files: named",
                value: named.seconds * 1000, unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-naming-many", name: "\(manyLabel) files: the job made and named",
                value: (made + named).seconds * 1000, unit: "ms", budget: .below(Self.manyBudget, "ms"),
            ),
            BenchResult(
                scenario: name, id: "library-naming-many-numbered",
                name: "\(manyLabel) files: numbered to tell them apart",
                value: Double(manyNumbered), unit: "files",
            ),
            BenchResult(
                scenario: name, id: "library-naming-duplicates", name: "Names given twice in a folder",
                value: Double(unsound.duplicates + manyUnsound.duplicates), unit: "names", budget: .exactly(0, "names"),
            ),
            BenchResult(
                scenario: name, id: "library-naming-split-pairs", name: "Raws named apart from their JPEGs",
                value: Double(unsound.split + manyUnsound.split), unit: "pairs", budget: .exactly(0, "pairs"),
            ),
        ]
    }

    /// `count` files from the fixture generator's photos, every fifth photo a raw beside its JPEG, with
    /// times to the millisecond; and each folder's files: the photos, a sidecar beside every third and
    /// a file of the photographer's own.
    static func photos(_ count: Int, seed: UInt64) -> (files: [NamingPhoto], existing: [String: Set<String>]) {
        let fixture = LibraryFixture(spec: .init(photos: count, seed: seed))
        var files: [NamingPhoto] = []
        files.reserveCapacity(count)
        var existing: [String: Set<String>] = [:]
        var index = 0
        while files.count < count {
            let photo = fixture.photo(at: index % max(fixture.spec.photos, 1))
            var fields = NamingFields(fixture: photo, root: "/Bench")
            fields.captured = fields.captured?.addingTimeInterval(Double(index % 1000) / 1000)
            var names = [fields.name]
            if index % 5 == 0, files.count + 1 < count {
                let base = (photo.name as NSString).deletingPathExtension
                fields.name = base + ".ARW"
                files.append(NamingPhoto(fields))
                fields.name = base + ".JPG"
                names = [base + ".ARW", base + ".JPG"]
            }
            files.append(NamingPhoto(fields))
            if index % 3 == 0 {
                names.append(fields.name + ".redlamp")
            }
            existing[fields.folder, default: ["Notes.txt"]].formUnion(names)
            index += 1
        }
        return (files, existing)
    }

    /// Names that two files in one folder were given, and raws whose JPEG was named otherwise.
    static func check(_ batch: NamingBatch, of files: [NamingPhoto]) -> (duplicates: Int, split: Int) {
        var seen = Set<String>()
        var duplicates = 0
        var bases: [String: String] = [:]
        var split = 0
        for (file, result) in zip(files, batch.results) {
            if !seen.insert(file.fields.folder + "/" + NamingJob.fold(result.name)).inserted {
                duplicates += 1
            }
            let pair = file.fields.folder + "/" + NamingJob.split(file.fields.name).base
            if let base = bases[pair] {
                if base != result.base {
                    split += 1
                }
            } else {
                bases[pair] = result.base
            }
        }
        return (duplicates, split)
    }
}

extension NamingFields {
    /// A synthetic photo's fields as the index would hold them, under `root`.
    init(fixture photo: FixturePhoto, root: String) {
        let (make, model) = Self.makeAndModel(make: photo.make, model: photo.model)
        self.init(
            name: photo.name, folder: root + "/" + photo.folder, captured: photo.captured.date,
            camera: CaptureMetadata(make: photo.make, model: photo.model).cameraName, make: make, model: model,
            lens: photo.lens, iso: photo.iso.map(Double.init), aperture: photo.aperture, shutter: photo.exposureTime,
            focalLength: photo.focalLength, rating: photo.rating, flag: photo.flag,
            label: photo.label.map(Self.labelName),
            caption: photo.caption, keywords: photo.keywords,
        )
    }
}
