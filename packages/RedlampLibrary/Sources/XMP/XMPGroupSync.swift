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
    /// Photos with a `.redlamp` whose `.xmp` Redlamp wrote, with the `.xmp`'s modification date.
    var xmpModified: [(id: Int64, modified: Date)] = []
}

extension XMPGroup {
    /// One member's side of the sync.
    private struct Side {
        let member: Member
        let photo: URL
        /// Its `.redlamp`'s edit, where the locator reads it.
        var editStamp: XMPFileStamp?
        /// The `.redlamp`'s fields; nil when it has none, or it can't be read.
        var redlamp: XMPFields?
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
    private struct SharedFile {
        let url: URL
        let stamp: XMPFileStamp?
        let bytes: [UInt8]?
        let packet: XMPPacket?
        let source: XMPSource?

        /// Listed, but not XMP Redlamp can read: it's never written over.
        var isUnreadable: Bool {
            stamp != nil && packet == nil
        }
    }

    /// What the shared `.xmp` gets.
    private struct Plan {
        var wanted = XMPFields()
        var decided = Set<XMPField>()
        /// The fields each member decides, by its position.
        var deciders: [Int: Set<XMPField>] = [:]
        /// The fields decided that the `.xmp` doesn't hold.
        var changing = Set<XMPField>()
        /// The `.xmp` with them, once checked.
        var bytes: [UInt8]?
        var problem: String?

        func fields(of position: Int) -> [XMPField] {
            (deciders[position] ?? []).intersection(changing).sorted()
        }
    }

    /// Merges the group's photos' other apps' fields into their `.redlamp` sidecars and, when
    /// `context` writes them, their fields into the `.xmp` they share; as `XMPMerge` and
    /// `XMPSidecarWriter` describe.
    func sync(_ context: XMPSyncContext) -> XMPGroupOutcome {
        var sides = members.map { member in side(member, context) }
        let sharedStamp = shared.map(XMPFileStamp.init)
        if sides.allSatisfy({ isUnchanged($0, sharedStamp: sharedStamp, context: context) }) {
            var outcome = XMPGroupOutcome()
            for side in sides {
                guard let record = side.record, side.redlamp != nil else { continue }
                outcome.photos.append(photo(side, other: record.other, merged: record.redlampFields, unchanged: true))
            }
            return outcome
        }

        let sharedURL = url(sharedName)
        let bytes = shared.flatMap { _ in try? Data(contentsOf: sharedURL) }.map { [UInt8]($0) }
        let packet = bytes.flatMap { XMPPacket(bytes: $0) }
        let file = SharedFile(
            url: sharedURL, stamp: sharedStamp, bytes: bytes, packet: packet,
            source: packet.map { XMPSource(packet: $0, conventions: context.conventions) },
        )
        for index in sides.indices {
            merge(&sides[index], shared: file.source, sharedStamp: sharedStamp, context: context)
        }
        var plan = plan(sides, file, context)

        // The `.redlamp` sidecars first, then the `.xmp`.
        if !context.dryRun {
            let store = SidecarStore(locator: context.locator)
            for index in sides.indices {
                take(&sides[index], store: store, context: context)
            }
        }
        var written: XMPFileStamp?
        if let planned = plan.bytes, context.writes, !context.dryRun {
            do {
                written = try XMPSidecarWriter.write(planned, to: file.url, replacing: file.bytes)
            } catch {
                plan.problem = Self.describe(error)
            }
        }
        return outcome(sides, file: file, plan: plan, written: written, context: context)
    }

    /// What the `.xmp` gets: each field from the first photo that decides it, the raw's first. A
    /// photo after the first never clears a field the `.xmp` holds, which may be the first's.
    private func plan(_ sides: [Side], _ file: SharedFile, _ context: XMPSyncContext) -> Plan {
        var plan = Plan()
        for (position, side) in sides.enumerated() {
            guard let merge = side.merge else { continue }
            for field in merge.decided where !plan.decided.contains(field) {
                let unit = (field == .rating || field == .flag ? [XMPField.rating, .flag] : [field])
                    .filter(context.fields.contains)
                if position > 0, unit.allSatisfy({ !merge.fields.holds($0) }),
                   unit.contains(where: { file.source?.fields.holds($0) ?? false }) {
                    continue
                }
                for field in unit {
                    plan.wanted.take(field, from: merge.fields)
                    plan.decided.insert(field)
                    plan.deciders[position, default: []].insert(field)
                }
            }
        }
        let held = file.source?.fields ?? XMPFields()
        plan.changing = plan.decided.filter { !plan.wanted.represented($0, in: held) }
        guard !plan.changing.isEmpty else { return plan }
        guard !file.isUnreadable else {
            plan.problem = "\(sharedName) isn't XMP Redlamp can read: left as it is"
            return plan
        }
        let changes = plan.wanted.changes(
            plan.decided, to: file.packet, conventions: context.conventions, now: context.now,
        )
        guard !changes.isEmpty else { return plan }
        plan.bytes = plan.wanted.written(
            into: file.packet, changes, fields: plan.decided, conventions: context.conventions,
        )
        if plan.bytes == nil {
            plan.problem = "\(sharedName) couldn't be written without changing what other apps wrote in it: left as it is"
        }
        return plan
    }

