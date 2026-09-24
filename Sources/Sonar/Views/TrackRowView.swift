import SwiftUI

/// One row in the library list. Highlights on hover and when it's the current
/// track, so the playlist feels interactive.
struct TrackRowView: View {
    let track: Track
    let isCurrent: Bool
    let isPlaying: Bool
    /// Keyboard-navigation cursor: this row sits under the ↑/↓ selection. Drawn as
    /// an accent outline, distinct from the filled `isCurrent` (now-playing) row.
    var isSelected: Bool = false
    /// Whether the selection was a deliberate pick (⌘/⇧-click, ⌘A, arrows) rather
    /// than the side effect of click-to-play — deliberate picks outline even the
    /// playing row, which otherwise suppresses the border.
    var selectionIsExplicit: Bool = false
    let durationText: String
    let onTap: () -> Void
    let onPlayNext: () -> Void
    let onAddToQueue: () -> Void
    let onDelete: () -> Void
    /// Whether to show the artist subtitle. Hidden when the list is already grouped
    /// by artist (the section header names the artist, so repeating it is noise).
    var showArtist: Bool = true
    /// Whether the queue already has items. When empty, "Play Next" and "Add to
    /// Queue" would do the same thing, so only "Play Next" is shown.
    var queueHasItems: Bool = false
    /// When set, a drag handle appears on hover and the row accepts drops. nil
    /// disables reordering (e.g. while searching).
    /// Non-nil enables the drag handle. `isDragging` lifts this row while it's the
    /// one being dragged; the gesture callbacks report the cursor's y (in the
    /// "reorder" coordinate space) so the parent can reorder by pure math.
    var reorderID: String? = nil
    var isDragging: Bool = false
    /// True while any row in the list is being drag-reordered. Suppresses hover
    /// feedback on the other rows: during drag auto-scroll the list slides under
    /// a stationary cursor, and without this every passing row flashes its
    /// highlight and controls.
    var dragActive: Bool = false
    var onReorderChanged: (CGFloat) -> Void = { _ in }
    var onReorderEnded: () -> Void = {}
    /// "Add to Playlist ▸" submenu contents. Empty = the submenu is hidden.
    var addToPlaylists: [PlaylistMenuItem] = []
    /// "New Playlist…" action inside the add-to submenu; nil hides it.
    var onNewPlaylistWithTrack: (() -> Void)? = nil
    /// "Remove from Playlist" action — shown only when set (row is inside a
    /// playlist, not the main library).
    var onRemoveFromPlaylist: (() -> Void)? = nil
    /// Whether this track is favorited — drives the heart's filled/outline state.
    var isFavorite: Bool = false
    /// Toggle favorite. nil hides the heart entirely (e.g. contexts without a store).
    var onToggleFavorite: (() -> Void)? = nil
    /// Non-nil when this row is part of a multi-selection — swaps the context menu
    /// for selection-wide actions. The row's click/hover behaviour is unchanged.
    var bulk: BulkRowMenu? = nil
    private let accent = Theme.accent

    @State private var hovering = false

    /// Hover feedback, gated off while another row is being dragged (the dragged
    /// row itself keeps it so the handle stays visible under the cursor).
    private var hover: Bool { hovering && (!dragActive || isDragging) }

