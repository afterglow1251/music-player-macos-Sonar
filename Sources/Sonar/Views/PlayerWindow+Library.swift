import SwiftUI
import AppKit

extension PlayerWindow {
    // MARK: Library section (header with expandable search + track list)

    /// Normal window: fixed-height list.
    var librarySection: some View { libraryCard(list: trackScroll(fixedHeight: 168)) }

    /// Fullscreen: the card fills an exact height (matched to the left column), the
    /// list stretches to fill it, and it stays transparent so it blends into the
    /// dark backdrop instead of reading as a lighter panel.
    func fullscreenLibrary(height: CGFloat) -> some View {
        libraryCard(list: trackScroll(fixedHeight: nil), plain: true).frame(height: height)
    }

    private func libraryCard(list: some View, plain: Bool = false) -> some View {
        VStack(spacing: 0) {
            if let playlist = selectedPlaylist { playlistHeader(playlist) } else { libraryHeader }
            // Keep the source switcher present while searching too: toggling it in/out
            // changed the height above the list, which nudged the scroll position on
            // every open/close of search.
            sourceBar
            Divider().overlay(Color.white.opacity(0.06)).padding(.horizontal, 6).padding(.top, 6)
            list
        }
        // Floating action bar for the current multi-selection, so bulk Favorite /
        // Playlist / Queue / Delete are one visible tap away — not hidden behind a
        // right-click. Slides up from the bottom of the card when 2+ rows are picked.
        .overlay(alignment: .bottom) { selectionBar }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: trackSelection.selection.count >= 2)
        // Transparent fill in fullscreen so it blends with the dark backdrop, but
        // always keep a border so the panel still has defined edges. Both live in
        // .background (not .overlay) so the border never paints over content that
        // draws its own overlays on top of itself, e.g. header button tooltips.
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(plain ? Color.clear : .white.opacity(0.05))
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(plain ? 0.1 : 0.06))
            }
        )
    }

    private var libraryHeader: some View {
        HStack(spacing: 8) {
            if searchActive {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                SteadyTextField(placeholder: "Search…", text: $searchText, focus: $searchFieldFocused)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { searchActive = false }
                    searchText = ""
                    searchFieldFocused = false
                } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
            } else {
                Text("LIBRARY")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                Text("\(controller.library.tracks.count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.3))
                Spacer()
                if !controller.library.tracks.isEmpty {
                    LibraryViewStrip(view: viewBinding, favoritesOnly: favoritesBinding)
                }
                Button { controller.library.revealInFinder() } label: {
                    Image(systemName: "folder").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .tooltip("Show in Finder")
                if !controller.library.tracks.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { searchActive = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { searchFieldFocused = true }
                    } label: {
                        Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(width: 22, height: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(PressableButtonStyle())
                    .tooltip("Search")
                }
            }
        }
        .frame(height: 24)
        .padding(.horizontal, 10)
        .padding(.top, 8).padding(.bottom, 4)
    }

    /// Land on the currently-playing track: clear anything that would hide it — an
    /// active search, the favorites filter, a source that doesn't hold it — then
    /// scroll it into the middle of the list. Driven by the "Playing from" label.
    func goToCurrentTrack() {
        // Nothing to land on if the track isn't in the library: it's playing on out
        // of a folder we've since been pointed away from, so no list holds a row for
        // it and the scroll below would resolve against nothing and quietly do
        // nothing. The label hides itself in that case; this is the backstop.
        guard currentTrackInLibrary else { return }
        if searchActive {
            withAnimation(.easeInOut(duration: 0.2)) { searchActive = false }
            searchText = ""
            searchFieldFocused = false
        }
        if controller.favorites.filterActive { controller.favorites.setFilter(false) }
        // Land in the source the label names, even when the list on screen happens to
        // hold the track too: the caption reads "Playing from <name>" and its tooltip
        // "Go to <name>", so landing anywhere else would make both a lie.
        if playingSourceTarget != selectedPlaylistID {
            suppressTopResetOnce = true   // we're about to centre on the track, not reset to top
            selectSource(playingSourceTarget)
        }
        scrollToCurrentNonce += 1
    }

    /// Where a tap on the "Playing from <name>" label should land, as a source id:
    /// the playlist the track is playing from, or the library (nil) if that playlist
    /// was since deleted or had the track removed from it. Keeps the jump honest
    /// about the one thing it must deliver — a row for the playing track.
    private var playingSourceTarget: Playlist.ID? {
        guard let current = controller.currentTrack,
              let id = controller.playingSourceID,
              let playlist = controller.playlists.playlists.first(where: { $0.id == id }),
              controller.tracks(in: playlist).contains(current) else { return nil }
        return id
    }

    // MARK: Source switcher (Library + playlists)

    /// Currently viewed playlist, or nil while the whole library is shown. Falls
    /// back to nil if the selected playlist was deleted.
    var selectedPlaylist: Playlist? {
        guard let id = selectedPlaylistID else { return nil }
        return controller.playlists.playlists.first { $0.id == id }
    }

    /// The display name of the source the current track is playing from, for the
    /// "Playing from …" label — nil when nothing is loaded (or the source
    /// playlist was since deleted, leaving nothing meaningful to point at).
    var playingSourceName: String? {
        guard controller.currentTrack != nil else { return nil }
        // A track playing on out of a folder the library has been pointed away from
        // has no source on screen to name — "Library" would mean the new folder,
        // which is precisely where this track isn't. Say nothing rather than lie.
        guard currentTrackInLibrary else { return nil }
        guard let id = controller.playingSourceID else { return "Library" }
        return controller.playlists.playlists.first { $0.id == id }?.name
    }

    /// The selected playlist's tracks resolved against the library (order kept,
    /// missing files dropped).
    var playlistTracks: [Track] {
        guard let playlist = selectedPlaylist else { return [] }
        return controller.tracks(in: playlist)
    }

    /// Whether the playing track is reachable in the UI at all: every list on
    /// screen — the library and every playlist — is built out of the current
    /// folder's files, so a track that isn't in the library appears nowhere. True
    /// of a track that's playing on after the folder was switched out from under
    /// it; playback deliberately survives the switch (`libraryFolderChanged`),
    /// so the UI has to cope with an audible track it can't point at.
    var currentTrackInLibrary: Bool {
        guard let current = controller.currentTrack else { return false }
        return controller.library.tracks.contains { $0.id == current.id }
    }

    /// Pills that switch the track list between the library and each playlist,
    /// plus a "＋" to make a new one.
    private var sourceBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                sourcePill(title: "Library", systemImage: "music.note",
                           selected: selectedPlaylistID == nil) { selectSource(nil) }
                ForEach(controller.playlists.playlists) { playlist in
                    sourcePill(title: playlist.name, systemImage: "music.note.list",
                               selected: selectedPlaylistID == playlist.id) { selectSource(playlist.id) }
                        .contextMenu {
                            Button("Play") { controller.playPlaylist(playlist) }
                            Button("Play Next") { controller.playNext(playlist) }
                            Button("Add to Queue") { controller.addToQueue(playlist) }
                            Divider()
                            Button("Rename") { beginRename(id: playlist.id, current: playlist.name) }
                            Divider()
                            Button("Delete", role: .destructive) { deletePlaylist(playlist.id) }
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
                Button { createPlaylist() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 22, height: 20)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableButtonStyle(hoverScale: 1.08))
                .tooltip("New playlist")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            // Animate pills sliding in/out as playlists are created or deleted.
            .animation(.easeInOut(duration: 0.22), value: controller.playlists.playlists.count)
        }
        .scrollIndicators(.never)
    }

    /// A source tab: `selected` (the source you're browsing) is a solid green
    /// fill, everything else neutral grey. Which source is *playing* is shown by
    /// the "Playing from …" label above the track, not here — the tab row stays
    /// calm.
    private func sourcePill(title: String, systemImage: String, selected: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 9))
                Text(title).font(.system(size: 10, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(selected ? .black : .white.opacity(0.7))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(selected ? accent.opacity(0.9) : Color.white.opacity(0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle(hoverScale: 1.05))
        // Animate only the highlight colour, not a layout morph — keeps switching crisp.
        .animation(.easeInOut(duration: 0.18), value: selected)
    }

    /// Header shown in place of the LIBRARY header while viewing a playlist.
    private func playlistHeader(_ playlist: Playlist) -> some View {
        HStack(spacing: 8) {
            if renamingPlaylist && renameTargetID == playlist.id {
                SteadyTextField(placeholder: "Playlist name", text: $renameText,
                                font: .systemFont(ofSize: 11, weight: .semibold),
                                textColor: .white,
                                onSubmit: { commitRename() },
                                onCancel: { cancelRename() },
                                focus: $renameFieldFocused)
                    .frame(maxWidth: 180)
                    .onChange(of: renameFieldFocused) { _, focused in
                        if !focused { commitRename() }   // commit when clicked away
                    }
            } else {
                Text(playlist.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent.opacity(0.9))
                    .lineLimit(1)
                Text("\(playlist.trackPaths.count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.3))
            }
            Spacer()
            if !playlistTracks.isEmpty {
                Button { controller.playPlaylist(playlist) } label: {
                    Image(systemName: "play.fill").font(.system(size: 11))
                        .foregroundStyle(accent)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .tooltip("Play")
            }
            Button { beginRename(id: playlist.id, current: playlist.name) } label: {
                Image(systemName: "pencil").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .tooltip("Rename")
            Button { deletePlaylist(playlist.id) } label: {
                Image(systemName: "trash").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .tooltip("Delete playlist")
        }
        .frame(height: 24)
        .padding(.horizontal, 10)
        .padding(.top, 8).padding(.bottom, 4)
    }

    // MARK: Source actions

    func selectSource(_ id: Playlist.ID?) {
        if renamingPlaylist && id != renameTargetID { cancelRename() }
        // Switch instantly: animating a full header swap (LIBRARY ↔ playlist)
        // interpolates two different layouts and stutters. The tab highlight
        // animates on its own; the list content just swaps cleanly.
        // Remember the outgoing source's offset HERE, before mutating the id:
        // by the time onChange(of: selectedPlaylistID) fires, SwiftUI has already
        // swapped the list content, and the offset may have been clamped against
        // the incoming (possibly much shorter) list — saving there recorded ~0
        // and every source reopened at the top.
        if id != selectedPlaylistID, let sv = autoScroller.scrollView {
            scrollMemory[selectedPlaylistID] = sv.contentView.bounds.origin.y
        }
        selectedPlaylistID = id
        if id != nil { searchActive = false; searchText = "" }
    }

    /// Create a playlist, optionally seed it with `track`. When `select` is true
    /// (the ＋ button / Save-queue), switch to it and start inline-naming it right
    /// away; when false (library's "New Playlist…"), create it quietly with its
    /// default name and stay put.
    func createPlaylist(addingTrack track: Track? = nil, select: Bool = true) {
        let playlist = controller.playlists.create()
        if let track { _ = controller.playlists.add(path: track.url.path, to: playlist.id) }
        if select { beginRename(id: playlist.id, current: playlist.name) }
    }

    /// Create a playlist seeded with several tracks (multi-select "New Playlist…").
    func createPlaylist(addingTracks tracks: [Track], select: Bool = true) {
        let playlist = controller.playlists.create()
        for track in tracks { _ = controller.playlists.add(path: track.url.path, to: playlist.id) }
        if select { beginRename(id: playlist.id, current: playlist.name) }
    }

    /// Switch to a playlist and turn its header name into a focused text field.
    func beginRename(id: Playlist.ID, current: String) {
        selectSource(id)
        renameTargetID = id
        renameText = current
        renamingPlaylist = true
        // Focus on the next runloop tick — just late enough for the field to be
        // in the hierarchy, without the visible pause a timed delay adds.
        DispatchQueue.main.async { renameFieldFocused = true }
    }

    private func commitRename() {
        guard renamingPlaylist else { return }
        if let id = renameTargetID { controller.playlists.rename(id, to: renameText) }
        cancelRename()
    }

    private func cancelRename() {
        renamingPlaylist = false
        renameTargetID = nil
        renameFieldFocused = false
    }

    private func deletePlaylist(_ id: Playlist.ID) {
        if selectedPlaylistID == id { selectSource(nil) }
        controller.playlists.delete(id)
    }

    /// Add-to-playlist submenu entries for a library row.
    func playlistMenuItems(for track: Track) -> [PlaylistMenuItem] {
        let path = track.url.path
        return controller.playlists.playlists.map { playlist in
            PlaylistMenuItem(id: playlist.id, name: playlist.name,
                             contains: playlist.trackPaths.contains(path)) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    _ = controller.playlists.add(path: path, to: playlist.id)
                }
            }
        }
    }

    // MARK: Sort & group

    /// The browse order the header's `LibraryViewStrip` picks.
    private var viewBinding: Binding<LibraryView> {
        // No withAnimation here: animating a full reorder of the (lazy) list makes
        // SwiftUI compute transitions for every row, which for a large library
        // takes seconds. Snap to the new order instead — it's instant.
        Binding(get: { controller.library.view },
                set: { new in controller.library.setView(new) })
    }

    private var favoritesBinding: Binding<Bool> {
        Binding(get: { controller.favorites.filterActive },
                set: { on in controller.favorites.setFilter(on) })
    }

    // MARK: Artist sections

    /// Artist view sections: every artist with 2+ tracks becomes its own section
    /// (alphabetical, tracks in track-number order), and all single-track artists
    /// are gathered into one "Various" section at the end — so a diverse library
    /// isn't a wall of one-line headers.
    var artistSections: [LibrarySection] {
        let groups = Dictionary(grouping: filteredTracks) { $0.artist.isEmpty ? "Unknown Artist" : $0.artist }
        var sections: [LibrarySection] = []
        var singles: [Track] = []
        for (name, tracks) in groups {
            if tracks.count >= 2 {
                let ordered = tracks.sorted {
                    ($0.trackNumber ?? .max, $0.displayTitle.lowercased())
                        < ($1.trackNumber ?? .max, $1.displayTitle.lowercased())
                }
                sections.append(LibrarySection(id: name, tracks: ordered, isVarious: false))
            } else {
                singles.append(contentsOf: tracks)
            }
        }
        sections.sort { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
        if !singles.isEmpty {
            let ordered = singles.sorted {
                let a = $0.artist.lowercased(), b = $1.artist.lowercased()
                if a != b { return a < b }
                return $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
            }
            sections.append(LibrarySection(id: "Various", tracks: ordered, isVarious: true))
        }
        return sections
    }

    /// The list the library section renders. Empty query → the whole library
    /// (cheap, always fresh). Otherwise the precomputed `searchResults`, filled
    /// by the debounced, off-main task — never fuzzy-ranked inside `body`.
    var filteredTracks: [Track] {
        let base = searchText.trimmingCharacters(in: .whitespaces).isEmpty
            ? controller.library.tracks
            : searchResults
        guard controller.favorites.filterActive else { return base }
        return base.filter { controller.favorites.isFavorite($0.url.path) }
    }

    /// The scope a library tap plays in. With the favorites filter on, playback
    /// walks the visible favorites (so next/previous stay within them); otherwise
    /// nil lets `play()` default to the whole library.
    var libraryPlaybackScope: [Track]? {
        controller.favorites.filterActive ? filteredTracks : nil
    }
}

/// Three little bars that dance while a track plays — the universal "now
/// playing" mark, sized to sit where a source pill's note glyph would. Driven
/// by a paused-when-idle `TimelineView`, so it costs nothing while stopped or
/// while the window is hidden; when paused it holds a still, uneven pose.
struct NowPlayingBars: View {
    var color: Color
    var animating: Bool

    private let count = 3
    private let barWidth: CGFloat = 2
    private let maxHeight: CGFloat = 9
    // Distinct speeds/phases per bar so they don't pump in lockstep.
    private let speeds: [Double] = [5.1, 3.7, 4.4]
    private let phases: [Double] = [0.0, 1.7, 3.1]
    private let resting: [CGFloat] = [0.5, 0.85, 0.6]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !animating)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 1.5) {
                ForEach(0..<count, id: \.self) { i in
                    Capsule(style: .continuous)
                        .fill(color)
                        .frame(width: barWidth, height: height(i, t: t))
                }
            }
            .frame(width: 10, height: maxHeight, alignment: .center)
        }
    }

    private func height(_ i: Int, t: Double) -> CGFloat {
        guard animating else { return maxHeight * resting[i] }
        let v = (sin(t * speeds[i] + phases[i]) + 1) / 2   // 0…1
        return maxHeight * (0.3 + 0.7 * CGFloat(v))
    }
}
