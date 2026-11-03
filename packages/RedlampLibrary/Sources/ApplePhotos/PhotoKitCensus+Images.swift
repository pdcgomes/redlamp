#if DEBUG || REDLAMP_PROFILING
    import CoreGraphics
    import Foundation
    import ImageIO
    import Synchronization
    import UniformTypeIdentifiers

    /// Photos' images as LIB-59 asks for them (`ApplePhotosImages`), the largest Photos keeps, screenfuls of the grid,
    /// and
    /// the camera's fields in Photos' local data (decision 10).
    extension PhotoKitCensus {
        func measureImages(_ drawn: Drawn, localities: Localities, _ plan: Plan) async -> PhotoKitCensusReport.Images {
            say("Asking Photos, without the network, for \(drawn.photos.count) photos' images at the grid's and the "
                +
                "preview's sizes and the largest it keeps, then the versions of \(drawn.edited.count) edited in Photos.")
            var current: [String: PhotoKitCensusReport.Sizes] = [:]
            for (group, photos) in Dictionary(grouping: drawn.photos, by: { localities.group(of: $0.id) }) {
                current[group] = await Self.blocking { sizes(of: photos, version: .current) }
            }
            var edited: [String: PhotoKitCensusReport.Sizes] = [:]
            if !drawn.edited.isEmpty {
                for version in [ApplePhotosImageVersion.current, .original] {
                    edited[version.rawValue] = await Self.blocking { sizes(of: drawn.edited, version: version) }
                }
            }
            say("Asking for \(plan.screenfuls) screenfuls of \(plan.screenful) grid thumbnails on \(plan.lanes) lanes, "
                + "then \(plan.cachedScreenfuls) prepared ahead by the caching manager.")
            let fresh = Array(drawn.rest.prefix(plan.screenful * plan.screenfuls))
            let ahead = Array(drawn.rest.dropFirst(fresh.count).prefix(plan.screenful * plan.cachedScreenfuls))
            let asked = await [screenfuls(of: fresh, cached: false, plan), screenfuls(of: ahead, cached: true, plan)]
            return PhotoKitCensusReport.Images(
                current: current,
                edited: edited,
                screenfuls: asked.filter { $0.count > 0 },
            )
        }

        /// Each photo's `version` asked of Photos at the store's two sizes, as LIB-59 asks it, and at the largest it
        /// keeps.
        func sizes(of photos: [ApplePhotosAsset], version: ApplePhotosImageVersion) -> PhotoKitCensusReport.Sizes {
            var grid = RequestTally()
            var preview = RequestTally()
            var largest = LargestTally()
            for asset in photos {
                grid.ask(images, asset.id, version, .grid)
                preview.ask(images, asset.id, version, .preview)
                largest.add(
                    probe.largestImage(of: asset.id, version: version),
                    original: Self.longEdge(of: asset.resource(.photo)),
                )
            }
            return PhotoKitCensusReport.Sizes(grid: grid.report, preview: preview.report, largest: largest.report)
        }

        /// Screenfuls of `photos`' grid thumbnails, each asked at once on the plan's lanes and made into the store's
        /// thumbnails; `cached`, prepared ahead by the caching manager as the grid prepares the rows near the screen.
        func screenfuls(
            of photos: [ApplePhotosAsset], cached: Bool, _ plan: Plan,
        ) async -> PhotoKitCensusReport.Screenfuls {
            var times: [Double] = []
            var made = (given: 0, inCloud: 0, unavailable: 0)
            let size = PhotoStore.Tier.grid.pixelSize
            for start in stride(from: 0, to: photos.count, by: plan.screenful) {
                let batch = Array(photos[start ..< min(start + plan.screenful, photos.count)])
                if cached {
                    images.cache(
                        Set(batch.map { ApplePhotosPicture(asset: $0.id, version: .current) }),
                        size: size,
                        window: "census",
                    )
                    try? await Task.sleep(for: plan.preparing)
                }
                let (elapsed, counts) = await Self.blocking { screenful(batch, lanes: plan.lanes) }
                if cached {
                    images.cache([], size: size, window: "census")
                }
                times.append(elapsed)
                made.given += counts.given
                made.inCloud += counts.inCloud
                made.unavailable += counts.unavailable
            }
            return PhotoKitCensusReport.Screenfuls(
                cached: cached, count: times.count, thumbnails: plan.screenful, lanes: plan.lanes, given: made.given,
                inCloud: made.inCloud, unavailable: made.unavailable, milliseconds: PhotoKitCensusReport.Spread(times),
            )
        }

        /// One screenful: its thumbnails asked on `lanes` threads, each made into the store's grid tier as it comes.
        func screenful(_ batch: [ApplePhotosAsset], lanes: Int) -> (Double, (
            given: Int,
            inCloud: Int,
            unavailable: Int,
        )) {
            let shared = Screenful()
            let encoder = StoreImageEncoder()
            let started = ContinuousClock.now
            DispatchQueue.concurrentPerform(iterations: max(min(lanes, batch.count), 1)) { _ in
                while let at = shared.next(below: batch.count) {
                    let answer = images.image(of: batch[at].id, version: .current, size: PhotoStore.Tier.grid.pixelSize)
                    if case let .image(image) = answer {
                        _ = encoder.encode(image, for: .grid)
                    }
                    shared.count(answer)
                }
            }
            return (Self.milliseconds(since: started), shared.counts.withLock { $0 })
        }

        /// What a screenful's lanes share: the next thumbnail to ask for, and what Photos gave.
        final class Screenful: Sendable {
            private let taken = Mutex(0)
            let counts = Mutex((given: 0, inCloud: 0, unavailable: 0))

            func next(below count: Int) -> Int? {
                taken.withLock { taken in
                    guard taken < count else { return nil }
                    defer { taken += 1 }
                    return taken
                }
            }

            func count(_ answer: ApplePhotosImage) {
                counts.withLock { counts in
                    switch answer {
                    case .image: counts.given += 1
                    case .inCloud: counts.inCloud += 1
                    case .unavailable: counts.unavailable += 1
                    }
                }
            }
        }

        // MARK: - EXIF

        /// The camera's fields in Photos' local images (decision 10): the data Photos gives of each picture without the
        /// network, read as the library reads a file's metadata, for photos whose originals are only in iCloud and, to
        /// compare, some whose originals are on this Mac.
        func readEXIF(_ photos: [ApplePhotosAsset], localities: Localities, _ plan: Plan) async -> PhotoKitCensusReport
            .EXIF {
            let inCloud = Array(photos.filter { localities[$0.id] == .inCloud }.prefix(plan.exifInCloud))
            let local = Array(photos.filter { localities[$0.id] == .local }.prefix(plan.exifLocal))
            say("Reading the camera's fields from Photos' local data of \(inCloud.count) photos only in iCloud and "
                + "\(local.count) on this Mac.")
            var read: [String: PhotoKitCensusReport.EXIF.Read] = [:]
            for (group, assets) in [("inCloud", inCloud), ("local", local)] where !assets.isEmpty {
                read[group] = await Self.blocking { exif(of: assets) }
            }
            return PhotoKitCensusReport.EXIF(byOriginal: read)
        }

        func exif(of assets: [ApplePhotosAsset]) -> PhotoKitCensusReport.EXIF.Read {
            var read = PhotoKitCensusReport.EXIF.Read()
            var megabytes: [Double] = []
            var edges: [Double] = []
            for asset in assets {
                read.asked += 1
                guard let data = probe.imageData(of: asset.id, version: .current) else { continue }
                read.given += 1
                megabytes.append(Double(data.count) / 1_000_000)
                let type = CGImageSourceCreateWithData(data as CFData, nil)
                    .flatMap { CGImageSourceGetType($0) as String? }
                read.types[type ?? "unknown", default: 0] += 1
                let ext = type.flatMap { UTType($0)?.preferredFilenameExtension } ?? "jpeg"
                guard let metadata = PhotoMetadataReader.read(
                    head: data, fileSize: data.count, url: URL(fileURLWithPath: "/census.\(ext)"),
                ) else { continue }
                if let size = metadata.pixelSize {
                    edges.append(Double(max(size.width, size.height)))
                }
                for (field, present) in [
                    ("camera", metadata.cameraName != nil), ("lens", metadata.lens != nil), (
                        "iso",
                        metadata.iso != nil,
                    ),
                    ("aperture", metadata.aperture != nil), ("shutter", metadata.shutter != nil),
                    ("focalLength", metadata.focalLength != nil), ("taken", metadata.captured != nil),
                    ("gps", metadata.latitude != nil),
                ] where present {
                    read.fields[field, default: 0] += 1
                }
            }
            read.megabytes = PhotoKitCensusReport.Spread(megabytes)
            read.longEdge = PhotoKitCensusReport.Spread(edges)
            return read
        }
    }
#endif
