import SwiftUI
import AppKit

/// The app's one text input — a borderless field whose text never moves.
///
/// SwiftUI's `TextField` (and a plain `NSTextField`) jump a pixel or two when
/// focus comes and goes: unfocused, the cell draws the text; focused, AppKit's
/// shared field editor takes over and lays the same text out at a slightly
/// different spot — and the placeholder sits at yet another. This wraps an
/// `NSTextField` whose cell centres the text vertically for **both** drawing and
/// editing (`CenteredCell`), so text, placeholder and caret all stay put.
///
/// While it's focused it reports `TextInputFocusKey` up the tree, which is how the
/// player window knows to stand down its bare-key shortcuts (⌘A select-all tracks,
/// arrows, ↩, ⌘⌫) so they edit the text instead — for any field, nothing to wire.
struct SteadyTextField: View {
    let placeholder: String
    @Binding var text: String
    var font: NSFont = .systemFont(ofSize: 12)
    var placeholderColor: Color = .white.opacity(0.4)
    var textColor: Color = .white
    var onSubmit: () -> Void = {}
    /// Esc while editing. Nil leaves Esc to the window (which drops the focus).
    var onCancel: (() -> Void)? = nil
    /// Optional outside handle on the focus, for callers that move it
    /// programmatically; otherwise the field tracks its own.
    var focus: Binding<Bool>? = nil
    @State private var ownFocus = false

    private var isFocused: Binding<Bool> { focus ?? $ownFocus }

    var body: some View {
        CenteredTextField(text: $text, placeholder: placeholder, font: font,
                          textColor: NSColor(textColor), placeholderColor: NSColor(placeholderColor),
                          isFocused: isFocused, onSubmit: onSubmit, onCancel: onCancel)
            .preference(key: TextInputFocusKey.self, value: isFocused.wrappedValue)
    }
}

/// Whether any `SteadyTextField` below is focused (being typed in).
struct TextInputFocusKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

// MARK: - AppKit field

private struct CenteredTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let font: NSFont
    let textColor: NSColor
    let placeholderColor: NSColor
    @Binding var isFocused: Bool
    let onSubmit: () -> Void
    let onCancel: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> FocusTrackingTextField {
        let field = FocusTrackingTextField()
        field.cell = CenteredCell(textCell: "")
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.lineBreakMode = .byClipping
        field.delegate = context.coordinator
        let coordinator = context.coordinator
        field.onFocusChange = { [weak field] focused in
            // Caret in the text colour — the default is dark, invisible on our UI.
            if focused, let editor = field?.currentEditor() as? NSTextView {
                editor.insertionPointColor = coordinator.parent.textColor
            }
            // Out of the current update pass — this can fire while SwiftUI is
            // laying the field out (it moving into a window).
            DispatchQueue.main.async {
                if coordinator.parent.isFocused != focused { coordinator.parent.isFocused = focused }
            }
        }
        return field
    }

    /// Exactly the width offered, whatever the text. Left to its intrinsic size, an
    /// `NSTextField` changes width the moment it gains focus (the field editor's
    /// content replaces the placeholder), and SwiftUI re-centres it inside its
    /// frame — the text and caret slide sideways on every focus change.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: FocusTrackingTextField,
                      context: Context) -> CGSize? {
        let natural = field.cell?.cellSize ?? field.intrinsicContentSize
        return CGSize(width: proposal.width ?? max(natural.width, 40), height: natural.height)
    }

    func updateNSView(_ field: FocusTrackingTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if field.font != font { field.font = font }
        field.textColor = textColor
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder, attributes: [.font: font, .foregroundColor: placeholderColor])

        // Mirror the focus binding onto the first responder — after this update
        // pass, since making/resigning first responder re-enters SwiftUI.
        if isFocused != field.hasFocus {
            let wantFocus = isFocused
            DispatchQueue.main.async {
                guard let window = field.window, field.hasFocus != wantFocus else { return }
                window.makeFirstResponder(wantFocus ? field : nil)
            }
        }
    }

    /// A field removed mid-edit (search closed, rename finished) hands the keyboard
    /// back rather than leaving an orphaned field editor as first responder.
    static func dismantleNSView(_ field: FocusTrackingTextField, coordinator: Coordinator) {
        if field.hasFocus { field.window?.makeFirstResponder(nil) }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CenteredTextField
        init(_ parent: CenteredTextField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                guard let onCancel = parent.onCancel else { return false }
                onCancel()
                return true
            default:
                return false
            }
        }
    }
}

/// An `NSTextField` that knows when it has the keyboard — the caret is in it —
/// from the window's first responder, not from editing: AppKit only reports
/// "began editing" at the first typed character, so a click-then-⌘A would never
/// have counted as focused.
final class FocusTrackingTextField: NSTextField {
    var onFocusChange: ((Bool) -> Void)?
    private(set) var hasFocus = false
    private var observation: NSKeyValueObservation?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observation = window?.observe(\.firstResponder) { [weak self] _, _ in
            // Re-check once the hand-off settles: focusing the field first makes
            // the field itself first responder, then passes that to the field
            // editor — whose link back to the field isn't set yet at that instant.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateFocus() } }
        }
        updateFocus()
    }

    private func updateFocus() {
        // While editing, the first responder is the window's shared field editor,
        // whose delegate is the field being edited.
        let responder = window?.firstResponder
        let focused = responder === self
            || (currentEditor() != nil && responder === currentEditor())
        guard focused != hasFocus else { return }
        hasFocus = focused
        onFocusChange?(focused)
    }
}

/// A text cell that centres its one line vertically — and uses that same rect for
/// the field editor while editing, which is what keeps the text from jumping when
/// focus comes and goes.
private final class CenteredCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let base = super.drawingRect(forBounds: rect)
        let height = cellSize(forBounds: rect).height
        guard height < base.height else { return base }
        return NSRect(x: base.minX, y: base.minY + ((base.height - height) / 2).rounded(),
                      width: base.width, height: height)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor: NSText,
                       delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: drawingRect(forBounds: rect), in: controlView, editor: editor,
                   delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor: NSText,
                         delegate: Any?, start: Int, length: Int) {
        super.select(withFrame: drawingRect(forBounds: rect), in: controlView, editor: editor,
                     delegate: delegate, start: start, length: length)
    }
}
