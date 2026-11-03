#if DEBUG || REDLAMP_PROFILING
    import Foundation

    /// The census of a Photos library (LIB-57) as it's shared: counts, sizes, times and answers, and the Mac it ran on,
    /// never a photo's name, place, album or identifier. Each step of the census (`PhotoKitCensus.Step`) fills its part
    /// of the report the first step made.
    public struct PhotoKitCensusReport: Sendable, Hashable, Codable {
        public static let format = "app.redlamp.photokit-census"

        public var format = Self.format
        public var version = 1
        /// When each step ran, by its name.
        public var ran: [String: Date] = [:]
        public var mac: Mac
        public var access: ApplePhotosAccess
        public var library: Library?
        public var index: Index?
        public var sample: Sample?
        public var images: Images?
        public var exif: EXIF?
        public var changes: Changes?
        public var downloads: Downloads?
        public var cancels: Cancels?
        public var recovered: Recovered?
        public var offline: Offline?
        public var week: Week?
        /// The parts that failed, each with the error's name.
        public var notes: [String] = []

        public init(mac: Mac, access: ApplePhotosAccess) {
            self.mac = mac
            self.access = access
        }

        /// The Mac the census ran on, and its network when it began.
        public struct Mac: Sendable, Hashable, Codable {
            public var model: String?
            public var chip: String?
            public var memoryGB: Int
            public var macOS: String
            public var redlamp: String?
            public var commit: String?
            public var performanceCores: Int
            public var reachable: Bool
            /// macOS marks the network as expensive (a phone's hotspot) or constrained (Low Data Mode).
            public var expensive: Bool
        }

        /// Photos' Library: every asset of the System Photo Library, each once, read as LIB-58 reads an album kept in
        /// place.
        public struct Library: Sendable, Hashable, Codable {
            /// Collections by kind (`album`, `smartAlbum`, `sharedAlbum`, `folder`).
            public var collections: [String: Int]
            /// Burst frames and hidden photos included.
            public var assets: Int
            /// Those the library lists (`ApplePhotosAsset.isListed`).
            public var photos: Int
            public var videos: Int
            public var hidden: Int
            /// Frames of bursts neither the key photo nor picked.
            public var burstFramesLeft: Int
            public var edited: Int
            /// Edited, with Photos' rendering among the asset's files.
            public var editsRendered: Int
            public var raws: Int
            public var pairs: Int
            public var dngs: Int
            public var live: Int
            public var screenshots: Int
            public var shared: Int
            /// The originals' types, by uniform type identifier; a pair's raws apart; the kinds of files assets have.
            public var types: [String: Int]
            public var pairRawTypes: [String: Int]
            public var resources: [String: Int]
            /// The originals' long side, in pixels, where Photos says.
            public var longEdge: Spread?
            /// How long each read took: `collections`, `assets` (every asset with its files and cloud identifier,
            /// `assets(in:)`) and `listedIDs` (the photos' identifiers alone, `listedIDs(in:)`).
            public var milliseconds: [String: Double]
            /// The census's memory before and after reading the assets.
            public var footprintMB: [String: Double]
        }

        /// The Library kept in place in an index of the census's own, by LIB-58's indexer, then followed by LIB-61's.
        public struct Index: Sendable, Hashable, Codable {
            public var assets: Int
            public var rows: Int
            public var videos: Int
            public var hidden: Int
            public var frames: Int
            public var firstBatchMilliseconds: Double?
            public var allMilliseconds: Double
            /// A pass right after, with Photos unchanged, as at a launch: how long, and whether it compared the albums
            /// whole rather than reading Photos' changes.
            public var unchangedMilliseconds: Double
            public var unchangedWhole: Bool
            public var indexMB: Double
        }

        /// The photos sampled at random for the images, the EXIF and the downloads, and the edited ones for their
        /// versions.
        public struct Sample: Sendable, Hashable, Codable {
            public var photos: Int
            public var edited: Int
            /// Their originals by where Photos has them (`local`, `inCloud`, or why it couldn't say), and RAW+JPEG
            /// pairs'
            /// raws apart.
            public var originals: [String: Int]
            public var pairRaws: [String: Int]
        }

        /// Photos' images without the network, asked as LIB-59 asks them (`ApplePhotosImages`).
        public struct Images: Sendable, Hashable, Codable {
            /// The sample's current versions, by where the original is: `local` or `inCloud`.
            public var current: [String: Sizes]
            /// The edited photos', by version: `current` and `original`.
            public var edited: [String: Sizes]
            public var screenfuls: [Screenfuls]
        }

        /// One picture's images at the store's sizes and the largest Photos keeps.
        public struct Sizes: Sendable, Hashable, Codable {
            public var grid = Requests()
            public var preview = Requests()
            public var largest = Largest()
        }

        /// Requests at one size: what they gave, the images' long side in pixels, and how long each took.
        public struct Requests: Sendable, Hashable, Codable {
            public var asked = 0
            public var given = 0
            public var inCloud = 0
            public var unavailable = 0
            public var longEdge: Spread?
            public var milliseconds: Spread?
        }

        /// The largest image Photos keeps of a picture, at its own size, and its long side as a percentage of the
        /// original's.
        public struct Largest: Sendable, Hashable, Codable {
            public var asked = 0
            public var given = 0
            public var longEdge: Spread?
            public var ofOriginal: Spread?
        }

        /// Screenfuls of grid thumbnails the store hasn't, each asked at once on as many lanes as the grid's on screen
        /// and
        /// made into the store's thumbnails: with nothing prepared, or prepared ahead by the caching manager.
        public struct Screenfuls: Sendable, Hashable, Codable {
            public var cached: Bool
            public var count: Int
            public var thumbnails: Int
            public var lanes: Int
            public var given: Int
            public var inCloud: Int
            public var unavailable: Int
            public var milliseconds: Spread?
        }

        /// What Photos' local images say of the camera (decision 10): each picture's data without the network, by where
        /// the
        /// original is.
        public struct EXIF: Sendable, Hashable, Codable {
            public var byOriginal: [String: Read]

            public struct Read: Sendable, Hashable, Codable {
                public var asked = 0
                public var given = 0
                public var megabytes: Spread?
                public var longEdge: Spread?
                public var types: [String: Int] = [:]
                /// How many had each field: `make`, `model`, `lens`, `exposureTime`, `fNumber`, `iso`, `focalLength`,
                /// `taken`, `gps`.
                public var fields: [String: Int] = [:]
            }
        }

        /// Photos' change history read through `ApplePhotosLibrary.changes(since:)`, as LIB-61 reads it.
        public struct Changes: Sendable, Hashable, Codable {
            /// Since a token taken just before, nothing changed.
            public var unchangedMilliseconds: Double
            /// Since the census began, and what changed meanwhile (`inserted`, `updated`, `deleted`, `collections`).
            public var sinceStartMilliseconds: Double?
            public var sinceStart: [String: Int]
            public var tokenBytes: Int
        }

        /// Originals only in iCloud downloaded as LIB-60 downloads them (`ApplePhotosLibrary.write`), each file once.
        public struct Downloads: Sendable, Hashable, Codable {
            public var asked = 0
            public var completed = 0
            /// Those that failed, by the error's name.
            public var failed: [String: Int] = [:]
            public var types: [String: Int] = [:]
            public var megabytes: Spread?
            /// From asking to Photos' first word of progress, and to its first above nothing.
            public var firstProgressMilliseconds: Spread?
            public var firstBytesMilliseconds: Spread?
            public var seconds: Spread?
            public var megabytesPerSecond: Spread?
            public var progressCalls: Spread?
            /// After each, where Photos has the original: `local` when it kept what it downloaded.
            public var afterwards: [String: Int] = [:]
            /// The space free on the Mac's disk before and after, in bytes: `available`, and `forImportantUsage`, which
            /// counts what macOS can purge.
            public var freeBefore: [String: Int64] = [:]
            public var freeAfter: [String: Int64] = [:]
        }

        /// Downloads cancelled partway, as Cancel in Develop cancels them.
        public struct Cancels: Sendable, Hashable, Codable {
            public var asked = 0
            public var cancelled = 0
            /// Finished before the point they were to be cancelled at.
            public var finishedFirst = 0
            /// Where each was cancelled: `firstProgress`, `quarter`, `half`.
            public var at: [String: Int] = [:]
            /// From cancelling to the download ending.
            public var stoppedMilliseconds: Spread?
            public var megabytesWhenCancelled: Spread?
            /// Written to after it was cancelled.
            public var grewAfterwards = 0
            /// How each ended, by the error's name.
            public var ended: [String: Int] = [:]
            /// Some seconds later, where Photos has the original.
            public var afterwards: [String: Int] = [:]
        }

        /// After a photo was deleted in Photos and recovered from Recently Deleted.
        public struct Recovered: Sendable, Hashable, Codable {
            public var minutesAfterCensus: Double
            public var changeSets: Int
            /// Every change since the census: `inserted`, `updated`, `deleted`, `collections`.
            public var changed: [String: Int]
            /// Each deleted photo's changes in order (`deleted, inserted`), by how many photos had them.
            public var patterns: [String: Int]
            /// Deleted photos Photos has again under their own local identifier.
            public var sameIdentifier: Int
            /// Deleted photos Photos doesn't have under their own, whose cloud identifier a photo inserted since has.
            public var newIdentifier: Int
            public var notBack: Int
            /// Where LIB-61's reading of the changes all at once puts the deleted photos.
            public var readAs: [String: Int]
            public var index: Pass?
        }

        /// A pass of LIB-61's over the index the census kept.
        public struct Pass: Sendable, Hashable, Codable {
            public var milliseconds: Double
            public var whole: Bool
            public var inserted: Int
            public var updated: Int
            public var removed: Int
            public var missing: Int
        }

        /// A download tried with the Mac offline (LIB-60's errors).
        public struct Offline: Sendable, Hashable, Codable {
            public var reachable: Bool
            public var tried: Bool
            /// How it ended, by the error's name, and whether the library took it for iCloud out of reach.
            public var ended: String?
            public var asOffline: Bool
            public var milliseconds: Double?
            /// Photos' preview of the photo without the network, offline: `given`, `inCloud` or `unavailable`.
            public var preview: String?
        }

        /// A week on: Photos' history since the census, and the originals it downloaded.
        public struct Week: Sendable, Hashable, Codable {
            public var days: Double
            public var expired: Bool
            public var milliseconds: Double?
            public var changeSets: Int?
            public var changed: [String: Int]
            /// The originals the census downloaded, and those it cancelled, by where Photos has them now.
            public var downloaded: [String: Int]
            public var cancelled: [String: Int]
            public var free: [String: Int64]
            public var index: Pass?
        }

        public func json() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(self)
        }

        public static func read(_ data: Data) throws -> PhotoKitCensusReport {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(PhotoKitCensusReport.self, from: data)
        }
    }

    public extension PhotoKitCensusReport {
        /// How values spread: how many, the least, the median, the 95th percentile (nearest rank) and the most.
        struct Spread: Sendable, Hashable, Codable {
            public var count: Int
            public var min: Double
            public var p50: Double
            public var p95: Double
            public var max: Double

            /// Nil for no values; each rounded to a tenth.
            public init?(_ values: some Collection<Double>) {
                guard !values.isEmpty else { return nil }
                let sorted = values.sorted()
                func rank(_ fraction: Double) -> Double {
                    Self.round(sorted[Swift.max(Int((fraction * Double(sorted.count)).rounded(.up)) - 1, 0)])
                }
                count = sorted.count
                min = Self.round(sorted[0])
                p50 = rank(0.5)
                p95 = rank(0.95)
                max = Self.round(sorted[sorted.count - 1])
            }

            static func round(_ value: Double) -> Double {
                (value * 10).rounded() / 10
            }
        }
    }
#endif
