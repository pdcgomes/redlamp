import CoreFoundation
import Foundation
import Observation
import RedlampLibrary

/// What the menu bar shows (`AppCommands`): each item's enabled state as `canPerform` has it, the checkmarks, and the
/// titles and lists that follow the editor. SwiftUI makes its whole main menu again, about 3 ms on the main thread,
/// whenever anything the menus read changes, as a held arrow key's selection did twice a press. The menus read only
/// this, which runs their checks again once in the turn after anything those read changes, and changes only when
/// what an item shows does.
@MainActor @Observable public final class MenuBarState {
    public struct Shown: Equatable {
        var enabled: Set<ShortcutAction> = []
        var checked: Set<ShortcutAction> = []
        public internal(set) var module = AppModule.develop
        public internal(set) var isModalDialogOpen = false
        public internal(set) var hasSelection = false
        public internal(set) var hasFilters = false
        public internal(set) var customLabels: [String] = []
        public internal(set) var keywordSets: [KeywordSet] = []
        public internal(set) var activeKeywordSet = ""
        /// The active keyword set's keywords, ⌥1 to ⌥9.
        public internal(set) var keywords = [String?](repeating: nil, count: KeywordSet.size)
        public internal(set) var cellStyle = GridCellStyle.compact
        public internal(set) var compareLayout = CompareLayout.toggle
        public internal(set) var filterPresets: [FilterPreset] = []
        public internal(set) var filterPreset: FilterPreset?
        public internal(set) var filmstripHidesAutomatically = false
    }

    public private(set) var shown = Shown()
    @ObservationIgnored private weak var model: EditorModel?
    /// The actions the menus have asked about. Until they have, every action's check runs.
    @ObservationIgnored private var asked: Set<ShortcutAction> = []
    /// The actions whose checks the last refresh ran; nil for every action.
    @ObservationIgnored private var refreshed: Set<ShortcutAction>?
    @ObservationIgnored private var refreshQueued = false

    public init(model: EditorModel) {
        self.model = model
        refresh()
    }

    /// Whether `action`'s item is enabled.
    public func isEnabled(_ action: ShortcutAction) -> Bool {
        guard ask(action) else { return action.isAvailable && model?.canPerform(action) == true }
        return shown.enabled.contains(action)
    }

    /// Whether `action`'s item has its checkmark.
    public func isChecked(_ action: ShortcutAction) -> Bool {
        guard ask(action) else { return model.flatMap { Self.isOn(action, in: $0) } == true }
        return shown.checked.contains(action)
    }

    /// Notes that the menus show `action`; false while the checks haven't run for it. An action asked about for the
    /// first time after the checks were narrowed to those asked before is answered from the model until they run
    /// again with it, in the next turn.
    private func ask(_ action: ShortcutAction) -> Bool {
        if asked.insert(action).inserted, let refreshed, !refreshed.contains(action), !refreshQueued {
            refreshQueued = true
            Self.onMainRunLoop { [weak self] in self?.refresh() }
        }
        return refreshed?.contains(action) ?? true
    }

    private func refresh() {
        guard let model else { return }
        refreshQueued = false
        #if DEBUG || REDLAMP_PROFILING
            let started = CFAbsoluteTimeGetCurrent()
            defer { MenuBarProbe.shared.refreshed(since: started) }
        #endif
        let actions = asked.isEmpty ? Set(ShortcutAction.allCases) : asked
        let next = withObservationTracking {
            Self.shown(by: model, for: actions)
        } onChange: { [weak self] in
            Self.onMainRunLoop { self?.refresh() }
        }
        refreshed = asked.isEmpty ? nil : asked
        guard next != shown else { return }
        let moduleChanged = next.module != shown.module
        shown = next
        if moduleChanged {
            Self.afterMenusUpdate { ModuleMenuKeys.refresh() }
        }
    }

    static func shown(by model: EditorModel, for actions: Set<ShortcutAction>) -> Shown {
        var shown = Shown()
        for action in actions {
            if action.isAvailable, model.canPerform(action) {
                shown.enabled.insert(action)
            }
            if isOn(action, in: model) == true {
                shown.checked.insert(action)
            }
        }
        shown.module = model.module
        shown.isModalDialogOpen = model.isModalDialogOpen
        shown.hasSelection = model.selection != nil
        let filters = model.libraryFilters
        shown.hasFilters = filters != nil
        shown.customLabels = model.customLabels
        let panels = model.libraryPanels
        shown.keywordSets = panels.keywordSets
        let active = panels.activeSet
        shown.activeKeywordSet = active?.name ?? ""
        shown.keywords = (1 ... KeywordSet.size).map { active?.keyword(forShortcut: $0)?.name }
        shown.cellStyle = model.libraryViews.cellStyle
        shown.compareLayout = model.compareLayout
        shown.filterPresets = filters?.presets ?? []
        shown.filterPreset = filters?.preset
        shown.filmstripHidesAutomatically = model.filmstripHidesAutomatically
        return shown
    }

    /// Whether `action`'s item has its checkmark; nil for an item that has none.
    static func isOn(_ action: ShortcutAction, in model: EditorModel) -> Bool? {
        if let key = action.groupKey {
            return model.libraryViews.groupKey == key
        }
        if let field = action.sortField {
            return model.libraryFilters?.sort.field == field
        }
        switch action {
        case .keywordPainter: return model.keywordPainter.isOn
        case .unpickedMoments: return model.showsUnpickedMoments
        case .toggleFilters: return model.libraryFilters?.filter.isEnabled == true
        case .lockFilters: return model.libraryFilters?.isLocked == true
        case .showPhotosInSubfolders: return model.library.includesSubfolders
        case .toggleAutoSync: return model.settingsSync.isAutoSyncing
        case .autoAdvance: return model.autoAdvance
        default: return nil
        }
    }

    /// Runs `body` on the main run loop in any of its common modes, so a sheet's or a menu's run loop doesn't hold it:
    /// a modal session started from a main-actor task holds the main queue.
    private nonisolated static func onMainRunLoop(_ body: @escaping @MainActor () -> Void) {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated(body)
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    /// Runs `body` once this turn of the main run loop is over, after SwiftUI's update of the menus in it.
    private static func afterMenusUpdate(_ body: @escaping @MainActor () -> Void) {
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue, false, CFIndex.max,
        ) { _, _ in
            MainActor.assumeIsolated(body)
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
}
