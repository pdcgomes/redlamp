import Foundation
import RedlampDocument

/// What a sync of photos' XMP works with: the library's sidecar locator and settings, and what's
/// recorded of the photos' earlier merges.
struct XMPSyncContext: Sendable {
    let locator: SidecarLocator
    let conventions: XMPConventions
    /// `.xmp` sidecars are written.
    let writes: Bool
    /// Nothing is written: neither sidecars nor records.
    let dryRun: Bool
    /// A photo's first merge takes other apps' fields into its `.redlamp` (`XMPMerge`'s `filling`).
    let fills: Bool
    let fields: Set<XMPField>
    let now: Date
    let records: [Int64: XMPMergeRecord]
}

/// What syncing one group did: each photo's outcome, the records to keep and drop, and the rows to
/// bring up to date.
struct XMPGroupOutcome: Sendable {
    var photos: [XMPPhotoSync] = []
    var records: [Int64: XMPMergeRecord] = [:]
    var dropped: [Int64] = []
    /// Photos whose `.redlamp` took other apps' fields, with its fields as merged.
    var organising: [(id: Int64, fields: XMPFields)] = []
    /// Photos whose `.redlamp` took other apps' keywords, with them.
    var keywords: [(id: Int64, paths: [String])] = []
    /// Photos whose `.redlamp` took other apps' capture time, with its fields as merged.
    var captures: [(id: Int64, fields: XMPFields)] = []
    /// Photos with a `.redlamp` whose `.xmp` Redlamp wrote, with what their rows keep of their `.xmp` files
    /// now: the later modification date and the signature.
    var xmpModified: [(id: Int64, modified: Date, signature: Int64?)] = []
    /// Photos whose `.redlamp` the sync wrote, with its date as its folder's listing gives it, and the
    /// fields it took, which are its own now.
    var sidecars: [(id: Int64, modified: Date, taken: [XMPField])] = []
}

extension XMPGroup {
    /// One member's side of the sync.
    fileprivate struct Side {
        let member: Member
        let photo: URL
        /// Its `.redlamp`'s edit, where the locator reads it.
        var editStamp: XMPFileStamp?
        /// When the sync saved its `.redlamp`, as its folder's listing dates it; nil when it didn't.
        var saved: Date?
        /// The `.redlamp`'s fields; nil when it has none, or it can't be read.
        var redlamp: XMPFields?
        /// Its `.redlamp` is gone since the last sync, as the Undo of the batch that made it leaves it: it
        /// holds nothing now, and takes nothing.
        var removed = false
        var record: XMPMergeRecord?
        var darktable: XMPSource?
        var embedded: XMPSource?
        var other = XMPFields()
        var merge: XMPMerge.Outcome?
        var problem: String?
        /// Its `.redlamp` couldn't take what was merged.
        var failed = false
        var unwritten: [XMPField] = []

        var id: Int64? {
            member.record?.id
        }
    }

    /// The shared `.xmp` as it was read.
    fileprivate struct SharedFile {
        let url: URL
        let stamp: XMPFileStamp?
        let bytes: [UInt8]?
        let packet: XMPPacket?
        let source: XMPSource?
        /// The capture time it gives.
        let captured: XMPCaptureTime?

        /// Listed, but not XMP Redlamp can read: it's never written over.
        var isUnreadable: Bool {
            stamp != nil && packet == nil
        }

        /// What it holds for the photo taken at `camera`, its capture time a shift from the camera's.
        func source(for camera: XMPCaptureTime?) -> XMPSource? {
            source?.capturing(captured, camera: camera)
        }
    }

    /// What the shared `.xmp` gets.
    fileprivate struct Plan {
        var wanted = XMPFields()
        var decided = Set<XMPField>()
        /// The fields each member decides, by its position.
        var deciders: [Int: Set<XMPField>] = [:]
        /// The camera's time of the member that decides the capture time, which `wanted` shifts.
        var camera: XMPCaptureTime?
        /// The fields decided that the `.xmp` doesn't hold.
        var changing = Set<XMPField>()
        /// The `.xmp` with them, once checked.
        var bytes: [UInt8]?
        var problem: String?

        func fields(of position: Int) -> [XMPField] {
            (deciders[position] ?? []).intersection(changing).sorted()
        }
    }

