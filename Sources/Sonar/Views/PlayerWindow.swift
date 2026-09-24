import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The main player window — a modern retro-skinned player: a big uncropped cover,
/// a blurred artwork backdrop, glassy panels, and the classic tile visualizer.
struct PlayerWindow: View {
    @StateObject var controller = PlayerController.shared
    /// Pauses the per-frame eye candy (visualizer, breathing cover, marquee)
    /// while the window can't be seen — fully covered, minimized, other Space.
    @StateObject var windowOcclusion = WindowOcclusionMonitor()
    @State var isFullscreen = false
    /// The (non-fullscreen) window is big enough for the two-column layout —
    /// e.g. zoomed to fill the screen — so it gets the same spread as fullscreen.
    @State var isWideWindow = false
    @State var fsLeftHeight: CGFloat = 400   // measured left-column height (fullscreen)
    @State var scrollToCurrentNonce = 0      // bump to scroll the list to the current track
    @State var jumpGeneration = 0            // invalidates a pending "jump to current track" when the source changes
    /// The keyboard/selection model (cursor, ⇧-anchor, multi-selection,
    /// explicitness) as one value-type reducer — a single `@State`, so it
    /// invalidates the same way the four separate `@State` vars used to.
    @State var trackSelection = TrackSelection()
    @State var scrollToSelectionNonce = 0    // bump to scroll to the cursor (keyboard nav only)
    @State var suppressTopResetOnce = false  // skip the next source-switch scroll restore (goToCurrentTrack centres instead)
    @State var scrollMemory: [Playlist.ID?: CGFloat] = [:]  // per-source scroll offset, so each source reopens where you left it
    @State var scrollRestorer = ScrollOffsetRestorer()      // chases a remembered offset across the lazy content swap
    static let listBottomAnchorID = "nav-list-bottom"  // tail scroll anchor for the last row
    static let listTopAnchorID = "nav-list-top"        // head scroll anchor for the first row
    @State var muteHovering = false           // mute button hover (driven by its AppKit catcher)
    @State var visualizerMode: VisualizerMode = .spectrum
    @State var isScrubbing = false
    @State var scrubTime: TimeInterval = 0
    @State var seekHoverX: CGFloat?   // cursor x over the position slider
    // Gesture-driven reorder, shared by library & queue (ids never collide:
    // library rows key on file path, queue rows on a UUID string).
    @State var rowFrames: [String: CGRect] = [:]
    @State var draggingID: String?
    @State var dragCursorY: CGFloat = 0
    /// The dragged row's slot frame, snapshotted at drag start — sizes/places the
    /// floating ghost and anchors the shift math even after the lazy stack culls
    /// the row itself.
    @State var draggedFrame: CGRect?
    /// Scrolls the list when a reorder drag nears the viewport edge, so long
    /// lists can be reordered past the visible rows.
    @State var autoScroller = ReorderAutoScroller()
    // Collapsed artist sections (Artist view).
    @State var collapsedGroups: Set<String> = []
    // Source switcher: nil = the whole library, otherwise the viewed playlist.
    @State var selectedPlaylistID: Playlist.ID?
    @State var renamingPlaylist = false
    @State var renameText = ""
    @State var renameTargetID: Playlist.ID?
    @State var showSettings = false
    @State var showLyrics = false
    @State var searchText = ""
    @State var searchActive = false
    @State var searchResults: [Track] = []   // filled off-main by the debounced search task
    @State var urlChips: [String] = []   // links queued via the ＋ button
    @State var shakingChipURL: String?   // chip to shake when a dupe is re-added
    @State var isDropTargeted = false
    /// Whether the pointer is over the now-playing title/artist strip — reveals the
    /// "open on YouTube" link there without leaving a button parked at rest.
    @State var nowPlayingHover = false
    /// Decoded once per track (not per frame) so the breathing animation doesn't
    /// re-decode the artwork 30×/sec.
    @State var artworkImage: NSImage?
    @FocusState var urlFieldFocused: Bool
    @FocusState var searchFieldFocused: Bool
    @FocusState var renameFieldFocused: Bool

    /// Accent — the signature green, used sparingly.
    let accent = Theme.accent

    let contentWidth: CGFloat = 460
    let artHeight: CGFloat = 340

    var engine: AudioEngine { controller.engine }

