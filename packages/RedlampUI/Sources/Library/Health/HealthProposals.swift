import Foundation
import Observation
import RedlampLibrary

/// The proposals of the Library Health check the grid shows (LIB-40): the check's findings as the library has them,
/// read again off the main thread each time the check's list changes, and each photo's mark, which the grid's cells
/// draw and their tooltips and VoiceOver say. Only a check's list has them. The menus follow only what's offered,
/// which a batch or Keep Anyway changes once, not the counts, which change with each part of a batch's photos: SwiftUI
/// asks every item of the menu bar again whenever something its menus read changes.
@MainActor
@Observable
public final class HealthProposals {
    /// What the menus follow: the check shown, and whether its batch has anything to act on.
    public struct Offer: Equatable, Sendable {
        public var check: HealthCheck.Kind
        /// Its batch acts on something proposed, or on photos listed apart once they're chosen.
        public var canAccept: Bool
        /// Its list has photos.
        public var hasFindings: Bool
    }

    /// The check's findings counted.
    public struct Tally: Equatable, Sendable {
        /// The findings its batch acts on as proposed.
        public var proposed: Int
        /// The findings listed apart, which the batch leaves out unless they're chosen.
        public var apart: Int
        /// The findings in its list.
        public var found: Int
    }

    /// The check shown and what it offers; nil while the grid shows anything else, and until its findings are read.
    public private(set) var offer: Offer?
    /// The check's findings counted, as last read.
    @ObservationIgnored public private(set) var tally: Tally?
    /// The check's findings as last read.
    @ObservationIgnored private(set) var findings: HealthFindings?
    /// Each photo's mark, by the index's ID.
    @ObservationIgnored private var marks: [Int64: HealthMark] = [:]
    @ObservationIgnored private weak var model: EditorModel?
    @ObservationIgnored private var shown: LibrarySource?
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var readAgain = false
    @ObservationIgnored private var observers: [UUID: @MainActor () -> Void] = [:]
    @ObservationIgnored private var health: (core: ObjectIdentifier, health: LibraryHealth)?
    /// Duplicates being read whole to confirm them, and how many were unconfirmed as the last reading started.
    @ObservationIgnored private var confirming: Task<Void, Never>?
    @ObservationIgnored private var confirmedFrom: Int?
    /// How long each reading of the findings took to reach the grid, for the budgets.
    @ObservationIgnored @_spi(Harness) public private(set) var readsTook: [Duration] = []

    init(model: EditorModel) {
        self.model = model
    }

    /// The source shown, or its list, changed: a check's findings are read again, and anything else has none.
    func follow(_ source: LibrarySource?) {
        guard case .health? = source else {
            clear()
            return
        }
        if source != shown {
            clear()
            shown = source
        }
        read()
    }

    /// The mark of the photo at `url`, while it's in the check shown.
    func mark(for url: URL) -> HealthMark? {
        guard !marks.isEmpty, let id = model?.librarySources.indexID(ofShown: url) else { return nil }
        return marks[id]
    }

    /// The marks of the photos the index knows as `ids`.
    func marks(of ids: [Int64]) -> [HealthMark] {
        ids.compactMap { marks[$0] }
    }

    /// The kinds of the pairs' halves the check proposes for the Trash, for the batch's words.
    var proposedKinds: Set<PhotoRecord.Kind> {
        Set(findings?.findings.lazy.filter(\.isProposed).compactMap { finding -> PhotoRecord.Kind? in
            guard case let .pairHalf(kind, _) = finding.reason else { return nil }
            return kind
        } ?? [])
    }

    /// Calls `handler` each time the marks change.
    func observe(_ handler: @escaping @MainActor () -> Void) -> LibraryObservation {
        let id = UUID()
        observers[id] = handler
        return LibraryObservation { [weak self] in self?.observers.removeValue(forKey: id) }
    }

    /// Reads whole, at utility priority, the duplicate candidates no recorded hash confirms, `unconfirmed` of them as
    /// the counts last found, so Exact Duplicates lists every group; the counts are read again after. One reading at a
    /// time, and none while the count is the one the last reading started from: candidates that can't be read, on a
    /// volume that's away say, stay unconfirmed until there are others.
    func confirmDuplicates(unconfirmed: Int) {
        guard confirming == nil, unconfirmed > 0, unconfirmed != confirmedFrom, let model,
              let core = model.library.service?.core
        else { return }
        confirmedFrom = unconfirmed
        let health = library(core)
        confirming = Task { [weak self] in
            try? await Task.detached(priority: .utility) { _ = try await health.confirmDuplicates() }.value
            guard let self else { return }
            confirming = nil
            self.model?.librarySources.recount()
        }
    }