    /// A group's sync worked out up to its writes: each member's merge, and the `.xmp` they share
    /// planned; or, when nothing it reads changed since its records, its outcome.
    struct Pending: Sendable {
        let group: XMPGroup
        private var sides: [Side]
        private let file: SharedFile?
        private var plan: Plan
        private let unchanged: XMPGroupOutcome?

        fileprivate init(group: XMPGroup, sides: [Side], file: SharedFile?, plan: Plan, unchanged: XMPGroupOutcome?) {
            self.group = group
            self.sides = sides
            self.file = file
            self.plan = plan
            self.unchanged = unchanged
        }

        /// The members whose `.redlamp` takes other apps' fields, by their places in the group.
        var takers: [Int] {
            sides.indices.filter { !(sides[$0].merge?.takenIn.isEmpty ?? true) }
        }

        func photo(_ taker: Int) -> URL {
            sides[taker].photo
        }

        /// The member's `.redlamp` with what it took from other apps, keeping everything else in it;
        /// nothing when it can't be read.
        func taking(_ taker: Int, into sidecar: Sidecar?, context: XMPSyncContext) -> SidecarChange {
            guard let merge = sides[taker].merge, var sidecar else { return .keep }
            sidecar.metadata = merge.fields.applied(to: sidecar.metadata, fields: Set(merge.takenIn))
            sidecar.modified = context.now
            return .save(sidecar)
        }

        /// Notes what became of the member's `.redlamp`.
        mutating func took(_ taker: Int, _ result: SidecarBatchResult?, store: SidecarStore) {
            let problem: String
            switch result?.outcome {
            case .saved?:
                let photo = sides[taker].photo
                sides[taker].editStamp = XMPGroup.editURL(store, photo).flatMap(XMPFileStamp.init(at:))
                sides[taker].saved = try? LocalFileSystem().attributes(of: store.locator.readURL(for: photo)).modified
                return
            case let .failed(error)?:
                problem = XMPGroup.describe(error)
            case .kept?, nil:
                problem = XMPSyncProblem.unreadableSidecar.description
            }
            sides[taker].failed = true
            sides[taker].problem = "its .redlamp couldn't take other apps' changes: \(problem)"
        }

        /// Writes the `.xmp`, once the `.redlamp` sidecars are written, when `context` writes it; the
        /// group's outcome.
        func finish(_ context: XMPSyncContext) -> XMPGroupOutcome {
            guard let file else { return unchanged ?? XMPGroupOutcome() }
            var plan = plan
            var written: XMPFileStamp?
            if let planned = plan.bytes, context.writes, !context.dryRun {
                do {
                    written = try XMPSidecarWriter.write(planned, to: file.url, replacing: file.bytes)
                } catch {
                    plan.problem = XMPGroup.describe(error)
                }
            }
            return group.outcome(sides, file: file, plan: plan, written: written, context: context)
        }
    }

