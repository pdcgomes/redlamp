#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import Photos
    import RedlampLibrary
    import Synchronization

    /// What the census of this Mac's Photos library (LIB-57) reads PhotoKit through, for the app's `--photos-census`:
    /// the
    /// images the store asks Photos for (LIB-59) and the probe.
    public enum PhotoKitCensusPhotos {
        public static let images: any ApplePhotosImages = PhotoKitImages.shared
        public static let probe: any ApplePhotosProbe = PhotoKitProbe()
    }

    /// What the census of a Photos library (LIB-57) asks of PhotoKit beyond what the library reads, each without the
    /// network: Photos' Library smart album, whether a file is on this Mac, the largest image Photos keeps of a
    /// picture,
    /// the picture's data with its metadata, and the persistent history change by change. The app's, as `requestImage`
    /// gives an `NSImage` on the Mac. What PhotoKit answers is what the census is for; nothing here is checked against
    /// Photos until it runs.
    final class PhotoKitProbe: ApplePhotosProbe {
        func libraryCollection() async throws -> String? {
            PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumUserLibrary, options: nil)
                .firstObject?.localIdentifier
        }

        /// Asks for the file's data without the network and stops at its first chunk: one only in iCloud fails at once.
        func locality(of resource: ApplePhotosResource, of asset: String) async -> ApplePhotosLocality {
            guard let found = Self.assets([asset]).first else { return .unknown("notFound") }
            let resources = PHAssetResource.assetResources(for: found)
            guard let source = resources.first(where: {
                Self.kind(of: $0) == resource.kind && $0.originalFilename == resource.originalFilename
            }) ?? resources.first(where: { Self.kind(of: $0) == resource.kind })
            else { return .unknown("noSuchFile") }
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = false
            let read = Read()
            return await withCheckedContinuation { continuation in
                let id = PHAssetResourceManager.default().requestData(for: source, options: options) { _ in
                    if read.arrived() {
                        read.stop()
                    }
                } completionHandler: { error in
                    if read.hasArrived || error == nil {
                        continuation.resume(returning: .local)
                    } else if let error {
                        continuation.resume(returning: Self.needsNetwork(error)
                            ? .inCloud : .unknown(PhotoKitCensus.name(of: error)))
                    }
                }
                read.started(id)
            }
        }

        /// A request for a file's data, stopped once its first chunk has arrived, whichever comes first: its first
        /// chunk
        /// or its ID.
        private final class Read: Sendable {
            private let state = Mutex<(id: PHAssetResourceDataRequestID?, arrived: Bool, stopped: Bool)>((
                nil,
                false,
                false,
            ))

            /// Whether this is the first chunk.
            func arrived() -> Bool {
                state.withLock { state in
                    defer { state.arrived = true }
                    return !state.arrived
                }
            }

            var hasArrived: Bool {
                state.withLock(\.arrived)
            }

            func started(_ id: PHAssetResourceDataRequestID) {
                let stopping = state.withLock { state in
                    state.id = id
                    return state.arrived && !state.stopped
                }
                if stopping {
                    stop()
                }
            }

            func stop() {
                let id = state.withLock { state -> PHAssetResourceDataRequestID? in
                    guard let id = state.id, !state.stopped else { return nil }
                    state.stopped = true
                    return id
                }
                if let id {
                    PHAssetResourceManager.default().cancelDataRequest(id)
                }
            }
        }

        /// Asked at Photos' largest size, at the size it keeps the picture, the degraded images it gives first counted
        /// with
        /// its last.
        func largestImage(of asset: String, version: ApplePhotosImageVersion) -> Int? {
            guard let found = Self.assets([asset]).first else { return nil }
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = false
            options.deliveryMode = .opportunistic
            options.resizeMode = .none
            options.version = version == .current ? .current : .original
            let largest = Mutex(0)
            let answered = DispatchSemaphore(value: 0)
            PHImageManager.default().requestImage(
                for: found, targetSize: PHImageManagerMaximumSize, contentMode: .default, options: options,
            ) { image, info in
                if let image {
                    let edge = Self.longEdge(of: image)
                    largest.withLock { $0 = max($0, edge) }
                }
                if info?[PHImageResultIsDegradedKey] as? Bool != true {
                    answered.signal()
                }
            }
            _ = answered.wait(timeout: .now() + 60)
            let edge = largest.withLock { $0 }
            return edge > 0 ? edge : nil
        }

        /// The largest data Photos gives: its high-quality data, or else its fast one.
        func imageData(of asset: String, version: ApplePhotosImageVersion) -> Data? {
            guard let found = Self.assets([asset]).first else { return nil }
            for mode in [PHImageRequestOptionsDeliveryMode.highQualityFormat, .fastFormat] {
                let options = PHImageRequestOptions()
                options.isNetworkAccessAllowed = false
                options.isSynchronous = true
                options.deliveryMode = mode
                options.version = version == .current ? .current : .original
                let data = Mutex<Data?>(nil)
                PHImageManager.default()
                    .requestImageDataAndOrientation(for: found, options: options) { found, _, _, _ in
                        data.withLock { $0 = found }
                    }
                if let data = data.withLock({ $0 }) {
                    return data
                }
            }
            return nil
        }

        func changeSets(since token: Data) async throws -> [ApplePhotosChanges] {
            guard let since = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: PHPersistentChangeToken.self,
                from: token,
            )
            else { throw ApplePhotosError.expiredToken }
            let result: PHPersistentChangeFetchResult
            do {
                result = try PHPhotoLibrary.shared().fetchPersistentChanges(since: since)
            } catch let error as PHPhotosError
                where [.persistentChangeTokenExpired, .persistentChangeDetailsUnavailable].contains(error.code) {
                throw ApplePhotosError.expiredToken
            }
            var sets: [ApplePhotosChanges] = []
            for change in result {
                let assets = try change.changeDetails(for: .asset)
                var collections = Set<String>()
                for type in [PHObjectType.assetCollection, .collectionList] {
                    let details = try change.changeDetails(for: type)
                    collections.formUnion(details.insertedLocalIdentifiers)
                    collections.formUnion(details.updatedLocalIdentifiers)
                    collections.formUnion(details.deletedLocalIdentifiers)
                }
                sets.append(ApplePhotosChanges(
                    inserted: assets.insertedLocalIdentifiers, updated: assets.updatedLocalIdentifiers,
                    deleted: assets.deletedLocalIdentifiers, collections: collections,
                    token: (try? NSKeyedArchiver.archivedData(
                        withRootObject: change.changeToken,
                        requiringSecureCoding: true,
                    ))
                        ?? Data(),
                ))
            }
            return sets
        }

        /// Whether `error`, or one under it, is PhotoKit's for a file it can't give without the network.
        private static func needsNetwork(_ error: any Error) -> Bool {
            var errors = [error as NSError]
            while let next = errors.popLast() {
                if next.domain == PHPhotosErrorDomain, next.code == PHPhotosError.networkAccessRequired.rawValue {
                    return true
                }
                if let under = next.userInfo[NSUnderlyingErrorKey] as? NSError {
                    errors.append(under)
                }
            }
            return false
        }

        private static func longEdge(of image: NSImage) -> Int {
            let represented = image.representations.map { max($0.pixelsWide, $0.pixelsHigh) }.max() ?? 0
            let drawn = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                .map { max($0.width, $0.height) } ?? 0
            return max(represented, drawn)
        }

        private static func kind(of resource: PHAssetResource) -> ApplePhotosResource.Kind {
            switch resource.type {
            case .photo: .photo
            case .alternatePhoto: .alternatePhoto
            case .fullSizePhoto: .fullSizePhoto
            case .pairedVideo: .pairedVideo
            default: .other
            }
        }

        /// The assets `ids` names, burst frames and hidden photos included, as the library reads them.
        private static func assets(_ ids: [String]) -> [PHAsset] {
            let options = PHFetchOptions()
            options.includeHiddenAssets = true
            options.includeAllBurstAssets = true
            let found = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: options)
            return found.objects(at: IndexSet(integersIn: 0 ..< found.count))
        }
    }
#endif