    /// Writes what the member's `.redlamp` took from other apps, keeping everything else in it.
    private func take(_ side: inout Side, store: SidecarStore, context: XMPSyncContext) {
        guard let merge = side.merge, !merge.taken.isEmpty else { return }
        do {
            guard var sidecar = store.load(for: side.photo) else { throw XMPSyncProblem.unreadableSidecar }
            sidecar.metadata = merge.fields.applied(to: sidecar.metadata, fields: Set(merge.taken))
            sidecar.modified = context.now
            try store.save(sidecar, for: side.photo)
            side.editStamp = Self.editURL(store, side.photo).flatMap(XMPFileStamp.init(at:))
        } catch {
            side.failed = true
            side.problem = "its .redlamp couldn't take other apps' changes: \(Self.describe(error))"
        }
    }

    /// Each photo's outcome, and the records and rows to keep once the sidecars are written.
    private func outcome(
        _ sides: [Side], file: SharedFile, plan: Plan, written: XMPFileStamp?, context: XMPSyncContext,
    ) -> XMPGroupOutcome {
        var outcome = XMPGroupOutcome()
        let wrote = plan.bytes != nil && context.writes && (context.dryRun || written != nil)
        let final = wrote ? plan.bytes.flatMap { XMPPacket(bytes: $0) }.map {
            XMPSource(packet: $0, conventions: context.conventions)
        } : file.source
        for (position, side) in sides.enumerated() {
            var side = side
            side.unwritten = wrote ? [] : plan.fields(of: position)
            if side.problem == nil, !plan.fields(of: position).isEmpty {
                side.problem = plan.problem
            }
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
            if !merge.taken.isEmpty {
                outcome.organising.append((id, merge.fields))
            }
            if let written {
                outcome.xmpModified.append((id, written.modified))
            }
            let record = XMPMergeRecord(
                sidecar: written ?? file.stamp, darktable: side.member.darktable.map(XMPFileStamp.init),
                photo: XMPFileStamp(side.member.entry), redlamp: side.editStamp, embedded: side.embedded,
                other: XMPSource.combining([final, side.darktable, side.embedded]), redlampFields: merge.fields,
                unwritten: side.unwritten,
            )
            if record != side.record {
                outcome.records[id] = record
            }
        }
        return outcome
    }

    /// A member's `.redlamp` and record, read where the locator finds them.
    private func side(_ member: Member, _ context: XMPSyncContext) -> Side {
        let photo = url(member.name)
        var side = Side(member: member, photo: photo)
        side.record = member.record.flatMap { context.records[$0.id] }
        let onThisMac = context.locator.onThisMac(photo)
        guard member.besideSidecar || onThisMac.map({ FileManager.default.fileExists(atPath: $0.path) }) == true
        else { return side }
        let sidecar = context.locator.readURL(for: photo)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sidecar.path, isDirectory: &isDirectory) else { return side }
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

    /// Reads the member's other apps' fields and merges them with its `.redlamp`'s.
    private func merge(_ side: inout Side, shared: XMPSource?, sharedStamp: XMPFileStamp?, context: XMPSyncContext) {
        let member = side.member
        side.darktable = member.darktable.flatMap { try? Data(contentsOf: url($0.name)) }
            .flatMap { XMPSource(xmp: $0, conventions: context.conventions) }
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
        let record = side.record
        let darktableStamp = member.darktable.map(XMPFileStamp.init)
        let changed = [
            (record?.sidecar, sharedStamp), (record?.darktable, darktableStamp), (record?.photo, photoStamp),
        ].compactMap { recorded, now -> Date? in
            guard let now, record == nil || !XMPFileStamp.same(recorded, now) else { return nil }
            return now.modified
        }
        let otherIsLater = changed.max().map { $0 > side.editStamp?.modified ?? .distantPast } ?? false
        side.merge = XMPMerge.merge(
            redlamp: redlamp, other: side.other, record: record, fields: context.fields, otherIsLater: otherIsLater,
        )
    }

    private func photo(_ side: Side, other: XMPFields, merged: XMPFields, unchanged: Bool) -> XMPPhotoSync {
        XMPPhotoSync(
            photo: side.id, path: side.photo.path, sidecar: shared != nil ? url(sharedName).path : nil,
            sharedWith: members.map(\.name).filter { $0 != side.member.name },
            darktable: side.member.darktable.map { url($0.name).path }, other: other, redlamp: side.redlamp,
            merged: merged, taken: side.merge?.taken ?? [], kept: side.merge?.kept ?? [], unwritten: side.unwritten,
            unchanged: unchanged, problem: side.problem,
        )
    }

    private static func editURL(_ store: SidecarStore, _ photo: URL) -> URL? {
        let sidecar = store.locator.readURL(for: photo)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sidecar.path, isDirectory: &isDirectory) else { return nil }
        return isDirectory.boolValue ? sidecar.appending(path: SidecarStore.editFile) : sidecar
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case let error as XMPSidecarWriter.Failure: error.description
        case let error as XMPSyncProblem: error.description
        case let error as SidecarStoreError:
            switch error {
            case .writtenByNewerVersion: "a newer Redlamp wrote it"
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