    /// Merges the group's photos' other apps' fields with their `.redlamp` sidecars' and plans the
    /// `.xmp` they share, as `XMPMerge` and `XMPSidecarWriter` describe; nothing is written. The
    /// `.redlamp` sidecars are written next (`Pending.taking`), then the `.xmp` (`Pending.finish`).
    func prepare(_ context: XMPSyncContext) -> Pending {
        var sides = members.map { member in side(member, context) }
        let sharedStamp = shared.map(XMPFileStamp.init)
        if sides.allSatisfy({ isUnchanged($0, sharedStamp: sharedStamp, context: context) }) {
            var outcome = XMPGroupOutcome()
            for side in sides {
                guard let record = side.record, side.redlamp != nil else { continue }
                outcome.photos.append(photo(side, other: record.other, merged: record.redlampFields, unchanged: true))
            }
            return Pending(group: self, sides: [], file: nil, plan: Plan(), unchanged: outcome)
        }

        let sharedURL = url(sharedName)
        let bytes = shared.flatMap { _ in try? Data(contentsOf: sharedURL) }.map { [UInt8]($0) }
        let packet = bytes.flatMap { XMPPacket(bytes: $0) }
        let file = SharedFile(
            url: sharedURL, stamp: sharedStamp, bytes: bytes, packet: packet,
            source: packet.map { XMPSource(packet: $0, conventions: context.conventions) },
            captured: packet.flatMap { XMPCaptureTime($0) },
        )
        for index in sides.indices {
            let shared = file.source(for: sides[index].member.camera)
            merge(&sides[index], shared: shared, sharedStamp: sharedStamp, context: context)
        }
        return Pending(group: self, sides: sides, file: file, plan: plan(sides, file, context), unchanged: nil)
    }

    /// What the `.xmp` gets: each field from the first photo that decides it, the raw's first. A
    /// photo after the first never clears a field the `.xmp` holds, which may be the first's.
    private func plan(_ sides: [Side], _ file: SharedFile, _ context: XMPSyncContext) -> Plan {
        var plan = Plan()
        for (position, side) in sides.enumerated() {
            guard let merge = side.merge else { continue }
            let held = file.source(for: side.member.camera)?.fields
            for field in merge.decided where !plan.decided.contains(field) {
                let unit = (field == .rating || field == .flag ? [XMPField.rating, .flag] : [field])
                    .filter(context.fields.contains)
                if position > 0, unit.allSatisfy({ !merge.fields.holds($0) }),
                   unit.contains(where: { held?.holds($0) ?? false }) {
                    continue
                }
                for field in unit {
                    plan.wanted.take(field, from: merge.fields)
                    plan.decided.insert(field)
                    plan.deciders[position, default: []].insert(field)
                }
                if unit.contains(.captureTime) {
                    plan.camera = side.member.camera
                }
            }
        }
        let held = file.source(for: plan.camera)?.fields ?? XMPFields()
        plan.changing = plan.decided.filter { !plan.wanted.represented($0, in: held) }
        guard !plan.changing.isEmpty else { return plan }
        guard !file.isUnreadable else {
            plan.problem = "\(sharedName) isn't XMP Redlamp can read: left as it is"
            return plan
        }
        let changes = plan.wanted.changes(
            plan.decided, to: file.packet, conventions: context.conventions, now: context.now, camera: plan.camera,
        )
        guard !changes.isEmpty else { return plan }
        plan.bytes = plan.wanted.written(
            into: file.packet, changes, fields: plan.decided, conventions: context.conventions, camera: plan.camera,
        )
        if plan.bytes == nil {
            plan.problem = "\(sharedName) couldn't be written without changing what other apps wrote in it: left as it is"
        }
        return plan
    }