    /// Returns once the duplicates being confirmed are, for the regression suite.
    @_spi(Harness) public func confirmed() async {
        await confirming?.value
    }

    /// Library Health for the library open now.
    func library(_ core: LibraryCore) -> LibraryHealth {
        if let health, health.core == ObjectIdentifier(core) {
            return health.health
        }
        let made = LibraryHealth(operations: core.files, engine: core.engine)
        health = (ObjectIdentifier(core), made)
        return made
    }

    /// The check of `kind` as the Library panel has it: pairs under its rule.
    static func check(_ kind: HealthCheck.Kind, pairs rule: PairRule) -> HealthCheck {
        switch kind {
        case .duplicates: .duplicates
        case .pairs: .pairs(rule)
        case .damaged: .damaged
        case .missing: .missing
        case .extensions: .extensions
        }
    }

    /// Whether the findings asked for so far are in.
    @_spi(Harness) public var isReading: Bool {
        reading
    }

    /// How many photos of the check shown have a mark.
    @_spi(Harness) public var marked: Int {
        marks.count
    }

    private func read() {
        guard let model, let core = model.library.service?.core, case let .health(kind)? = shown else { return }
        guard !reading else {
            readAgain = true
            return
        }
        reading = true
        let (health, check, source, started) = (
            library(core), Self.check(kind, pairs: model.librarySources.pairRule), shown, ContinuousClock.now,
        )
        Task { [weak self] in
            let read = await Task.detached(priority: .userInitiated) { () -> Read? in
                guard let found = try? await health.findings(check) else { return nil }
                var marks = [Int64: HealthMark](minimumCapacity: found.findings.count)
                var tally = Tally(proposed: 0, apart: 0, found: found.findings.count)
                for finding in found.findings {
                    marks[finding.photo] = HealthMark(finding)
                    tally.proposed += finding.isProposed ? 1 : 0
                    tally.apart += finding.apart == nil ? 0 : 1
                }
                return Read(findings: found, marks: marks, tally: tally)
            }.value
            guard let self else { return }
            reading = false
            if shown == source, let read {
                apply(read)
                readsTook = readsTook.suffix(99) + [.now - started]
            }
            if readAgain {
                readAgain = false
                self.read()
            }
        }
    }

    /// A check's findings as read, with each photo's mark and their count.
    private struct Read: Sendable {
        var findings: HealthFindings
        var marks: [Int64: HealthMark]
        var tally: Tally
    }

    private func apply(_ read: Read) {
        let replaced = (findings, marks)
        findings = read.findings
        marks = read.marks
        tally = read.tally
        // Tens of thousands of findings and marks take milliseconds to free.
        Task.detached(priority: .utility) { withExtendedLifetime(replaced) {} }
        let tally = read.tally
        let offer = Offer(
            check: read.findings.check.kind, canAccept: tally.proposed > 0 || tally.apart > 0,
            hasFindings: tally.found > 0,
        )
        if offer != self.offer {
            self.offer = offer
        }
        for observer in observers.values {
            observer()
        }
    }

    private func clear() {
        shown = nil
        readAgain = false
        findings = nil
        tally = nil
        if offer != nil {
            offer = nil
        }
        guard !marks.isEmpty else { return }
        let replaced = marks
        marks = [:]
        Task.detached(priority: .utility) { withExtendedLifetime(replaced) {} }
        for observer in observers.values {
            observer()
        }
    }
}

public extension EditorModel {
    /// The proposals of the Library Health check the grid shows.
    var healthProposals: HealthProposals {
        if let proposals = Self.healthProposals.object(forKey: self) {
            return proposals
        }
        let proposals = HealthProposals(model: self)
        Self.healthProposals.setObject(proposals, forKey: self)
        return proposals
    }

    private static let healthProposals = NSMapTable<EditorModel, HealthProposals>.weakToStrongObjects()
}
