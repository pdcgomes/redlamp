import SwiftUI

/// Settings › Shortcuts (LIB-36): every action in the command list behind the menus, the palette and the keys,
/// with its keys. A key is recorded by pressing it, and one that collides is shown with what it collides with
/// before anything is saved. Presets give the keys of Lightroom Classic, Photo Mechanic or Bridge.
struct ShortcutsSettings: View {
    @State private var editor = ShortcutEditor()
    @State private var presetToConfirm: KeymapPreset?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Keys from", selection: Binding(
                    get: { editor.keymap.preset },
                    set: { preset in
                        if editor.changeCount > 0 {
                            presetToConfirm = preset
                        } else {
                            editor.choose(preset)
                        }
                    },
                )) {
                    ForEach(KeymapPreset.allCases) { Text($0.title).tag($0) }
                }
                .fixedSize()
                .accessibilityIdentifier("shortcuts.preset")
                Spacer()
                if editor.changeCount > 0 {
                    Button("Undo \(editor.changeCount == 1 ? "1 Change" : "\(editor.changeCount) Changes")") {
                        presetToConfirm = editor.keymap.preset
                    }
                    .accessibilityIdentifier("shortcuts.reset-all")
                }
            }
            Text(editor.keymap.preset.summary)
                .formFooter()
            TextField("Search actions or keys", text: $editor.search)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("shortcuts.search")
            List {
                ForEach(editor.sections, id: \.0) { category, actions in
                    Section(category.rawValue) {
                        ForEach(actions) { ShortcutRow(editor: editor, action: $0) }
                    }
                }
            }
            .frame(height: 400)
            Text("""
            Click a key to record another in its place, and press the new one. Keys with ⌘ are the menus’; \
            the rest work wherever you aren’t typing. A key another action has is shown with it before \
            anything changes.
            """)
            .formFooter()
        }
        .padding(20)
        .confirmationDialog(
            presetToConfirm.map { "Use \($0.title)’s keys?" } ?? "",
            isPresented: Binding(get: { presetToConfirm != nil }, set: {
                if !$0 {
                    presetToConfirm = nil
                }
            }),
            presenting: presetToConfirm,
        ) { preset in
            Button("Use \(preset.title)’s Keys") { editor.choose(preset) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The keys you changed go back to the preset’s.")
        }
        .onAppear { ShortcutEditor.shown = editor }
        .onDisappear {
            editor.cancel()
            if ShortcutEditor.shown === editor {
                ShortcutEditor.shown = nil
            }
        }
    }
}

/// An action, its keys, and while one is recorded or collides, what's pressed and what it collides with.
private struct ShortcutRow: View {
    let editor: ShortcutEditor
    let action: ShortcutAction

    var body: some View {
        let keymap = editor.keymap
        let keys = keymap.combos(for: action)
        let isRecording = editor.recording?.action == action
        let pending = editor.pending.flatMap { $0.recording.action == action ? $0 : nil }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(action.title)
                    .foregroundStyle(action.isAvailable ? .primary : .tertiary)
                    .lineLimit(1)
                if keymap.isChanged(action) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                        .help("Changed from \(keymap.preset.title)’s keys")
                }
                if let phase = action.plannedPhase {
                    Text(phase).font(.caption).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                if isRecording {
                    RecordingField(editor: editor)
                } else {
                    Button { editor.record(action) } label: {
                        if keys.isEmpty {
                            Text("Add Key").foregroundStyle(.secondary)
                        } else {
                            HStack(spacing: 6) {
                                ForEach(keys, id: \.self) { KeyCaps($0.keys) }
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(!action.isAvailable)
                    .help("Record a key in place of \(keys.first?.display ?? "none")")
                    .accessibilityIdentifier("shortcuts.record.\(action.rawValue)")
                }
                Menu {
                    Button("Record a Key") { editor.record(action) }
                    Button("Add Another Key") { editor.record(action, adding: true) }
                        .disabled(keys.isEmpty)
                    if !keys.isEmpty {
                        Divider()
                        ForEach(keys, id: \.self) { combo in
                            Button("Remove \(combo.display)") { editor.remove(combo, from: action) }
                        }
                    }
                    if keymap.isChanged(action) {
                        Divider()
                        Button("Use \(keymap.preset.title)’s Keys") { editor.reset(action) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(!action.isAvailable)
                .accessibilityIdentifier("shortcuts.menu.\(action.rawValue)")
            }
            if let pending {
                ConflictView(editor: editor, pending: pending)
            }
        }
        .background(KeyRecorder(
            isRecording: isRecording,
            onKey: { editor.press($0) },
            onModifiers: { editor.heldModifiers = $0 },
            onEnd: {
                if editor.recording?.action == action {
                    editor.cancel()
                }
            },
        ))
    }
}

/// What a row shows while its key is recorded: the modifiers held so far, and Cancel.
private struct RecordingField: View {
    let editor: ShortcutEditor

    var body: some View {
        HStack(spacing: 6) {
            let held = KeyCombo.symbols(of: editor.heldModifiers)
            if held.isEmpty {
                Text("Type a key").foregroundStyle(.secondary)
            } else {
                KeyCaps(held, active: true)
            }
            Button("Cancel") { editor.cancel() }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("shortcuts.cancel-recording")
        }
        .accessibilityIdentifier("shortcuts.recording")
    }
}

/// A key that collides, before anything is saved: what has it, and Take It or Cancel.
private struct ConflictView: View {
    let editor: ShortcutEditor
    let pending: ShortcutEditor.Pending

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(pending.conflicts, id: \.self) { conflict in
                Label(ShortcutEditor.describe(conflict, combo: pending.combo), systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                if pending.isReserved {
                    Button("OK") { editor.cancel() }
                        .accessibilityIdentifier("shortcuts.cancel")
                } else {
                    Button("Cancel") { editor.cancel() }
                        .accessibilityIdentifier("shortcuts.cancel")
                    Button("Take \(pending.combo.display)") { editor.confirm() }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("shortcuts.take")
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
    }
}