    /// Each photo's outcome, and the records and rows to keep once the sidecars are written.
    private func outcome(
        _ sides: [Side], file: SharedFile, plan: Plan, written: XMPFileStamp?, context: XMPSyncContext,
    ) -> XMPGroupOutcome {
        var outcome = XMPGroupOutcome()
        let wrote = plan.bytes != nil && context.writes && (context.dryRun || written != nil)
        let rewritten = wrote ? plan.bytes.flatMap { XMPPacket(bytes: $0) } : nil
        let source = rewritten.map { XMPSource(packet: $0, conventions: context.conventions) } ?? file.source
        let captured = rewritten.map { XMPCaptureTime($0) } ?? file.captured
        for (position, side) in sides.enumerated() {
            var side = side
            side.unwritten = wrote ? [] : plan.fields(of: position)
            if side.problem == nil, !plan.fields(of: position).isEmpty {
                side.problem = plan.problem
            }
            let final = source?.capturing(captured, camera: side.member.camera)
            var photo = photo(
                side, other: side.other, merged: side.merge?.fields ?? XMPSource.combining([final, side.darktable]),
                unchanged: false,
            )
            photo.written = wrote ? plan.fields(of: position) : []
            if side.member.darktable != nil || shared != nil || side.redlamp != nil || side.problem != nil {
                outcome.photos.append(photo)
            }
            guard !context.dryRun, let id = side.id else { continue }
            guard let merge = side.merge else {
                if side.record != nil, side.redlamp == nil, side.problem == nil {
                    outcome.dropped.append(id)
                }
                continue
            }
            guard !side.failed else { continue }
            if !merge.takenIn.isEmpty {
                outcome.organising.append((id, merge.fields))
            }
            if let saved = side.saved {
                outcome.sidecars.append((id, saved, merge.takenIn))
            }
            if merge.takenIn.contains(.keywords) {
                outcome.keywords.append((id, merge.fields.keywords ?? []))
            }
            if merge.takenIn.contains(.captureTime) {
                outcome.captures.append((id, merge.fields))
            }
            if let written {
                let darktable = side.member.darktable.map(XMPFileStamp.init)
                outcome.xmpModified.append((
                    id, max(written.modified, darktable?.modified ?? .distantPast),
                    XMPFileStamp.signature(shared: written, darktable: darktable),
                ))
            }
            let record = XMPMergeRecord(
                sidecar: written ?? file.stamp, darktable: side.member.darktable.map(XMPFileStamp.init),
                photo: XMPFileStamp(side.member.entry), redlamp: side.editStamp, embedded: side.embedded,
                other: XMPSource.combining([final, side.darktable, side.embedded]), redlampFields: merge.redlampFields,
                unwritten: side.unwritten,
            )
            if record != side.record {
                outcome.records[id] = record
            }
        }
        return outcome
    }

    /// A member's `.redlamp` and record, read where the locator finds them. A `.redlamp` the record says the
    /// last sync read, and that's gone, holds nothing: the `.xmp` loses what it had from it.
    private func side(_ member: Member, _ context: XMPSyncContext) -> Side {
        let photo = url(member.name)
        var side = Side(member: member, photo: photo)
        side.record = member.record.flatMap { context.records[$0.id] }
        let onThisMac = context.locator.onThisMac(photo)
        let sidecar = context.locator.readURL(for: photo)
        var isDirectory: ObjCBool = false
        guard member.besideSidecar || onThisMac.map({ FileManager.default.fileExists(atPath: $0.path) }) == true,
              FileManager.default.fileExists(atPath: sidecar.path, isDirectory: &isDirectory)
        else {
            if side.record?.redlamp != nil {
                side.redlamp = XMPFields()
                side.removed = true
            }
            return side
        }
        let edit = isDirectory.boolValue ? sidecar.appending(path: SidecarStore.editFile) : sidecar
        side.editStamp = XMPFileStamp(at: edit)
        if let record = side.record, XMPFileStamp.same(record.redlamp, side.editStamp) {
            side.redlamp = record.redlampFields
            return side
        }
        guard let metadata = Self.metadata(atEdit: edit) else {
            side.problem = "its .redlamp can't be read by this Redlamp: left as it is"
            return side
        }
        side.redlamp = XMPFields(metadata)
        return side
    }

    /// The metadata of the `.redlamp` whose edit is at `edit`, all a merge reads of it (`.some(nil)`
    /// for none); nil when the edit can't be read. A sidecar this build can't save over is found
    /// when its merge is written, and left as it is.
    private static func metadata(atEdit edit: URL) -> PhotoMetadata?? {
        struct Probe: Decodable {
            var metadata: PhotoMetadata?
        }
        guard let data = try? Data(contentsOf: edit), let probe = try? JSONDecoder().decode(Probe.self, from: data)
        else { return nil }
        return .some(probe.metadata)
    }