    /// Two columns (now-playing | library) instead of the single stacked one:
    /// always in fullscreen, and in a window whenever both columns fit.
    var usesWideLayout: Bool { isFullscreen || isWideWindow }

    /// The smallest window content size the two-column layout fits in without
    /// cramping: the minimum cover + gap + minimum library width, and a cover
    /// tall enough to still read as the hero next to the controls below it.
    static let wideLayoutMinSize = CGSize(width: 880, height: 760)

    static func fitsWideLayout(_ size: CGSize) -> Bool {
        size.width >= wideLayoutMinSize.width && size.height >= wideLayoutMinSize.height
    }

    var body: some View {
        Group {
            if usesWideLayout {
                fullscreenContent
            } else {
                normalContent
            }
        }
        // Fill the window (the single column stays centred in it) so the reader
        // below measures the window's content area, not the fixed-width column.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { isWideWindow = Self.fitsWideLayout(proxy.size) }
                .onChange(of: proxy.size) { _, size in isWideWindow = Self.fitsWideLayout(size) }
        })
        // Enable the native green fullscreen button / ⌃⌘F, and track its state so
        // we can swap in the immersive visualizer when the window goes fullscreen.
        .background(FullscreenEnabler())
        // Open snug to the fixed-width content — no empty margins beside it.
        .background(WindowWidthSnapper())
        // Esc handling for BOTH modes, via a local NSEvent monitor that fires
        // before the window: we swallow the key (return true) whenever there's an
        // open layer to peel back — a section (settings/lyrics), the search, or a
        // multi-selection. This is a monitor rather than `.onExitCommand` because
        // (a) in fullscreen macOS leaves fullscreen on Esc by itself and only
        // consuming the event stops that, and (b) a focused list row can swallow
        // Esc before `.onExitCommand` ever sees it. Returning false lets Esc through
        // to its default job — leave fullscreen, or just drop the cursor.
        .background(EscapeInterceptor {
            if showSettings || showLyrics {
                withAnimation(.easeInOut(duration: 0.22)) {
                    showSettings = false
                    showLyrics = false
                }
                return true
            } else if searchActive {
                withAnimation(.easeInOut(duration: 0.2)) { searchActive = false }
                searchText = ""
                searchFieldFocused = false
                return true
            } else if trackSelection.selection.count > 1 {
                trackSelection.selection.removeAll()          // clear the whole multi-selection
                trackSelection.selectionIsExplicit = false
                return true
            } else if urlFieldFocused || searchFieldFocused {
                dismissFocus()
                return true
            }
            return false
        })
        // Decode artwork here (not in normalContent) so the cover updates in
        // fullscreen too, where normalContent isn't in the tree.
        .onAppear { decodeArtwork(controller.currentTrack) }
        .onChange(of: controller.currentTrack) { _, track in decodeArtwork(track) }
        // Search runs here, not in `body`: debounce the keystrokes, then rank on a
        // background task so a big library never blocks the UI. Re-keys on every
        // searchText change (the previous task is cancelled automatically).
        .task(id: searchText) {
            let query = searchText.trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty else { return }        // empty → filteredTracks uses the library directly
            try? await Task.sleep(for: .milliseconds(150))
            if Task.isCancelled { return }
            let tracks = controller.library.tracks
            let ranked = await Task.detached { PlayerWindow.rank(query: query, tracks: tracks) }.value
            if Task.isCancelled { return }
            searchResults = ranked
        }
        // Also re-decode when only the artwork changes (same track, metadata just
        // finished loading after a download) — same-url tracks compare equal, so
        // the change above wouldn't fire.
        .onChange(of: controller.currentTrack?.artworkData) { _, _ in
            decodeArtwork(controller.currentTrack)
        }
        // Swap to the fullscreen layout at the *start* of the native animation
        // (will…, not did…), so the two-column layout and its blurred backdrop grow
        // together with the window — instead of the small windowed column floating
        // in a growing black void and then popping into place once the animation ends.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in
            isFullscreen = true
        }
        // …and swap back to the windowed layout at the *start* of the exit animation
        // too, so the shrinking window never shows the two-column fullscreen layout
        // crammed (and cover-clipped) into a half-size frame. The normal single column
        // rides the shrink down instead.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
            isFullscreen = false
        }
        // Remember playback position on quit (in addition to pause/track-change).
        // On the body, not a layout, so it's registered whichever layout is showing.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            controller.saveOnQuit()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            // Once windowed again, snap the frame to the fixed-width content's natural
            // size so there are no leftover black margins around it. `normalContent`
            // has been laid out for the whole shrink (swapped in at willExit), so its
            // fittingSize is already correct — no settling delay needed.
            guard let window = note.object as? NSWindow else { return }
            Task { @MainActor in
                // A window restored to a two-column size keeps it — there are no
                // margins to trim there.
                if let content = window.contentView, !Self.fitsWideLayout(content.frame.size) {
                    let fit = content.fittingSize
                    if fit.width > 100, fit.height > 100 { window.setContentSize(fit) }
                }
            }
        }
    }

    private var normalContent: some View {
        VStack(spacing: 12) {
            heroSlot(width: contentWidth, height: artHeight)
            infoStrip
            visualizerStrip
            positionSlider
            transportRow
            utilityRow
            DownloadBar(controller: controller, downloader: controller.downloader, urlChips: $urlChips, shakingChipURL: $shakingChipURL, urlFieldFocused: $urlFieldFocused)
            librarySection
        }
        .padding(16)
        .frame(width: contentWidth + 32)
        // Click any empty (black) area to dismiss the URL field's cursor.
        .background(
            backdrop
                .contentShape(Rectangle())
                .onTapGesture { dismissFocus(); trackSelection.selection.removeAll() }
        )
        .overlay(alignment: .bottom) { bottomToasts }
        // Drag & drop audio files or a YouTube link onto the window.
        // Files & URLs only (not plain text) so an internal reorder drag doesn't
        // trigger the window's drop highlight.
        .onDrop(of: [.fileURL, .url], isTargeted: $isDropTargeted) { handleDrop($0) }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8).stroke(accent, lineWidth: 2).padding(4)
            }
        }
        // Escape: peel back one layer — an open section (settings/lyrics), then the
        // search, then a multi-selection — otherwise just drop the cursor.
        .onExitCommand {
            if showSettings || showLyrics {
                withAnimation(.easeInOut(duration: 0.22)) {
                    showSettings = false
                    showLyrics = false
                }
            } else if searchActive {
                withAnimation(.easeInOut(duration: 0.2)) { searchActive = false }
                searchText = ""
                searchFieldFocused = false
            } else if trackSelection.selection.count > 1 {
                trackSelection.selection = trackSelection.selectedTrackID.map { [$0] } ?? []   // collapse a multi-selection first
                trackSelection.selectionIsExplicit = false
            } else {
                dismissFocus()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSettings)) { _ in
            withAnimation(.easeInOut(duration: 0.22)) { showSettings.toggle() }
        }
        // Keyboard model (active only while no text field is focused, so fields
        // keep their own keys): ↑/↓ walk the track-list cursor and ↩ plays it;
        // ←/→ seek ±10s; ⌘↑/↓ volume. The list is the default owner of the bare
        // arrows — no focus mode to enter or a cursor to re-acquire.
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
        // Don't let the URL field grab the cursor on launch.
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
    }

    // MARK: Backdrop (blurred artwork behind everything)

    /// A blurred wash of the current cover behind the whole player, so the window
    /// takes on the song's colours instead of sitting on flat black — the same
    /// ambient treatment the fullscreen layout uses, sized for the window. With
    /// no artwork it's just black.
    private var backdrop: some View {
        ZStack {
            Color.black
            if let image = artworkImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 70)
                    .opacity(0.32)
                    .scaleEffect(1.3)
            }
            // Darken toward the bottom so the library rows and controls stay
            // legible over brighter covers.
            LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0.62)],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    /// Fuzzy-rank a (non-empty) query against the library. Static & pure so it can
    /// run on a background task without touching view state. `nonisolated` +
    /// `Sendable` inputs let it hop off the main actor.
    nonisolated static func rank(query: String, tracks: [Track]) -> [Track] {
        tracks
            .compactMap { track -> (track: Track, score: Double)? in
                guard let s = FuzzySearch.score(query, in: [track.displayTitle, track.artist]) else { return nil }
                return (track, s)
            }
            .sorted { $0.score > $1.score }
            .map(\.track)
    }

    // MARK: Helpers

    /// Drop the cursor from any text field (Esc / click outside).
    func dismissFocus() {
        urlFieldFocused = false
        searchFieldFocused = false
    }

    private func decodeArtwork(_ track: Track?) {
        artworkImage = track?.artworkData.flatMap { NSImage(data: $0) }
    }

}
