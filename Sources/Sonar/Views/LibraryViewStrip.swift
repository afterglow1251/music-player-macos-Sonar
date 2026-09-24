import SwiftUI

/// The library's view switcher as a strip that slides out of its icon.
///
/// At rest it's one icon — the current sort, always (the favorites filter shows
/// only inside the strip, as its heart lit or not). Hover it and the choices spring out to the left, one after
/// another: ♥ (the favorites *filter*, set apart by a divider since it combines
/// with any sort) then the four sorts. The active ones are simply coloured —
/// accent for the sort, pink for the filter — no checkmarks. One move and one
/// click instead of opening a menu.
///
/// It opens the instant the pointer lands on the icon, and closes only once the
/// pointer has left the whole strip (after a blink), so drifting between
/// icons doesn't snap it shut. A click on
/// the icon toggles it too (no hover on a trackpad tap).
struct LibraryViewStrip: View {
    @Binding var view: LibraryView
    @Binding var favoritesOnly: Bool

    @State private var expanded = false
    @State private var hoverTask: Task<Void, Never>?

    private static let openDelay: Duration = .zero
    private static let closeDelay: Duration = .milliseconds(60)

    var body: some View {
        HStack(spacing: 2) {
            if expanded {
                // Leftmost first; each springs in a beat after the one to its right,
                // so the strip unrolls outward from the icon.
                option(0, symbol: favoritesOnly ? "heart.fill" : "heart", label: "Favorites",
                       tint: favoritesOnly ? Theme.favorite : nil) { favoritesOnly.toggle() }
                Rectangle()
                    .fill(.white.opacity(0.15))
                    .frame(width: 1, height: 12)
                    .padding(.horizontal, 3)
                    .transition(unroll(1))
                ForEach(Array(LibraryView.allCases.enumerated()), id: \.element) { index, mode in
                    option(index + 2, symbol: mode.symbol, label: mode.label,
                           tint: view == mode ? Theme.accent : nil) { view = mode }
                }
            } else {
                Button { setExpanded(true) } label: {
                    icon(view.symbol, color: .white.opacity(0.6))
                }
                .buttonStyle(PressableButtonStyle())
                .transition(.opacity)
            }
        }
        .padding(.horizontal, expanded ? 4 : 0)
        .background(Capsule().fill(.white.opacity(expanded ? 0.06 : 0)))
        .fixedSize()
        .onHover { inside in
            hoverTask?.cancel()
            // Opening is immediate — no task hop, no beat to wait out.
            if inside, Self.openDelay == .zero {
                setExpanded(true)
                return
            }
            hoverTask = Task {
                try? await Task.sleep(for: inside ? Self.openDelay : Self.closeDelay)
                guard !Task.isCancelled else { return }
                setExpanded(inside)
            }
        }
    }

    private func setExpanded(_ open: Bool) {
        guard open != expanded else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { expanded = open }
    }

    /// Choice `index` of the strip (0 = leftmost). `tint` marks it active.
    private func option(_ index: Int, symbol: String, label: String, tint: Color?,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            icon(symbol, color: tint ?? .white.opacity(0.55))
        }
        .buttonStyle(PressableButtonStyle())
        .tooltip(label)
        .transition(unroll(index))
    }

    private func icon(_ symbol: String, color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(color)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
    }

    /// Springs in from the icon's side, the ones further left a little later;
    /// leaves all at once, quickly.
    private func unroll(_ index: Int) -> AnyTransition {
        let count = LibraryView.allCases.count + 2   // ♥, divider, the sorts
        let delay = Double(count - 1 - index) * 0.03
        return .asymmetric(
            insertion: .scale(scale: 0.4, anchor: .trailing)
                .combined(with: .opacity)
                .combined(with: .offset(x: 12))
                .animation(.spring(response: 0.34, dampingFraction: 0.7).delay(delay)),
            removal: .opacity.animation(.easeOut(duration: 0.12)))
    }
}
