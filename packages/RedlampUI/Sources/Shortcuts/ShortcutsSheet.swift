import SwiftUI

/// Lightroom's ⌘/ shortcut overlay: every shortcut, grouped, generated from the registry.
struct ShortcutsSheet: View {
    @Environment(EditorModel.self) private var model

    private let columns = [
        GridItem(.flexible(), alignment: .top),
        GridItem(.flexible(), alignment: .top),
        GridItem(.flexible(), alignment: .top),
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { model.showShortcuts = false }

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Keyboard Shortcuts")
                        .font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Text("Dimmed shortcuts belong to tools that arrive in later phases.")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.secondaryLabel)
                    Button {
                        model.showShortcuts = false
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.secondaryLabel)
                    .help("Close (Esc)")
                }

                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                        ForEach(ShortcutAction.byCategory, id: \.0) { category, actions in
                            ShortcutGroup(title: category.rawValue, actions: actions)
                        }
                        ToolGesturesGroup()
                        PaletteKeysGroup()
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1080, maxHeight: 720)
            .background(RoundedRectangle(cornerRadius: 18).fill(Color(white: 0.1)))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.white.opacity(0.08)))
            .shadow(color: .black.opacity(0.5), radius: 30)
            .padding(40)
        }
        .transition(.opacity)
    }
}

/// Zooming, panning and sizing brushes in the tools that draw over the photo (UX-15).
private struct ToolGesturesGroup: View {
    private static let hints: [PaletteHint] = [
        PaletteHint("Zoom around the pointer, in any tool", ["Scroll"]),
        PaletteHint("Move the photo while a tool is active", ["Space", "Drag"]),
        PaletteHint("Brush size, in any brush tool", ["[", "]"]),
        PaletteHint("Brush feather", ["⇧", "[", "]"]),
        PaletteHint("Brush size from the pointer", ["⌘", "Scroll"]),
        PaletteHint("Brush feather from the pointer", ["⌘", "⇧", "Scroll"]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("ZOOM AND BRUSHES")
                .font(Theme.sectionFont)
                .tracking(0.6)
                .foregroundStyle(Theme.secondaryLabel)
                .padding(.bottom, 2)
            ForEach(Self.hints, id: \.self) { hint in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(hint.title)
                        .font(Theme.labelFont)
                        .foregroundStyle(Theme.value)
                    Spacer(minLength: 8)
                    KeyCaps(hint.keys)
                }
            }
        }
        .padding(.trailing, 12)
    }
}

/// The command palette's own keys, from the definitions its hint bar shows.
private struct PaletteKeysGroup: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("COMMAND PALETTE")
                .font(Theme.sectionFont)
                .tracking(0.6)
                .foregroundStyle(Theme.secondaryLabel)
                .padding(.bottom, 2)
            ForEach(PaletteKeyReference.keys, id: \.self) { hint in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(hint.title)
                        .font(Theme.labelFont)
                        .foregroundStyle(Theme.value)
                    Spacer(minLength: 8)
                    KeyCaps(hint.keys)
                }
            }
        }
        .padding(.trailing, 12)
    }
}

private struct ShortcutGroup: View {
    let title: String
    let actions: [ShortcutAction]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(Theme.sectionFont)
                .tracking(0.6)
                .foregroundStyle(Theme.secondaryLabel)
                .padding(.bottom, 2)
            ForEach(actions) { action in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(action.title)
                        .font(Theme.labelFont)
                        .foregroundStyle(action.isAvailable ? Theme.value : Theme.tertiaryLabel)
                    if let phase = action.plannedPhase {
                        Text(phase)
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(Theme.tertiaryLabel)
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 6) {
                        ForEach(action.combos, id: \.self) { combo in
                            KeyCaps(combo.keys, dimmed: !action.isAvailable)
                        }
                    }
                }
            }
        }
        .padding(.trailing, 12)
    }
}
