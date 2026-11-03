#if DEBUG || REDLAMP_PROFILING
    import Foundation

    public extension PhotoKitCensusReport {
        /// The report in lines, beside the design's budgets, as `census.txt` holds it.
        func lines() -> [String] {
            var lines = ["Redlamp's census of this Mac's Photos library (LIB-57)"]
            lines.append("Mac: " + [
                mac.model, mac.chip, "\(mac.memoryGB) GB", "macOS \(mac.macOS)",
                mac.redlamp.map { "Redlamp \($0)" + (mac.commit.map { " (\($0))" } ?? "") },
                "\(mac.performanceCores) performance cores",
                mac.reachable ? (mac.expensive ? "network expensive or constrained" : "network up") : "offline",
            ].compactMap(\.self).joined(separator: ", "))
            lines.append("Access to Photos: \(access.rawValue)")
            if let library {
                lines += Self.lines(library)
            }
            if let index {
                lines.append("Kept in place (LIB-58): \(index.rows) rows of \(index.assets) assets in "
                    + "\(Self.time(index.allMilliseconds)), the first batch in \(index.firstBatchMilliseconds.map(Self.time) ?? "none") "
                    + "(budgets for 50,000: 15 s and 1 s); followed again unchanged in \(Self.time(index.unchangedMilliseconds))"
                    +
                    "\(index.unchangedWhole ? ", comparing the albums whole" : "") (budget 200 ms); index \(index.indexMB) MB")
            }
            if let sample {
                lines.append("Sample: \(sample.photos) photos, originals \(Self.list(sample.originals))"
                    + (sample.pairRaws.isEmpty ? "" : "; pairs' raws \(Self.list(sample.pairRaws))")
                    + "; \(sample.edited) edited in Photos")
            }
            if let images {
                lines += Self.lines(images)
            }
            if let exif {
                lines.append("The camera's fields in Photos' local data (decision 10):")
                for (group, read) in exif.byOriginal.sorted(by: { $0.key < $1.key }) {
                    lines.append("  originals \(Self.place(group)): data for \(read.given) of \(read.asked)"
                        + (read.megabytes.map { ", \(Self.spread($0, " MB"))" } ?? "")
                        + (read.longEdge.map { ", long side \(Self.spread($0, " px"))" } ?? "")
                        + (read.fields.isEmpty ? "" : "; fields \(Self.list(read.fields))")
                        + (read.types.isEmpty ? "" : "; \(Self.list(read.types))"))
                }
            }
            if let changes {
                lines.append(
                    "Changes (LIB-61): read unchanged in \(Self.time(changes.unchangedMilliseconds)) (budget 200 ms)"
                        +
                        (changes.sinceStartMilliseconds
                            .map { "; since the census began, in \(Self.time($0)): " } ?? "")
                        + Self.list(changes.sinceStart),
                )
            }
            if let downloads {
                lines += Self.lines(downloads)
            }
            lines += laterLines()
            if !notes.isEmpty {
                lines.append("Not measured: " + notes.joined(separator: "; "))
            }
            return lines
        }

        /// The cancelled downloads, and the steps after the first.
        private func laterLines() -> [String] {
            var lines: [String] = []
            if let cancels, cancels.asked > 0 {
                lines.append(
                    "Cancelled downloads: \(cancels.cancelled) of \(cancels.asked) cancelled (\(Self.list(cancels.at)))"
                        + (cancels.finishedFirst > 0 ? ", \(cancels.finishedFirst) finished first" : "")
                        +
                        (cancels.stoppedMilliseconds
                            .map { "; ended \(Self.spread($0, " ms")) after cancelling" } ?? "")
                        + (cancels.megabytesWhenCancelled.map { ", \(Self.spread($0, " MB")) written by then" } ?? "")
                        + "; \(cancels.grewAfterwards) written to afterwards; ended \(Self.list(cancels.ended)); "
                        + "Photos has them: \(Self.list(cancels.afterwards))",
                )
            }
            if let recovered {
                lines.append("Recovered from Recently Deleted, \(Int(recovered.minutesAfterCensus)) minutes on: "
                    + "\(recovered.changeSets) changes (\(Self.list(recovered.changed))); deleted photos' changes "
                    + "\(Self.list(recovered.patterns)); back under their own identifier \(recovered.sameIdentifier), "
                    + "under a new one \(recovered.newIdentifier), not back \(recovered.notBack); "
                    + "read all at once as \(Self.list(recovered.readAs))"
                    + (recovered.index.map { "; LIB-61's pass: \(Self.pass($0))" } ?? ""))
            }
            if let offline {
                lines.append("Offline: \(offline.reachable ? "the network could be reached" : "no network"); "
                    + (offline.tried
                        ? "a download ended \(offline.ended ?? "") after \(offline.milliseconds.map(Self.time) ?? "")"
                        + "\(offline.asOffline ? ", named as iCloud out of reach" : ", not named as iCloud out of reach"); "
                        + "its preview \(offline.preview ?? "")"
                        : "no original only in iCloud left to try"))
            }
            if let week {
                lines.append("A week on (\(String(format: "%.1f", week.days)) days): "
                    + (week.expired ? "Photos no longer has its history since the census"
                        : "history read in \(week.milliseconds.map(Self.time) ?? ""), \(week.changeSets ?? 0) changes "
                        + "(\(Self.list(week.changed)))")
                    + "; downloaded originals \(Self.list(week.downloaded)), cancelled \(Self.list(week.cancelled))"
                    + (week.index.map { "; LIB-61's pass: \(Self.pass($0))" } ?? ""))
            }
            return lines
        }

        private static func lines(_ library: Library) -> [String] {
            [
                "Photos' Library: \(library.assets) assets, \(library.photos) photos listed; \(library.videos) videos, "
                    + "\(library.hidden) hidden, \(library.burstFramesLeft) burst frames left; edited in Photos "
                    + "\(library.edited) (rendering kept \(library.editsRendered)); raws \(library.raws), RAW+JPEG pairs "
                    + "\(library.pairs), DNGs \(library.dngs); Live \(library.live), screenshots \(library.screenshots), "
                    + "shared \(library.shared)",
                "  collections \(list(library.collections)); read in \(list(library.milliseconds.mapValues(time)))"
                    + "; memory \(library.footprintMB["before"] ?? 0) → \(library.footprintMB["after"] ?? 0) MB"
                    + (library.longEdge.map { "; originals' long side \(spread($0, " px"))" } ?? ""),
                "  originals \(list(library.types))" + (library.pairRawTypes.isEmpty ? "" : "; pairs' raws "
                    + list(library.pairRawTypes)),
            ]
        }

        private static func lines(_ images: Images) -> [String] {
            var lines = ["Photos' images without the network (LIB-59):"]
            for (group, sizes) in images.current.sorted(by: { $0.key < $1.key }) {
                lines.append("  originals \(place(group)), \(sizes.grid.asked) photos:")
                lines += Self.lines(sizes)
            }
            for (version, sizes) in images.edited.sorted(by: { $0.key < $1.key }) {
                lines.append("  edited in Photos, the \(version) version, \(sizes.grid.asked) photos:")
                lines += Self.lines(sizes)
            }
            for screenfuls in images.screenfuls {
                lines.append("  \(screenfuls.count) screenful\(screenfuls.count == 1 ? "" : "s") of "
                    + "\(screenfuls.thumbnails) grid thumbnails on "
                    + "\(screenfuls.lanes) lanes\(screenfuls.cached ? ", prepared ahead" : ""): "
                    + (screenfuls.milliseconds.map { spread($0, " ms") } ?? "") + " (budget p95 250 ms); "
                    +
                    "given \(screenfuls.given), only in iCloud \(screenfuls.inCloud), unavailable \(screenfuls.unavailable)")
            }
            return lines
        }

        private static func lines(_ sizes: Sizes) -> [String] {
            func requests(_ name: String, _ requests: Requests) -> String {
                "    \(name): given \(requests.given), only in iCloud \(requests.inCloud), unavailable \(requests.unavailable)"
                    + (requests.longEdge.map { ", long side \(spread($0, " px"))" } ?? "")
                    + (requests.milliseconds.map { ", \(spread($0, " ms"))" } ?? "")
            }
            return [
                requests("grid, 384", sizes.grid),
                requests("preview, 2048", sizes.preview),
                "    largest kept: given \(sizes.largest.given) of \(sizes.largest.asked)"
                    + (sizes.largest.longEdge.map { ", long side \(spread($0, " px"))" } ?? "")
                    + (sizes.largest.ofOriginal.map { ", \(spread($0, "%")) of the original's" } ?? ""),
            ]
        }

        private static func lines(_ downloads: Downloads) -> [String] {
            let before = downloads.freeBefore["available"]
            let after = downloads.freeAfter["available"]
            return [
                "Downloads from iCloud (LIB-60): \(downloads.completed) of \(downloads.asked) (\(list(downloads.types)))"
                    + (downloads.failed.isEmpty ? "" : "; failed \(list(downloads.failed))")
                    + (downloads.megabytes.map { "; \(spread($0, " MB"))" } ?? "")
                    + (downloads.seconds.map { " in \(spread($0, " s"))" } ?? "")
                    + (downloads.megabytesPerSecond.map { ", \(spread($0, " MB/s"))" } ?? ""),
                "  Photos' first progress \(downloads.firstProgressMilliseconds.map { spread($0, " ms") } ?? "never"), "
                    + "first above nothing \(downloads.firstBytesMilliseconds.map { spread($0, " ms") } ?? "never"), "
                    + "\(downloads.progressCalls.map { spread($0, "") } ?? "no") progress calls each; afterwards "
                    + "Photos has them: \(list(downloads.afterwards))"
                    + (before.flatMap { before in after.map { after in
                        "; free space \(String(format: "%+.0f", Double(after - before) / 1_000_000)) MB"
                    } } ?? ""),
            ]
        }

        private static func pass(_ pass: Pass) -> String {
            "\(time(pass.milliseconds))\(pass.whole ? " comparing whole" : ""), inserted \(pass.inserted), "
                + "updated \(pass.updated), removed \(pass.removed), missing \(pass.missing)"
        }

        private static func place(_ group: String) -> String {
            switch group {
            case "local": "on this Mac"
            case "inCloud": "only in iCloud"
            default: group
            }
        }

        private static func time(_ milliseconds: Double) -> String {
            milliseconds < 1000 ? String(format: "%.1f ms", milliseconds) : String(
                format: "%.1f s",
                milliseconds / 1000,
            )
        }

        private static func spread(_ spread: Spread, _ unit: String) -> String {
            func value(_ value: Double) -> String {
                value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
            }
            return "p50 \(value(spread.p50))\(unit), p95 \(value(spread.p95))\(unit), "
                + "\(value(spread.min)) to \(value(spread.max))\(unit) over \(spread.count)"
        }

        private static func list(_ counts: [String: some CustomStringConvertible]) -> String {
            counts.isEmpty ? "none" : counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
                .joined(separator: ", ")
        }
    }
#endif