    /// Whether nothing the member's merge reads has changed since its record, and its record owes the
    /// `.xmp` nothing; a member with neither a `.redlamp` nor an `.xmp` has nothing to merge.
    private func isUnchanged(_ side: Side, sharedStamp: XMPFileStamp?, context: XMPSyncContext) -> Bool {
        guard side.redlamp != nil else {
            return side.problem == nil && shared == nil && side.member.darktable == nil && side.record == nil
        }
        guard let record = side.record else { return false }
        return XMPFileStamp.same(record.sidecar, sharedStamp)
            && XMPFileStamp.same(record.darktable, side.member.darktable.map(XMPFileStamp.init))
            && XMPFileStamp.same(record.photo, XMPFileStamp(side.member.entry))
            && XMPFileStamp.same(record.redlamp, side.editStamp)
            && (!context.writes || record.unwritten.isEmpty)
    }

    /// Reads the member's other apps' fields and merges them with its `.redlamp`'s; its capture time
    /// only when the index has the camera's.
    private func merge(_ side: inout Side, shared: XMPSource?, sharedStamp: XMPFileStamp?, context: XMPSyncContext) {
        let member = side.member
        side.darktable = member.darktable.flatMap { try? Data(contentsOf: url($0.name)) }.flatMap { XMPPacket($0) }
            .map { packet in
                XMPSource(packet: packet, conventions: context.conventions)
                    .capturing(XMPCaptureTime(packet), camera: member.camera)
            }
        guard let redlamp = side.redlamp else {
            side.other = XMPSource.combining([shared, side.darktable])
            return
        }
        let photoStamp = XMPFileStamp(member.entry)
        if let record = side.record, XMPFileStamp.same(record.photo, photoStamp) {
            side.embedded = record.embedded
        } else {
            side.embedded = XMPSource.embedded(in: side.photo, conventions: context.conventions)
        }
        side.other = XMPSource.combining([shared, side.darktable, side.embedded])
        let otherIsLater = XMPMerge.otherIsLater(
            side.record, sidecar: sharedStamp, darktable: member.darktable.map(XMPFileStamp.init), photo: photoStamp,
            redlampSaved: side.editStamp?.modified,
        )
        side.merge = XMPMerge.merge(
            redlamp: redlamp, other: side.other, record: side.record,
            fields: member.camera == nil ? context.fields.subtracting([.captureTime]) : context.fields,
            otherIsLater: otherIsLater, filling: context.fills,
        )
        if side.removed, let taken = side.merge?.taken {
            side.merge?.theirs = taken
        }
    }

    private func photo(_ side: Side, other: XMPFields, merged: XMPFields, unchanged: Bool) -> XMPPhotoSync {
        XMPPhotoSync(
            photo: side.id, path: side.photo.path, sidecar: shared != nil ? url(sharedName).path : nil,
            sharedWith: members.map(\.name).filter { $0 != side.member.name },
            darktable: side.member.darktable.map { url($0.name).path }, other: other,
            redlamp: side.removed ? nil : side.redlamp,
            merged: merged, taken: side.merge?.takenIn ?? [], kept: side.merge?.kept ?? [], unwritten: side.unwritten,
            unchanged: unchanged, problem: side.problem,
        )
    }

    fileprivate static func editURL(_ store: SidecarStore, _ photo: URL) -> URL? {
        let sidecar = store.locator.readURL(for: photo)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sidecar.path, isDirectory: &isDirectory) else { return nil }
        return isDirectory.boolValue ? sidecar.appending(path: SidecarStore.editFile) : sidecar
    }

    fileprivate static func describe(_ error: any Error) -> String {
        switch error {
        case let error as XMPSidecarWriter.Failure: error.description
        case let error as XMPSyncProblem: error.description
        case let error as SidecarStoreError:
            switch error {
            case .writtenByNewerVersion: "a newer Redlamp wrote it"
            case .damaged: "its edit is damaged"
            case .unreadable: "its edit can't be read"
            case .lossy: "saving it would lose what's in it"
            }
        default: error.localizedDescription
        }
    }
}

enum XMPSyncProblem: Error, CustomStringConvertible {
    case unreadableSidecar

    var description: String {
        switch self {
        case .unreadableSidecar: "it can't be read"
        }
    }
}
