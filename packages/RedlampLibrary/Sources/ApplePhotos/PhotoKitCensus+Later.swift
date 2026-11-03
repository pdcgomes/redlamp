#if DEBUG || REDLAMP_PROFILING
    import Foundation

    /// The census's later steps, from what `measure` kept on this Mac: after a photo is recovered from Recently
    /// Deleted,
    /// with the Mac offline, and a week on.
    extension PhotoKitCensus {
        /// What the later steps need, kept in the census's folder on this Mac and never in the report: the photos it
        /// downloaded, cancelled and left alone by identifier, Photos' change token after `measure`, and the asset keys
        /// of
        /// the Library's photos.
        struct State: Codable {
            static let format = "app.redlamp.photokit-census-state"

            var format = Self.format
            var measured: Date
            var token: Data?
            var downloaded: [Pick]
            var cancelled: [Pick]
            var spares: [Pick]
            /// Each asset's key from its local identifier alone, with its key from its cloud identifier, for those with
            /// one: how a photo recovered under a new local identifier is found again (`ApplePhotosPlace.key`).
            var clouds: [String: String]
            /// The Library is kept in the census's own index.
            var indexed: Bool
        }

        /// One of an asset's files.
        struct Pick: Codable, Hashable {
            var asset: String
            var resource: ApplePhotosResource

            init(asset: String, resource: ApplePhotosResource) {
                self.asset = asset
                self.resource = resource
            }

            init?(photo asset: ApplePhotosAsset) {
                guard let photo = asset.resource(.photo) else { return nil }
                self.init(asset: asset.id, resource: photo)
            }
        }

        /// No `measure` has run in this folder, or the last step deleted what it kept.
        public struct NotMeasured: Error, CustomStringConvertible {
            public var description: String {
                "the census hasn't measured this Mac's library yet, or its week has ended: run its first step"
            }
        }

        func save(_ state: State) throws {
            try FileManager.default.createDirectory(at: stateFolder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(state).write(to: stateURL, options: .atomic)
        }

        func loadState() throws -> State {
            guard let data = try? Data(contentsOf: stateURL) else { throw NotMeasured() }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let state = try decoder.decode(State.self, from: data)
            guard state.format == State.format else { throw NotMeasured() }
            return state
        }

        /// The report the steps before wrote, to add this one's part to.
        func loadReport() throws -> PhotoKitCensusReport {
            guard let data = try? Data(contentsOf: reportURL) else { throw NotMeasured() }
            return try PhotoKitCensusReport.read(data)
        }

        static func clouds(of assets: [ApplePhotosAsset]) -> [String: String] {
            var clouds: [String: String] = [:]
            for asset in assets {
                if let cloud = asset.cloud {
                    clouds[ApplePhotosPlace.key(cloud: nil, local: asset.id)] = ApplePhotosPlace.key(
                        cloud: cloud,
                        local: asset.id,
                    )
                }
            }
            return clouds
        }

        /// Follows Photos in the index the census kept, as Redlamp does at a launch (LIB-61).
        func followKept() async throws -> PhotoKitCensusReport.Pass {
            let index = try await LibraryIndex.open(at: kept.index, readers: 2)
            let outcome: ApplePhotosIndexer.Outcome
            do {
                outcome = try await ApplePhotosIndexer(photos: photos, index: index, paths: kept).update()
            } catch {
                await index.close()
                throw error
            }
            await index.close()
            return PhotoKitCensusReport.Pass(
                milliseconds: outcome.elapsed / .milliseconds(1), whole: outcome.whole,
                inserted: outcome.inserted.count,
                updated: outcome.updated.count, removed: outcome.removed.count, missing: outcome.missing.count,
            )
        }

        // MARK: - Recovered

        /// After a photo was deleted in Photos and recovered from Recently Deleted: how Photos' history tells of it,
        /// whether
        /// the photo has its local identifier again, and how LIB-61 takes it.
        func recovered() async throws -> PhotoKitCensusReport {
            var report = try loadReport()
            let state = try loadState()
            guard let token = state.token else { throw NotMeasured() }
            say("Reading Photos' changes since the census, change by change.")
            let sets: [ApplePhotosChanges]
            let together: ApplePhotosChanges
            do {
                sets = try await probe.changeSets(since: token)
                together = try await photos.changes(since: token)
            } catch ApplePhotosError.expiredToken {
                say("Photos no longer has its history since the census.")
                report.notes.append("recovered: expiredToken")
                return report
            }
            let deleted = sets.reduce(into: Set<String>()) { $0.formUnion($1.deleted) }
            var events: [String: [String]] = [:]
            for set in sets {
                for (event, ids) in [("deleted", set.deleted), ("inserted", set.inserted), ("updated", set.updated)] {
                    for id in ids where deleted.contains(id) {
                        events[id, default: []].append(event)
                    }
                }
            }
            let back = try await Set(photos.assets(withIDs: Array(deleted)).map(\.id))
            let inserted = sets.reduce(into: Set<String>()) { $0.formUnion($1.inserted) }.subtracting(deleted)
            let insertedKeys = try await Set(photos.assets(withIDs: Array(inserted)).compactMap { asset in
                asset.cloud.map { ApplePhotosPlace.key(cloud: $0, local: asset.id) }
            })
            var found = PhotoKitCensusReport.Recovered(
                minutesAfterCensus: Date.now.timeIntervalSince(state.measured) / 60, changeSets: sets.count,
                changed: Self.counts(of: sets.reduce(into: ApplePhotosChanges(token: Data())) { all, set in
                    all.inserted.formUnion(set.inserted)
                    all.updated.formUnion(set.updated)
                    all.deleted.formUnion(set.deleted)
                    all.collections.formUnion(set.collections)
                }),
                patterns: Self.tally(deleted.map { events[$0, default: []].joined(separator: ", ") }),
                sameIdentifier: 0, newIdentifier: 0, notBack: 0, readAs: [:],
            )
            for id in deleted {
                if back.contains(id) {
                    found.sameIdentifier += 1
                } else if let key = state.clouds[ApplePhotosPlace.key(cloud: nil, local: id)],
                          insertedKeys.contains(key) {
                    found.newIdentifier += 1
                } else {
                    found.notBack += 1
                }
                let readAs = together.deleted.contains(id) ? "deleted"
                    : together.inserted.contains(id) ? "inserted" : together.updated.contains(id) ? "updated" : "none"
                found.readAs[readAs, default: 0] += 1
            }
            if deleted.isEmpty {
                say("Photos' history tells of no photo deleted since the census.")
            }
            if state.indexed {
                say("Following Photos in the census's index, as Redlamp does at a launch.")
                found.index = await attempt("recovered index", &report.notes) { try await followKept() }
            }
            report.recovered = found
            say("\(deleted.count) deleted since the census: \(found.sameIdentifier) back under their own identifier, "
                + "\(found.newIdentifier) under a new one, \(found.notBack) not back.")
            return report
        }

        // MARK: - Offline

        /// With the Mac offline: a download of an original only in iCloud, and how the library names its failure
        /// (LIB-60).
        func offline(_ plan: Plan) async throws -> PhotoKitCensusReport {
            var report = try loadReport()
            let state = try loadState()
            var found = PhotoKitCensusReport.Offline(reachable: network.isReachable, tried: false, asOffline: false)
            if found.reachable {
                say("macOS says the network can be reached: turn Wi-Fi off, unplug Ethernet, and run this step again.")
            }
            var chosen: Pick?
            for pick in state.spares + state.cancelled {
                if await probe.locality(of: pick.resource, of: pick.asset) == .inCloud {
                    chosen = pick
                    break
                }
            }
            if let pick = chosen {
                say("Downloading one original only in iCloud, offline.")
                found.tried = true
                let url = scratch.appending(path: UUID().uuidString)
                let started = ContinuousClock.now
                do {
                    try await Self.within(plan.timeout) { [photos] in
                        try await photos.write(pick.resource, of: pick.asset, to: url) { _ in }
                    }
                    found.ended = "completed"
                } catch {
                    found.ended = Self.name(of: error)
                    if let failure = error as? ApplePhotosError, case .offline = failure {
                        found.asOffline = true
                    }
                }
                found.milliseconds = (ContinuousClock.now - started) / .milliseconds(1)
                try? FileManager.default.removeItem(at: url)
                let preview = await Self.blocking { [images] in
                    images.image(of: pick.asset, version: .current, size: PhotoStore.Tier.preview.pixelSize)
                }
                found.preview = switch preview {
                case .image: "given"
                case .inCloud: "inCloud"
                case .unavailable: "unavailable"
                }
                say("It ended \(found.ended ?? ""), \(found.asOffline ? "as" : "not as") iCloud out of reach.")
            } else {
                say("None of the originals the census left alone is still only in iCloud.")
            }
            report.offline = found
            return report
        }

        // MARK: - A week on

        /// A week on: whether Photos still has its history since the census and how long reading it takes, where the
        /// originals the census downloaded are now, and LIB-61 following a week of changes. Then it deletes what the
        /// census kept on this Mac.
        func week() async throws -> PhotoKitCensusReport {
            var report = try loadReport()
            let state = try loadState()
            guard let token = state.token else { throw NotMeasured() }
            say("Reading Photos' history since the census.")
            let started = ContinuousClock.now
            var found = PhotoKitCensusReport.Week(
                days: Date.now.timeIntervalSince(state.measured) / 86400, expired: false, changed: [:], downloaded: [:],
                cancelled: [:], free: Self.free(),
            )
            do {
                found.changed = try await Self.counts(of: photos.changes(since: token))
                found.milliseconds = (ContinuousClock.now - started) / .milliseconds(1)
                found.changeSets = try await probe.changeSets(since: token).count
            } catch ApplePhotosError.expiredToken {
                found.expired = true
            }
            for pick in state.downloaded {
                let now = await probe.locality(of: pick.resource, of: pick.asset)
                found.downloaded[Self.label(now), default: 0] += 1
            }
            for pick in state.cancelled {
                let now = await probe.locality(of: pick.resource, of: pick.asset)
                found.cancelled[Self.label(now), default: 0] += 1
            }
            if state.indexed {
                say("Following a week of Photos' changes in the census's index, as Redlamp does at a launch.")
                found.index = await attempt("week index", &report.notes) { try await followKept() }
            }
            report.week = found
            try FileManager.default.removeItem(at: stateFolder)
            say((found.expired ? "Photos no longer has its history since the census. "
                    : "Photos has its history since the census: \(found.changeSets ?? 0) changes. ")
                + "What the census kept on this Mac is deleted.")
            return report
        }
    }
#endif
