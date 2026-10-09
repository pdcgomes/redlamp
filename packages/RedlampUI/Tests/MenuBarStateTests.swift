import Foundation
import Observation
import Synchronization
import Testing
@testable import RedlampUI

/// What the menu bar shows (LIB-14): every item's enabled state and checkmark as `canPerform` and the model have
/// them, a turn after they change, and no change at all, so no rebuild of the menus, when nothing an item shows does.
@MainActor
struct MenuBarStateTests {
    /// Asks about every action, as the menus' body does.
    private func askAll(_ menu: MenuBarState) {
        for action in ShortcutAction.allCases {
            _ = menu.isEnabled(action)
            _ = menu.isChecked(action)
        }
    }

    private func disagreements(_ menu: MenuBarState, _ model: EditorModel) -> [ShortcutAction] {
        ShortcutAction.allCases.filter { action in
            menu.isEnabled(action) != (action.isAvailable && model.canPerform(action))
                || menu.isChecked(action) != (MenuBarState.isOn(action, in: model) == true)
        }
    }

    /// Counts the changes to what the menus read, as SwiftUI's observation of their body does.
    private final class Changes: Sendable {
        private let count = Mutex(0)
        var value: Int {
            count.withLock { $0 }
        }

        @MainActor func watch(_ menu: MenuBarState) {
            withObservationTracking { _ = menu.shown } onChange: { [self] in
                count.withLock { $0 += 1 }
                Task { @MainActor in self.watch(menu) }
            }
        }
    }

    @Test func `every item's enabled state and checkmark follow the model through moves, a module switch and a group`()
        async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        try await fixture.open(count: 5)
        let model = fixture.model
        let menu = MenuBarState(model: model)
        askAll(menu)
        try await fixture.settle()
        #expect(disagreements(menu, model) == [])

        model.perform(.nextPhoto)
        try await fixture.eventually { disagreements(menu, model).isEmpty }
        #expect(disagreements(menu, model) == [])

        model.showModule(.library)
        try await fixture.eventually { disagreements(menu, model).isEmpty }
        #expect(menu.shown.module == .library)
        #expect(disagreements(menu, model) == [])

        let group = try #require(ShortcutAction.allCases.first { $0.groupKey != nil && !menu.isChecked($0) })
        model.perform(group)
        try await fixture.eventually { menu.isChecked(group) }
        #expect(disagreements(menu, model) == [])
    }

    @Test func `moving between photos in the middle of a folder leaves what the menus show alone`() async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        try await fixture.open(count: 6)
        let model = fixture.model
        model.showModule(.library)
        model.perform(.nextPhoto)
        let menu = MenuBarState(model: model)
        askAll(menu)
        try await fixture.settle()
        let changes = Changes()
        changes.watch(menu)

        for _ in 0 ..< 3 {
            model.perform(.nextPhoto)
            try await fixture.settle()
        }
        #expect(model.selection == fixture.photos[4])
        #expect(changes.value == 0)
        #expect(disagreements(menu, model) == [])
    }

    @Test func `a dialog holds the items once, and its end gives them back once`() async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        try await fixture.open(count: 3)
        let model = fixture.model
        let menu = MenuBarState(model: model)
        askAll(menu)
        try await fixture.settle()
        let enabled = ShortcutAction.allCases.filter(menu.isEnabled)
        let changes = Changes()
        changes.watch(menu)

        model.isModalDialogOpen = true
        try await fixture.eventually { menu.shown.isModalDialogOpen }
        try await fixture.settle()
        #expect(changes.value == 1)
        #expect(disagreements(menu, model) == [])
        #expect(ShortcutAction.allCases.filter(menu.isEnabled).count < enabled.count)

        model.isModalDialogOpen = false
        try await fixture.eventually { !menu.shown.isModalDialogOpen }
        try await fixture.settle()
        #expect(changes.value == 2)
        #expect(ShortcutAction.allCases.filter(menu.isEnabled) == enabled)
    }
}