    var body: some View {
        HStack(spacing: 10) {
            // The note doubles as the favorite marker: pink on favorited rows.
            // The current track's note comes alive instead — the same dancing bars
            // as "Playing from", in accent, holding still while paused. "Playing"
            // outranks "favorited", and that row is already highlighted anyway.
            Group {
                if isCurrent {
                    NowPlayingBars(color: accent, animating: isPlaying)
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 10))
                        .foregroundStyle(isFavorite ? Theme.favorite : .white.opacity(0.4))
                }
            }
            .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.displayTitle)
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? .white : .white.opacity(0.85))
                    .lineLimit(1)
                if showArtist && !track.artist.isEmpty {
                    Text(track.artist)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            // Two overlaid layers, right-aligned, so the trailing edge is stable:
            //  • the duration, flush-right, shown at rest;
            //  • the hover controls — heart / trash / (drag, when reorderable) — as a
            //    single evenly-spaced group pinned to the far corner.
            // All three icons keep their slot at rest (only opacity changes), so the
            // heart never drifts, the spacing between the icons is uniform, and the
            // drag handle sits in the corner where the duration rests.
            ZStack(alignment: .trailing) {
                Text(durationText)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
                    .opacity(hover ? 0 : 1)
                HStack(spacing: 6) {
                    if let onToggleFavorite {
                        Button(action: onToggleFavorite) {
                            Image(systemName: isFavorite ? "heart.fill" : "heart")
                                .font(.system(size: 11))
                                .foregroundStyle(isFavorite ? Theme.favorite : .white.opacity(0.6))
                                .frame(width: 18, height: 20)
                        }
                        .buttonStyle(PressableButtonStyle())
                        .help(isFavorite ? "Remove from Favorites" : "Add to Favorites")
                        // Hover-only: at rest the pink note is the favorite marker.
                        .opacity(hover ? 1 : 0)
                        .allowsHitTesting(hover)
                    }
                    // Inside a playlist the row's quick action removes the entry
                    // from the list; the file itself can only be trashed from the
                    // Library (or the context menu's explicit Delete).
                    if let onRemoveFromPlaylist {
                        Button(action: onRemoveFromPlaylist) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.6))
                                .frame(width: 18, height: 20)
                        }
                        .buttonStyle(PressableButtonStyle())
                        .help("Remove from Playlist")
                        .opacity(hover ? 1 : 0)
                        .allowsHitTesting(hover)
                    } else {
                        Button(action: onDelete) {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                                .foregroundStyle(.red.opacity(0.9))
                                .frame(width: 18, height: 20)
                        }
                        .buttonStyle(PressableButtonStyle())
                        .help("Delete (move to Trash)")
                        .opacity(hover ? 1 : 0)
                        .allowsHitTesting(hover)
                    }
                    if reorderID != nil {
                        DragDots()
                            .foregroundStyle(.white.opacity(0.55))
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(coordinateSpace: .named("reorder"))
                                    .onChanged { onReorderChanged($0.location.y) }
                                    .onEnded { _ in onReorderEnded() }
                            )
                            .help("Drag to reorder")
                            .opacity(hover ? 1 : 0)
                            .allowsHitTesting(hover)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(background))
        .overlay(
            // A plain click-to-play shows no border on the playing row (its accent
            // fill already marks it, and that click also set `isSelected`). But a
            // deliberate selection — ⌘/⇧-click, ⌘A, arrow keys — outlines even the
            // playing row, else picking it gives no feedback.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected && (!isCurrent || selectionIsExplicit) ? accent.opacity(0.55) : .clear, lineWidth: 1.5)
        )
        .scaleEffect(isDragging ? 1.02 : 1)
        .shadow(color: isDragging ? .black.opacity(0.45) : .clear,
                radius: isDragging ? 8 : 0, y: isDragging ? 4 : 0)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onTap)
        .contextMenu { if let bulk { bulkMenu(bulk) } else { singleMenu } }
        .animation(.easeOut(duration: 0.12), value: hover)
    }

    /// The normal single-track context menu.
    @ViewBuilder private var singleMenu: some View {
        Button("Play", action: onTap)
        Button("Play Next", action: onPlayNext)
        if queueHasItems {
            Button("Add to Queue", action: onAddToQueue)
        }
        if let onToggleFavorite {
            Button(action: onToggleFavorite) {
                Label(isFavorite ? "Remove from Favorites" : "Add to Favorites",
                      systemImage: isFavorite ? "heart.slash" : "heart")
            }
        }
        if !addToPlaylists.isEmpty || onNewPlaylistWithTrack != nil {
            Menu("Add to Playlist") {
                ForEach(addToPlaylists) { item in
                    Button(action: item.add) {
                        if item.contains {
                            Label(item.name, systemImage: "checkmark")
                        } else {
                            Text(item.name)
                        }
                    }
                }
                if let onNewPlaylistWithTrack {
                    if !addToPlaylists.isEmpty { Divider() }
                    Button("New Playlist…", action: onNewPlaylistWithTrack)
                }
            }
        }
        Divider()
        Button { copyToClipboard(track.displayTitle) } label: {
            Label("Copy Title", systemImage: "doc.on.doc")
        }
        if !track.artist.isEmpty {
            Button { copyToClipboard(track.artist) } label: {
                Label("Copy Artist", systemImage: "person")
            }
        }
        if let youtubeURL = track.youtubeURL {
            Button { openInBrowser(youtubeURL) } label: {
                Label("Open on YouTube", systemImage: "arrow.up.forward.square")
            }
        }
        Divider()
        if let onRemoveFromPlaylist {
            Button("Remove from Playlist", role: .destructive, action: onRemoveFromPlaylist)
        }
        Button("Delete", role: .destructive, action: onDelete)
    }

    /// The multi-selection menu: every action applies to all selected tracks.
    @ViewBuilder private func bulkMenu(_ bulk: BulkRowMenu) -> some View {
        Button("Play Next (\(bulk.count))", action: bulk.onPlayNext)
        if queueHasItems {
            Button("Add \(bulk.count) to Queue", action: bulk.onAddToQueue)
        }
        if !bulk.allFavorited {
            Button { bulk.onFavorite() } label: {
                Label("Add \(bulk.count) to Favorites", systemImage: "heart")
            }
        }
        if bulk.anyFavorited {
            Button { bulk.onUnfavorite() } label: {
                Label("Remove from Favorites", systemImage: "heart.slash")
            }
        }
        if !bulk.addToPlaylists.isEmpty || bulk.onNewPlaylistWithSelection != nil {
            Menu("Add to Playlist") {
                ForEach(bulk.addToPlaylists) { item in
                    Button(item.name, action: item.add)
                }
                if let onNew = bulk.onNewPlaylistWithSelection {
                    if !bulk.addToPlaylists.isEmpty { Divider() }
                    Button("New Playlist…", action: onNew)
                }
            }
        }
        Divider()
        if let onRemove = bulk.onRemoveFromPlaylist {
            Button("Remove \(bulk.count) from Playlist", role: .destructive, action: onRemove)
        }
        Button("Delete \(bulk.count) Tracks", role: .destructive, action: bulk.onDelete)
    }

    private var background: Color {
        if isDragging { return Color(white: 0.16) }
        if isCurrent { return accent.opacity(0.16) }
        if isSelected { return .white.opacity(0.10) }
        return hover ? .white.opacity(0.07) : .clear
    }
}
