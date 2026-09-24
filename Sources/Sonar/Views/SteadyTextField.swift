import SwiftUI

/// A borderless text field with a **static** placeholder that never jitters.
///
/// AppKit's native placeholder shifts ~1px between the empty/edited states; here
/// we draw our own placeholder and disable the focus ring, so it stays put.
///
/// The app's one text input: use it for every field. While it's focused it
/// reports `TextInputFocusKey` up the tree, which is how the player window knows
/// to stand down its bare-key shortcuts (⌘A select-all tracks, arrows, ↩, ⌘⌫) so
/// they edit the text instead — for any field, with nothing to wire per field.
struct SteadyTextField: View {
    let placeholder: String
    @Binding var text: String
    var font: Font = .system(size: 12)
    var placeholderColor: Color = .white.opacity(0.4)
    var textColor: Color = .white
    var onSubmit: () -> Void = {}
    /// Optional outside handle on the focus, for callers that move it
    /// programmatically; otherwise the field tracks its own.
    var focus: FocusState<Bool>.Binding? = nil
    @FocusState private var ownFocus: Bool

    private var isFocused: Bool { focus?.wrappedValue ?? ownFocus }

    var body: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(font)
                    .foregroundStyle(placeholderColor)
                    .allowsHitTesting(false)
            }
            field
        }
        .preference(key: TextInputFocusKey.self, value: isFocused)
    }

    private var field: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(textColor)
            .focusEffectDisabled()
            .onSubmit(onSubmit)
            .focused(focus ?? $ownFocus)
    }
}

/// Whether any `SteadyTextField` below is focused (being typed in).
struct TextInputFocusKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}
