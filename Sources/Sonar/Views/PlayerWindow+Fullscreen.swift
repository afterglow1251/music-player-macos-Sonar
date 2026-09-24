import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension PlayerWindow {
    // MARK: Fullscreen (the whole player, spread across the big screen)

    /// Fullscreen (and a window big enough for it — see `usesWideLayout`)
    /// reuses every normal control — nothing is lost. It just lays the player
    /// out in two columns (now-playing on the left, library/queue on the right)
    /// over a blurred-artwork backdrop, with a larger visualizer.
    var fullscreenContent: some View {
        GeometryReader { geo in
            // Scale the cover and the list to the actual screen so it truly fills,
            // and center the two columns so there's no top-left void.
            //
            // The cover is also capped by what's left once the controls under it
            // (~460pt) and the library column beside it are accounted for, so a
            // window just past `wideLayoutMinSize` shrinks the cover instead of
            // pushing the column off the bottom or the library off the side.
            let rightWidth = min(max(geo.size.width * 0.30, 420), 780)
            let artFit = min(geo.size.height * 0.5, geo.size.height - 460,
                             geo.size.width - rightWidth - 60 - 64)
            let artSize = min(max(artFit, 300), 660)
            ZStack {
                fullscreenBackdrop
                HStack(alignment: .top, spacing: 60) {
                    VStack(spacing: 16) {
                        heroSlot(width: artSize, height: artSize)
                        infoStrip
                        visualizerStrip
                        positionSlider
                        transportRow
                        utilityRow
                        DownloadBar(controller: controller, downloader: controller.downloader, urlChips: $urlChips, shakingChipURL: $shakingChipURL, urlFieldFocused: $urlFieldFocused)
                    }
                    .frame(width: artSize)
                    // Measure the left column so the library can match its height exactly.
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: ColumnHeightKey.self, value: proxy.size.height)
                    })

                    fullscreenLibrary(height: fsLeftHeight)
                        .frame(width: rightWidth)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onPreferenceChange(ColumnHeightKey.self) { fsLeftHeight = max($0, 320) }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color.black)
        .ignoresSafeArea()
        // Files & URLs only (not plain text) so an internal reorder drag doesn't
        // trigger the window's drop highlight.
        .onDrop(of: [.fileURL, .url], isTargeted: $isDropTargeted) { handleDrop($0) }
        .overlay(alignment: .bottom) { bottomToasts }
        // ⌘, toggles the inline settings panel here too.
        .onReceive(NotificationCenter.default.publisher(for: .toggleSettings)) { _ in
            withAnimation(.easeInOut(duration: 0.22)) { showSettings.toggle() }
        }
        // ←/→ seek ±10s, ⌘↑/↓ volume, ↑/↓ walk the track-list cursor + ↩ plays it
        // (space is handled by the play button itself).
        .background {
            if !urlFieldFocused && !searchFieldFocused && !renameFieldFocused {
                Group {
                    Button("") { controller.seekBy(-10) }.keyboardShortcut(.leftArrow, modifiers: [])
                    Button("") { controller.seekBy(10) }.keyboardShortcut(.rightArrow, modifiers: [])
                    Button("") { controller.adjustVolume(0.05) }.keyboardShortcut(.upArrow, modifiers: .command)
                    Button("") { controller.adjustVolume(-0.05) }.keyboardShortcut(.downArrow, modifiers: .command)
                    Button("") { moveSelection(by: -1) }.keyboardShortcut(.upArrow, modifiers: [])
                    Button("") { moveSelection(by: 1) }.keyboardShortcut(.downArrow, modifiers: [])
                    Button("") { playSelectedTrack() }.keyboardShortcut(.return, modifiers: [])
                    Button("") { selectAll() }.keyboardShortcut("a", modifiers: .command)
                    Button("") { deleteSelection() }.keyboardShortcut(.delete, modifiers: .command)
                }
                .hidden()
            }
        }
    }

    private var fullscreenBackdrop: some View {
        ZStack {
            Color.black
            if let image = artworkImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 80)
                    .opacity(0.28)
                    .scaleEffect(1.2)
            }
            LinearGradient(colors: [.black.opacity(0.45), .clear, .black.opacity(0.55)],
                           startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }
}
