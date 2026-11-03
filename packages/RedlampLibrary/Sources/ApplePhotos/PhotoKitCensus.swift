#if DEBUG || REDLAMP_PROFILING
    import Foundation
    import RedlampDocument

    /// The census of this Mac's Photos library (LIB-57, step 3 of the Apple Photos in place design): what Apple's
    /// documentation leaves open, measured through the code the library reads Photos with (`ApplePhotosLibrary`,
    /// LIB-59's
    /// `ApplePhotosImages`, the Photos indexer), on a library nothing else can be given access to where Redlamp is
    /// built.
    ///
    /// Its steps: `measure`, the images Photos keeps under Optimize Mac Storage and their sizes, the camera's EXIF in
    /// them,
    /// downloads and cancelling, whether Photos keeps what it downloaded, and the design's budgets on this library;
    /// `recovered`, once a photo has been deleted in Photos and recovered from Recently Deleted; `offline`, with the
    /// Mac
    /// offline; and `week`, a week on. The report holds counts, sizes, times and answers only. What the later steps
    /// need
    /// of the photos measured, their identifiers, Photos' change token and an index of the Library, stays in the
    /// folder's
    /// `State` on this Mac, and the last step deletes it.
    public struct PhotoKitCensus: Sendable {
        public enum Step: String, Sendable, Hashable, CaseIterable {
            case measure, recovered, offline, week
        }

        /// How much the census reads and downloads.
        public struct Plan: Sendable, Hashable {
            /// Photos drawn at random for the images, their EXIF and the downloads, and edited ones for their versions.
            public var sample = 300
            public var edited = 100
            public var exifInCloud = 60
            public var exifLocal = 10
            public var screenfuls = 10
            public var cachedScreenfuls = 5
            /// Thumbnails in a screenful of the grid, as LIB-59's bench counts them.
            public var screenful = 70
            public var lanes = CoreCounts.performance
            /// Ten originals at most, the owner's allowance: these downloaded, then these cancelled partway.
            public var downloads = 7
            public var cancels = 3
            /// Originals only in iCloud left alone, for the offline step.
            public var spares = 2
            public var timeout = Duration.seconds(300)
            /// How long the caching manager is given to prepare a screenful before it's asked for.
            public var preparing = Duration.seconds(1)
            /// How long a cancelled download is watched for writes, and how long after the cancelled downloads Photos
            /// is
            /// asked whether it kept them.
            public var watching = Duration.seconds(2)
            public var settling = Duration.seconds(5)
            public var seed: UInt64 = 57

            public init() {}
        }

        public let photos: any ApplePhotosLibrary
        public let images: any ApplePhotosImages
        public let probe: any ApplePhotosProbe
        public let network: any ApplePhotosNetwork
        /// Where the report and the state are.
        public let folder: URL
        /// Hears of each part of a step as it starts and as it ends.
        public let say: @Sendable (String) -> Void

        public init(
            photos: any ApplePhotosLibrary, images: any ApplePhotosImages, probe: any ApplePhotosProbe,
            network: any ApplePhotosNetwork, folder: URL, say: @escaping @Sendable (String) -> Void = { _ in },
        ) {
            self.photos = photos
            self.images = images
            self.probe = probe
            self.network = network
            self.folder = folder
            self.say = say
        }

        /// The report, to send back, and its text.
        public var reportURL: URL {
            folder.appending(path: "census.json")
        }

        public var textURL: URL {
            folder.appending(path: "census.txt")
        }

        /// What stays on this Mac: identifiers, Photos' change token and the index of the Library.
        public var stateFolder: URL {
            folder.appending(path: "State", directoryHint: .isDirectory)
        }

        var stateURL: URL {
            stateFolder.appending(path: "state.json")
        }

        /// The Library kept in place in an index of the census's own, until the last step.
        var kept: LibraryPaths {
            LibraryPaths(root: stateFolder.appending(path: "Library", directoryHint: .isDirectory))
        }

        /// The downloads, each removed once it's measured, and the folder with them once the step ends.
        var scratch: URL {
            FileManager.default.temporaryDirectory.appending(path: "redlamp-photos-census", directoryHint: .isDirectory)
        }

        /// Runs `step`, then writes the report with what it found beside what the steps before found. `measure` starts
        /// the census again; the others need it to have run.
        @discardableResult
        public func run(_ step: Step, plan: Plan = Plan()) async throws -> PhotoKitCensusReport {
            let manager = FileManager.default
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try? manager.removeItem(at: scratch)
            try manager.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? manager.removeItem(at: scratch) }
            var report: PhotoKitCensusReport = switch step {
            case .measure: await measure(plan)
            case .recovered: try await recovered()
            case .offline: try await offline(plan)
            case .week: try await week()
            }
            report.ran[step.rawValue] = .now
            try report.json().write(to: reportURL, options: .atomic)
            try Data((report.lines().joined(separator: "\n") + "\n").utf8).write(to: textURL, options: .atomic)
            return report
        }
    }

    // MARK: - Measuring

    extension PhotoKitCensus {
        /// The Library as the census read it.
        struct Read {
            /// The collections read: Photos' Library, or every album where there's none.
            var collections: [String]
            var assets: [ApplePhotosAsset]
            var report: PhotoKitCensusReport.Library
        }

        /// The photos drawn, each in a random order: the sample, the edited ones, and the rest, for the screenfuls.
        struct Drawn {
            var photos: [ApplePhotosAsset]
            var edited: [ApplePhotosAsset]
            var rest: [ApplePhotosAsset]
        }

        func measure(_ plan: Plan) async -> PhotoKitCensusReport {
            try? FileManager.default.removeItem(at: stateFolder)
            var access = photos.access()
            if access == .notDetermined {
                say("Asking for access to Photos: choose Allow in the dialog.")
                access = await photos.requestAccess()
            }
            var report = PhotoKitCensusReport(mac: .current(network: network), access: access)
            guard access == .authorized else {
                say("Redlamp may not read Photos (\(access.rawValue)): System Settings › Privacy & Security › Photos.")
                report.notes.append("access: \(access.rawValue)")
                return report
            }
            let began = photos.changeToken()
            let started = Date.now
            var notes: [String] = []
            guard let read = await attempt("library", &notes, { try await readLibrary() }) else {
                report.notes = notes
                return report
            }
            report.library = read.report
            report.index = await attempt("index", &notes) { try await keep(read.collections) }
            let drawn = Self.draw(read.assets, plan)
            let localities = await localities(of: drawn.photos)
            report.sample = PhotoKitCensusReport.Sample(
                photos: drawn.photos.count, edited: drawn.edited.count,
                originals: Self.tally(drawn.photos.map { localities.group(of: $0.id) }),
                pairRaws: Self.tally(localities.pairRaws.map(Self.label)),
            )
            report.images = await measureImages(drawn, localities: localities, plan)
            report.exif = await readEXIF(drawn.photos, localities: localities, plan)
            report.changes = await attempt("changes", &notes) { try await readChanges(since: began) }
            let picks = Self.picks(drawn.photos.filter { localities[$0.id] == .inCloud }, plan)
            report.downloads = await download(picks.downloads, plan)
            report.cancels = await cancel(picks.cancels, plan)
            let state = State(
                measured: started, token: photos.changeToken(),
                downloaded: picks.downloads
                    .flatMap { asset in asset.originals.map { Pick(asset: asset.id, resource: $0) } },
                cancelled: picks.cancels.compactMap(Pick.init(photo:)),
                spares: picks.spares.compactMap(Pick.init(photo:)),
                clouds: Self.clouds(of: read.assets), indexed: report.index != nil,
            )
            _ = await attempt("state", &notes) { try save(state) }
            report.notes = notes
            say("Measured. The report is \(reportURL.path).")
            return report
        }

        /// Runs `body`, naming the part in `notes` with its error when it fails.
        func attempt<T>(_ part: String, _ notes: inout [String], _ body: () async throws -> T) async -> T? {
            do {
                return try await body()
            } catch {
                say("\(part) failed: \(Self.name(of: error))")
                notes.append("\(part): \(Self.name(of: error))")
                return nil
            }
        }

        func readLibrary() async throws -> Read {
            say("Reading Photos' collections.")
            var clock = ContinuousClock.now
            let tree = try await photos.collections()
            let collectionsTime = Self.milliseconds(since: clock)
            let ids = try await probe.libraryCollection().map { [$0] } ?? tree.filter { $0.kind != .folder }.map(\.id)
            say("Reading every asset of Photos' Library with its files and cloud identifier, as an album kept is read.")
            let before = Self.footprint()
            clock = .now
            let assets = try await photos.assets(in: ids)
            let assetsTime = Self.milliseconds(since: clock)
            let after = Self.footprint()
            clock = .now
            _ = try await photos.listedIDs(in: ids)
            let listedTime = Self.milliseconds(since: clock)
            say("\(assets.count) assets read in \(Self.seconds(assetsTime)).")
            let listed = assets.filter(\.isListed)
            return Read(collections: ids, assets: assets, report: PhotoKitCensusReport.Library(
                collections: Self.tally(tree.map(\.kind.rawValue)),
                assets: assets.count,
                photos: listed.count,
                videos: assets.count { $0.mediaType == .video },
                hidden: assets.count(where: \.isHidden),
                burstFramesLeft: assets.count { $0.burst.map { !$0.isKey && !$0.isUserPick } == true },
                edited: listed.count(where: \.hasAdjustments),
                editsRendered: listed.count { $0.edit != nil },
                raws: listed.count(where: \.isRaw),
                pairs: listed.count(where: \.isPair),
                dngs: listed.count { $0.isRaw && $0.resource(.photo)?.type == "com.adobe.raw-image" },
                live: listed.count { $0.subtypes.contains(.live) },
                screenshots: listed.count { $0.subtypes.contains(.screenshot) },
                shared: assets.count { $0.source == .cloudShared },
                types: Self.tally(listed.compactMap { $0.resource(.photo)?.type }),
                pairRawTypes: Self.tally(listed.filter(\.isPair).compactMap { $0.resource(.alternatePhoto)?.type }),
                resources: Self.tally(assets.map { $0.resources.map(\.kind.rawValue).sorted().joined(separator: "+") }),
                longEdge: PhotoKitCensusReport.Spread(listed.compactMap { Self.longEdge(of: $0.resource(.photo)) }),
                milliseconds: ["collections": collectionsTime, "assets": assetsTime, "listedIDs": listedTime],
                footprintMB: ["before": before, "after": after],
            ))
        }

        /// Keeps `collections` in place in the census's own index, as Add Albums will, then follows Photos once with
        /// nothing changed, as a launch does.
        func keep(_ collections: [String]) async throws -> PhotoKitCensusReport.Index {
            say("Keeping the Library in place in an index of the census's own, as Redlamp keeps an album.")
            let paths = kept
            try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
            let index = try await LibraryIndex.open(at: paths.index, readers: 2)
            let indexer = ApplePhotosIndexer(photos: photos, index: index, paths: paths)
            let first: ApplePhotosIndexer.Outcome
            let again: ApplePhotosIndexer.Outcome
            do {
                first = try await indexer.keep(collections)
                again = try await indexer.update()
            } catch {
                await index.close()
                throw error
            }
            await index.close()
            let all = first.elapsed / .milliseconds(1)
            let unchanged = again.elapsed / .milliseconds(1)
            say("\(first.inserted.count) rows indexed in \(Self.seconds(all)); followed again, unchanged, in "
                + "\(Self.seconds(unchanged)).")
            return PhotoKitCensusReport.Index(
                assets: first.assets, rows: first.inserted.count, videos: first.videos, hidden: first.hidden,
                frames: first.frames, firstBatchMilliseconds: first.firstBatch.map { $0 / .milliseconds(1) },
                allMilliseconds: all, unchangedMilliseconds: unchanged, unchangedWhole: again.whole,
                indexMB: Self.megabytes(of: [paths.index, URL(fileURLWithPath: paths.index.path + "-wal")]),
            )
        }

        /// The photos the library lists, in a random order the seed makes again, split into the sample, the edited
        /// ones and the rest.
        static func draw(_ assets: [ApplePhotosAsset], _ plan: Plan) -> Drawn {
            var listed = assets.filter(\.isListed).sorted { $0.id < $1.id }
            var random = SeededRandom(seed: plan.seed)
            for at in listed.indices.reversed() where at > 0 {
                listed.swapAt(at, random.int(below: at + 1))
            }
            let photos = Array(listed.prefix(plan.sample))
            let edited = Array(listed.filter(\.hasAdjustments).prefix(plan.edited))
            let taken = Set(photos.map(\.id)).union(edited.map(\.id))
            return Drawn(photos: photos, edited: edited, rest: listed.filter { !taken.contains($0.id) })
        }

        /// Where Photos has the sample's originals: their photos by asset, and pairs' raws apart.
        struct Localities {
            var photos: [String: ApplePhotosLocality] = [:]
            var pairRaws: [ApplePhotosLocality] = []

            subscript(id: String) -> ApplePhotosLocality? {
                photos[id]
            }

            /// The group a photo is counted in: where its original is.
            func group(of id: String) -> String {
                photos[id].map(PhotoKitCensus.label) ?? "unknown"
            }
        }

        func localities(of photos: [ApplePhotosAsset]) async -> Localities {
            say("Asking Photos, without the network, which of \(photos.count) photos' originals are on this Mac.")
            var found = Localities()
            for asset in photos {
                if let photo = asset.resource(.photo) {
                    found.photos[asset.id] = await probe.locality(of: photo, of: asset.id)
                }
                if asset.isPair, let raw = asset.resource(.alternatePhoto) {
                    await found.pairRaws.append(probe.locality(of: raw, of: asset.id))
                }
            }
            return found
        }

        // MARK: - Changes

        /// Photos' history as LIB-61 reads it: since a token taken just before, and since the census began.
        func readChanges(since began: Data?) async throws -> PhotoKitCensusReport.Changes {
            say("Reading Photos' change history.")
            guard let now = photos.changeToken() else { throw ApplePhotosError.expiredToken }
            var clock = ContinuousClock.now
            _ = try await photos.changes(since: now)
            let unchanged = Self.milliseconds(since: clock)
            var sinceStart: [String: Int] = [:]
            var sinceStartTime: Double?
            if let began {
                clock = .now
                let changes = try await photos.changes(since: began)
                sinceStartTime = Self.milliseconds(since: clock)
                sinceStart = Self.counts(of: changes)
            }
            return PhotoKitCensusReport.Changes(
                unchangedMilliseconds: unchanged, sinceStartMilliseconds: sinceStartTime, sinceStart: sinceStart,
                tokenBytes: now.count,
            )
        }

        static func counts(of changes: ApplePhotosChanges) -> [String: Int] {
            [
                "inserted": changes.inserted.count, "updated": changes.updated.count, "deleted": changes.deleted.count,
                "collections": changes.collections.count,
            ]
        }
    }
#endif
