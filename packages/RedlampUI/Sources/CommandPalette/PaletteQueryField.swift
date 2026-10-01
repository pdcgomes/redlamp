import AppKit
import RedlampDesign
import SwiftUI

/// The palette's text field. An AppKit field, so its delegate sees the arrow, Return, Esc
/// and Delete keys (as `moveUp:`, `insertNewline:`, `cancelOperation:`…) before they edit
/// the text, and the palette decides what each does.
struct PaletteQueryField: NSViewRepresentable {
    let text: String
    let placeholder: String
    var font: NSFont = .systemFont(ofSize: 16)
    var alignment: NSTextAlignment = .natural
    let textColor: NSColor
    let placeholderColor: NSColor
    /// The palette's appearance, which its own theme can set apart from the window's.
    let colorScheme: ColorScheme
    /// Changes when the palette sets the text itself, to reset the selection.
    let revision: Int
    let selectsAll: Bool
    /// Takes keyboard focus when it appears (harness specimens don't).
    var focuses = true
    let onChange: (String) -> Void
    let onKey: (PaletteKey) -> Bool

    func makeNSView(context: Context) -> PaletteTextField {
        let field = PaletteTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byClipping
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.takesFocus = focuses
        field.isEditable = focuses
        field.isSelectable = focuses
        field.selectsAllOnFocus = selectsAll
        context.coordinator.revision = revision
        configure(field)
        return field
    }

    func updateNSView(_ field: PaletteTextField, context: Context) {
        context.coordinator.parent = self
        configure(field)
        if context.coordinator.revision != revision {
            context.coordinator.revision = revision
            field.select(all: selectsAll)
        }
    }

    private func configure(_ field: PaletteTextField) {
        field.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        field.font = font
        field.alignment = alignment
        field.textColor = textColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: font, .foregroundColor: placeholderColor, .paragraphStyle: paragraph,
        ])
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PaletteQueryField
        var revision = 0

        init(parent: PaletteQueryField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.onChange(field.stringValue)
        }

        func control(_: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            var modifiers: PaletteModifiers = []
            if flags.contains(.shift) {
                modifiers.insert(.shift)
            }
            if flags.contains(.option) {
                modifiers.insert(.option)
            }
            switch selector {
            case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveUpAndModifySelection(_:)):
                return parent.onKey(.up)
            case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveDownAndModifySelection(_:)):
                return parent.onKey(.down)
            case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveLeftAndModifySelection(_:)),
                 #selector(NSResponder.moveWordLeft(_:)), #selector(NSResponder.moveWordLeftAndModifySelection(_:)):
                return parent.onKey(.left(modifiers))
            case #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveRightAndModifySelection(_:)),
                 #selector(NSResponder.moveWordRight(_:)), #selector(NSResponder.moveWordRightAndModifySelection(_:)):
                return parent.onKey(.right(modifiers))
            case #selector(NSResponder.insertNewline(_:)):
                return parent.onKey(.submit)
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onKey(.escape)
            case #selector(NSResponder.deleteBackward(_:)):
                return textView.string.isEmpty && parent.onKey(.deleteBackward)
            case #selector(NSResponder.deleteToBeginningOfLine(_:)):
                return parent.onKey(.reset)
            case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
                // Keep focus in the palette.
                return true
            default:
                return false
            }
        }
    }
}

/// Takes focus once it's in a window, then places the selection as the palette asks.
final class PaletteTextField: NSTextField {
    var takesFocus = true
    var selectsAllOnFocus = true

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard takesFocus, window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window, window.firstResponder !== currentEditor() else { return }
            window.makeFirstResponder(self)
            select(all: selectsAllOnFocus)
        }
    }

    /// Selects the whole text, or puts the insertion point at its end.
    func select(all: Bool) {
        guard let editor = currentEditor() else { return }
        if all {
            editor.selectAll(nil)
        } else {
            editor.selectedRange = NSRange(location: (stringValue as NSString).length, length: 0)
        }
    }
}
