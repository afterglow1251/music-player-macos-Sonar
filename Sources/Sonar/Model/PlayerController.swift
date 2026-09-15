import Foundation
import Combine
import AppKit

enum RepeatMode: Int {
    case off = 0, all, one
}

/// One entry in the play queue. The stable `id` lets the same track sit in the
/// queue more than once and keeps drag-reorder animations smooth.
struct QueueItem: Identifiable, Hashable {
    let id = UUID()
    var track: Track
}

enum SleepMode: Equatable {
    case off
    case timer(minutes: Int)
    case endOfTrack
}

/// The top-level coordinator the UI observes. Owns the audio engine, the music
/// library, the downloader and Now Playing; wires them together and persists
/// playback preferences between launches.
@MainActor
final class PlayerController: ObservableObject {
    /// The one player the whole app drives — shared by the main window and the
    /// menu-bar mini-player so they stay in lockstep (same engine, same queue).
    static let shared = PlayerController()

    let engine = AudioEngine()
    let library = MusicLibrary()
    let playlists = PlaylistStore()
    let favorites = FavoritesStore()
    let downloader = Downloader()
    let lyrics = LyricsController()
    let waveforms = WaveformStore()
    private let nowPlaying = NowPlayingController()

    @Published private(set) var currentTrack: Track? {
        didSet {
            if currentTrack?.url != oldValue?.url {
                lyrics.load(for: currentTrack, at: engine.currentTime)
                waveforms.load(for: currentTrack)
            }
            if currentTrack?.artworkData != oldValue?.artworkData { refreshAlbumTheme() }
        }
    }
    /// Which browse source the *currently loaded* track is playing from — nil for
    /// the library, else a playlist's id. Distinct from whatever source the user
    /// is browsing right now: start a playlist, scroll away to another, and this
    /// still points at the one that's actually playing, so the UI can mark it.
    /// Set only on user-initiated plays; auto next/previous keep the same source.
    @Published private(set) var playingSourceID: Playlist.ID?

    /// True while the current track came off the play queue. The source label
    /// keeps naming the underlying playlist/library (the queue is an overlay on it,
    /// not a new source), so this flags the "· from queue" note beside it.
    @Published private(set) var playingFromQueue = false
    @Published var urlInput: String = ""

    /// Tracks the user lined up to play next, overriding the normal library order.
    /// Ephemeral (not persisted) — like Winamp's play queue. Each entry has a
    /// stable id so the same track can appear twice and drag-reorder stays smooth.
    @Published private(set) var queue: [QueueItem] = []

    @Published var shuffle = false { didSet { resetShuffle(); save() } }
    @Published var repeatMode: RepeatMode = .off { didSet { save() } }
    @Published var themeIndex = 0 { didSet { save() } }

    /// When on, the visualizer tiles are tinted from the current cover instead of
    /// the fixed preset at `themeIndex`.
    @Published var albumTheme = true {
        didSet {
            if albumTheme { refreshAlbumTheme() }
            save()
        }
    }

    /// Theme derived from the current cover (nil when off, or the track has no
    /// cover at all). Cached so tiles don't re-decode the artwork every frame.
    @Published private(set) var derivedAlbumTheme: VisualizerTheme?

    var theme: VisualizerTheme {
        if albumTheme, let derived = derivedAlbumTheme { return derived }
        return VisualizerTheme.all[min(max(themeIndex, 0), VisualizerTheme.all.count - 1)]
    }

    func cycleTheme() {
        albumTheme = false
        themeIndex = (themeIndex + 1) % VisualizerTheme.all.count
    }

    /// Recompute the cover-derived theme. Cheap (downscales to 32×32), and only
    /// runs when album mode is on so idle covers don't burn cycles.
    private func refreshAlbumTheme() {
        guard albumTheme, let data = currentTrack?.artworkData,
              let image = NSImage(data: data) else {
            derivedAlbumTheme = nil
            return
        }
        derivedAlbumTheme = VisualizerTheme.fromArtwork(image)
    }
    func cycleRepeat() {
        repeatMode = RepeatMode(rawValue: (repeatMode.rawValue + 1) % 3) ?? .off
    }

    private var cancellables = Set<AnyCancellable>()
    private let prefs = Preferences()

    /// True only while `restorePreferences()` runs. Restoring one `@Published`
    /// (e.g. `shuffle`) fires its `didSet { save() }`, which would persist a
    /// half-restored snapshot — clobbering values not yet restored (the theme
    /// was being reset to Classic this way). Guarding `save()` prevents it.
    private var isRestoring = false

    init() {
        restorePreferences()

        engine.onFinished = { [weak self] in self?.next(auto: true) }
        lyrics.follow(engine.clock)

        // Gapless: the engine preloads the next track and, when it advances to it
        // seamlessly, asks us to reconcile state without a reload.
        engine.nextURLProvider = { [weak self] in self?.peekNextURL() }
        engine.onAdvanced = { [weak self] url in self?.commitAdvance(to: url) }

        // Media keys / Control Center → us.
        nowPlaying.onPlay = { [weak self] in self?.engine.play() }
        nowPlaying.onPause = { [weak self] in self?.engine.pause() }
        nowPlaying.onToggle = { [weak self] in self?.togglePlayPause() }
        nowPlaying.onNext = { [weak self] in self?.next() }
        nowPlaying.onPrevious = { [weak self] in self?.previous() }

        // Re-publish child changes so the view updates. The downloader is
        // deliberately NOT forwarded: it publishes progress/status on every
        // yt-dlp output line, and routing that through this controller
        // re-rendered every observer — the whole window, the menu-bar panel,
        // the status button — for the entire length of a download. Views that
        // show download state observe `downloader` directly instead.
        for child in [engine.objectWillChange, library.objectWillChange,
                      playlists.objectWillChange, favorites.objectWillChange,
                      lyrics.objectWillChange] {
            child.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        }

        // Follow the library to whatever folder it's pointed at — including a rename
        // it picked up on its own. `dropFirst` because this is about *changes*: both
        // stores resolve the same folder at init, so the initial value is already
        // in effect and re-applying it would reset a context restoreLastTrack built.
        library.$folder
            .dropFirst()
            .sink { [weak self] folder in self?.libraryFolderChanged(to: folder) }
            .store(in: &cancellables)

        // When the library rescans (e.g. a download finished writing its tags and
        // artwork), refresh the now-playing track so its cover/title/duration
        // update on their own — without needing a re-play.
        library.$tracks
            .sink { [weak self] tracks in
                guard let self, let current = self.currentTrack,
                      let updated = tracks.first(where: { $0.url == current.url }) else { return }
                if updated.artworkData != current.artworkData
                    || updated.title != current.title
                    || updated.duration != current.duration {
                    self.currentTrack = updated
                    self.updateNowPlaying()
                }
            }
            .store(in: &cancellables)

        // Keep Now Playing in sync with play/pause, and remember the position
        // whenever playback pauses/resumes/stops (cheap, no timer).
        engine.$isPlaying
            .dropFirst()
            .sink { [weak self] _ in
                self?.updateNowPlaying()
                self?.save()
            }
            .store(in: &cancellables)

        // Persist volume / EQ shortly after the user stops adjusting them.
        engine.$volume.dropFirst().debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.save() }.store(in: &cancellables)
        engine.$eqGains.dropFirst().debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.save() }.store(in: &cancellables)
        engine.$eqEnabled.dropFirst().sink { [weak self] _ in self?.save() }.store(in: &cancellables)

        // When the library first loads, restore the last-played track (paused).
        library.$tracks.filter { !$0.isEmpty }.first()
            .sink { [weak self] tracks in self?.restoreLastTrack(from: tracks) }
            .store(in: &cancellables)

        // Persist the position every few seconds while playing, so it survives
        // any kind of close (⌘Q, crash, kill) without a per-frame cost.
        persistTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.engine.isPlaying else { return }
                self.save()
            }
        }
    }

    private var persistTimer: Timer?

    // MARK: Playback

    // MARK: - Playback spine
    //
    // Two layers. The *context* is the source you're playing through (a playlist or
    // the library) with a position — it generates new tracks when you reach the
    // front. The *history* is the linear record of what actually played; ⏮ / ⏭ walk
    // it, replaying queued interjections and all. The context is frozen while a
    // queued track plays or while you retrace, so the source survives both.

    /// The linear play record — the spine of ⏮ / ⏭. Its `current` entry drives
    /// every UI mirror (`currentTrack`, `playingSourceID`, `playingFromQueue`), so
    /// the label can never disagree with what's playing.
    private var history = PlayHistory()

    /// The context list forward generation walks (a playlist's tracks, or the
    /// library). Frozen while a queued track plays / while retracing.
    private var scope: [Track] = []

    /// The source id (nil = library) that *newly generated* context tracks get
    /// stamped with. The label reads the current history entry's source, not this.
    private var liveSourceID: Playlist.ID?

    /// The context's linear position — the last context (non-queue) track. When the
    /// queue drains, generation resumes from here so the playlist carries on instead
    /// of stranding us on the off-scope queued track. Frozen while queued tracks chain.
    private var resumeAnchor: Track?

    // Shuffle only needs the "bag" now (every track plays once before any repeat);
    // the played order it used to track lives in `history`, shared with linear mode.
    private var shuffleBag: [Track] = []       // upcoming this cycle, pre-shuffled
    private var shuffleUniverse: [Track] = []  // the list the bag was built from

    /// Tracks that next/previous walk through: the active scope if it still holds
    /// Publish the current history entry to the UI mirrors and load it into the
    /// engine. The single funnel every play / retrace goes through, so the label
    /// (`playingSourceID` + `playingFromQueue`) always matches what's audible.
    private func activateCurrentEntry() {
        guard let entry = history.current else { return }
        playingSourceID = entry.sourceID
        playingFromQueue = entry.fromQueue
        currentTrack = entry.track
        engine.load(url: entry.track.url)
        updateNowPlaying()
        save()
    }

    /// Record a freshly-chosen track as the new head of history and play it. A
    /// queued interjection freezes the context (scope / anchor / bag untouched); a
    /// context track advances the linear anchor.
    private func playNewEntry(_ track: Track, fromQueue: Bool) {
        if !fromQueue { resumeAnchor = track }
        history.push(PlayHistoryEntry(track: track, sourceID: liveSourceID, fromQueue: fromQueue))
        activateCurrentEntry()
    }

    /// A user-initiated play from a browse source — the start of a fresh context.
    /// Records the source for forward generation and the label, reseeds shuffle, and
    /// forks a new head in the history.
    func play(_ track: Track, from source: Playlist.ID?, in scope: [Track]?) {
        let list = scope ?? library.tracks
        self.scope = list
        liveSourceID = source
        reseedShuffle(for: list, avoiding: track)
        playNewEntry(track, fromQueue: false)
    }

    /// Play a whole group (playlist / artist section) as a new context, from its
    /// first track.
    func playGroup(_ tracks: [Track], from source: Playlist.ID?) {
        guard let first = tracks.first else { return }
        play(first, from: source, in: tracks)
    }

    /// Play/pause. If nothing is loaded yet, start the first track in the library.
    func togglePlayPause() {
        if currentTrack == nil {
            if let first = library.tracks.first { play(first, from: nil, in: library.tracks) }
            return
        }
        engine.togglePlayPause()
    }

    func next(auto: Bool = false) {
        // Repeat-one replays the current track in place — no history churn.
        if auto, repeatMode == .one, currentTrack != nil {
            engine.seek(to: 0); engine.play(); return
        }
        // Sleep "until end of track" fires here (auto-advance only): the track just
        // ended, so clear the timer and stop rather than advance.
        if auto, sleepMode == .endOfTrack { setSleep(.off); return }
        // Retrace forward through what already played before generating anything new.
        if !history.atHead {
            _ = history.stepForward()
            activateCurrentEntry()
            return
        }
        generateNext(auto: auto)
    }

    /// Generate and play the next track when we're at the head of history: the queue
    /// overrides, otherwise walk the context (playlist / library / shuffle).
    private func generateNext(auto: Bool) {
        let decision = PlaybackSequencer.nextDecision(
            auto: auto, current: currentTrack, library: library.tracks, scope: scope,
            queueFront: queue.first?.track, resumeAnchor: resumeAnchor, shuffle: shuffle,
            repeatMode: repeatMode, sleepUntilEndOfTrack: false)
        switch decision {
        case .none, .stopForSleep:
            return
        case .stopAtEnd:
            engine.stop()
        case .play(let track, _, let fromQueue):
            if fromQueue { queue.removeFirst() }
            playNewEntry(track, fromQueue: fromQueue)
        case .playRandom(let list, _, _):
            playNewEntry(nextShuffleTrack(in: list), fromQueue: false)
        }
    }

    func previous() {
        // >3s in: restart the current track (standard transport feel).
        if engine.currentTime > 3 { engine.seek(to: 0); return }
        // Otherwise step back through the real play history — queued tracks included.
        guard history.canStepBack else { engine.seek(to: 0); return }
        _ = history.stepBack()
        activateCurrentEntry()
    }

    /// The URL that will play next, WITHOUT side effects — the engine preloads it
    /// for a gapless join. Only at the head (retrace reloads); nil when playback
    /// should stop or the pick isn't gapless (shuffle draws at advance, repeat-one
    /// and end-of-track sleep loop / stop in place).
    private func peekNextURL() -> URL? {
        guard history.atHead, repeatMode != .one, sleepMode != .endOfTrack else { return nil }
        let decision = PlaybackSequencer.nextDecision(
            auto: true, current: currentTrack, library: library.tracks, scope: scope,
            queueFront: queue.first?.track, resumeAnchor: resumeAnchor, shuffle: shuffle,
            repeatMode: repeatMode, sleepUntilEndOfTrack: false)
        if case .play(let track, _, _) = decision { return track.url }
        return nil
    }

    /// Reconcile our state to a track the engine already advanced to gaplessly — no
    /// reload, the audio is flowing. Mirrors `generateNext` minus the engine work;
    /// only ever fires for a head-of-history generated track (see `peekNextURL`).
    private func commitAdvance(to url: URL) {
        guard let track = library.tracks.first(where: { $0.url == url }) else { return }
        let fromQueue = (queue.first?.track.url == url)
        if fromQueue { queue.removeFirst() } else { resumeAnchor = track }
        history.push(PlayHistoryEntry(track: track, sourceID: liveSourceID, fromQueue: fromQueue))
        playingSourceID = liveSourceID
        playingFromQueue = fromQueue
        currentTrack = track
        updateNowPlaying()
        save()
    }

    func delete(_ track: Track) {
        guard library.delete(track) else {
            downloader.lastError = "Couldn't move \(track.title) to the Trash"
            return
        }
        if currentTrack == track {
            engine.stop()
            currentTrack = nil
            updateNowPlaying()
        }
        queue.removeAll { $0.track == track }
        history.remove { $0.track == track }
    }

    /// Delete several tracks (multi-select). Each goes through the same failure-
    /// aware path as the single delete: a track whose Trash move fails stays in the
    /// library, and the toast reports how many couldn't be trashed.
    func delete(_ tracks: [Track]) {
        var failed = 0
        var stoppedCurrent = false
        for track in tracks {
            guard library.delete(track) else { failed += 1; continue }
            if currentTrack == track {
                engine.stop()
                currentTrack = nil
                stoppedCurrent = true
            }
            queue.removeAll { $0.track == track }
            history.remove { $0.track == track }
        }
        if stoppedCurrent { updateNowPlaying() }
        if failed > 0 {
            downloader.lastError = "Couldn't move \(failed) track\(failed == 1 ? "" : "s") to the Trash"
        }
    }

    // MARK: Queue

    /// Insert a track at the front of the queue — it plays right after the current one.
    func playNext(_ track: Track) { queue.insert(QueueItem(track: track), at: 0) }

    /// Queue several tracks to play next, preserving their order (multi-select).
    func playNext(_ tracks: [Track]) {
        queue.insert(contentsOf: tracks.map { QueueItem(track: $0) }, at: 0)
    }

    /// Append a track to the end of the queue.
    func addToQueue(_ track: Track) { queue.append(QueueItem(track: track)) }

    /// Append several tracks to the queue, in order (multi-select).
    func addToQueue(_ tracks: [Track]) {
        queue.append(contentsOf: tracks.map { QueueItem(track: $0) })
    }

    func removeFromQueue(_ item: QueueItem) { queue.removeAll { $0.id == item.id } }

    /// Gesture reorder: move the queued item with `id` to `index` (queue is
    /// ephemeral, so there's nothing to persist).
    func reorderQueue(id: UUID, toIndex index: Int) {
        guard let from = queue.firstIndex(where: { $0.id == id }) else { return }
        let item = queue.remove(at: from)
        queue.insert(item, at: min(max(index, 0), queue.count))
    }

    func clearQueue() { queue.removeAll() }

    // MARK: Favorites

    func isFavorite(_ track: Track) -> Bool { favorites.isFavorite(track.url.path) }

    func toggleFavorite(_ track: Track) { favorites.toggle(track.url.path) }

    /// Favorite or unfavorite a set of tracks at once (multi-select).
    func setFavorite(_ tracks: [Track], to favorite: Bool) {
        favorites.setFavorite(Set(tracks.map { $0.url.path }), to: favorite)
    }

    // MARK: Library folder

    /// The library was pointed at a different folder. Playlists follow it, and the
    /// listening session built out of the old folder ends here.
    ///
    /// What plays right now is deliberately left alone — swapping a setting
    /// shouldn't cut a song off mid-bar, and the engine holds its own open file, so
    /// it plays on happily. Everything that would *generate* from the old folder is
    /// dropped instead, so the next track comes from the folder you actually have
    /// on screen. Without this the scope — a frozen snapshot array, not a live view
    /// of the library — still contains the current track, so ⏭ would walk you
    /// deeper into a folder with no rows to show for it.
    private func libraryFolderChanged(to folder: URL) {
        playlists.setFolder(folder)
        favorites.setFolder(folder)

        // Each of these points into the folder we just left: the walk list, the
        // anchor parked in it, tracks lined up off it, and the retrace trail.
        scope = []
        resumeAnchor = nil
        liveSourceID = nil
        resetShuffle()
        queue.removeAll()

        // Keep the audible track as history's sole entry: ⏮ needs a valid head, and
        // anything behind it is in the old folder. Its source label goes with it —
        // the playlist it came from isn't on screen any more either.
        if let current = currentTrack {
            history.reset(to: PlayHistoryEntry(track: current, sourceID: nil, fromQueue: false))
            playingSourceID = nil
            playingFromQueue = false
        }
    }

    // MARK: Playlists

    /// Resolve a playlist's stored paths to real library tracks, in playlist
    /// order, skipping any file that's no longer in the library.
    func tracks(in playlist: Playlist) -> [Track] {
        let byPath = Dictionary(library.tracks.map { ($0.url.path, $0) },
                                uniquingKeysWith: { first, _ in first })
        return playlist.trackPaths.compactMap { byPath[$0] }
    }

    /// Play a playlist from its first track, as the new scope.
    func playPlaylist(_ playlist: Playlist) {
        playGroup(tracks(in: playlist), from: playlist.id)
    }

    /// Queue a whole playlist to play right after the current track, in playlist
    /// order. A snapshot: later edits to the playlist don't touch the queue.
    func playNext(_ playlist: Playlist) { playNext(tracks(in: playlist)) }

    /// Append a whole playlist to the end of the queue, in playlist order. Also
    /// a snapshot — see `playNext(_:)`.
    func addToQueue(_ playlist: Playlist) { addToQueue(tracks(in: playlist)) }

    /// Snapshot the current queue into a new playlist. Returns nil if the queue
    /// is empty (nothing to save).
    @discardableResult
    func saveQueueAsPlaylist() -> Playlist? {
        guard !queue.isEmpty else { return nil }
        let playlist = playlists.create()
        for item in queue { playlists.add(path: item.track.url.path, to: playlist.id) }
        return playlist
    }

    // MARK: Shuffle bag

    /// Next track under shuffle — draw from the bag, refilling + reshuffling it when
    /// empty so every track plays once before any repeat. The *played order* lives
    /// in `history` now (shared with linear mode), so ⏮ / ⏭ retrace happens there,
    /// not here.
    private func nextShuffleTrack(in list: [Track]) -> Track {
        reseedShuffleIfNeeded(for: list)
        if shuffleBag.isEmpty { refillShuffleBag(avoiding: currentTrack) }
        return shuffleBag.popLast() ?? currentTrack ?? list[0]
    }

    /// Reseed the bag for a brand-new context (a user pick / group play), excluding
    /// the track about to play. No-op when shuffle is off — the bag reseeds lazily
    /// on the first shuffle generation instead.
    private func reseedShuffle(for list: [Track], avoiding: Track?) {
        guard shuffle else { return }
        shuffleUniverse = list
        refillShuffleBag(avoiding: avoiding)
    }

    /// Rebuild the bag when the shuffle universe (the list we walk) changes — e.g.
    /// switching from the library to a playlist, or shuffle toggled back on.
    private func reseedShuffleIfNeeded(for list: [Track]) {
        guard shuffleUniverse != list else { return }
        shuffleUniverse = list
        refillShuffleBag(avoiding: currentTrack)
    }

    private func refillShuffleBag(avoiding: Track?) {
        shuffleBag = shuffleUniverse.filter { $0 != avoiding }.shuffled()
    }

    /// Drop the shuffle bag — toggling shuffle re-seeds from the next generation.
    /// The play history is left alone; it's the record of what played, not shuffle
    /// state, so ⏮ still retraces across a shuffle toggle.
    private func resetShuffle() {
        shuffleBag = []
        shuffleUniverse = []
    }

    // MARK: EQ

    func applyEQPreset(_ preset: EQPreset) {
        engine.eqGains = preset.gains
        save()
    }

    // MARK: Download

    /// One URL sitting in the download queue, staying put (and visible as a chip)
    /// for its whole lifetime — added on submit, removed only once it finishes.
    struct DownloadItem: Identifiable, Equatable {
        let id = UUID()
        let url: String
    }

    /// Everything waiting to download, including the one currently in flight
    /// (always `downloadQueue.first` while `isProcessingDownloads`). Downloads
    /// run one at a time; an item is removed only when its own download ends.
    @Published private(set) var downloadQueue: [DownloadItem] = []
    private var isProcessingDownloads = false

    var downloadsLeft: Int { downloadQueue.count }

    /// The item currently being downloaded, if any — the UI uses this to lock
    /// its chip against removal while the item's own download is in flight.
    var currentDownloadID: DownloadItem.ID? {
        isProcessingDownloads ? downloadQueue.first?.id : nil
    }

    func downloadFromInput() { download(urlInput) }

    /// Enqueue one or many URLs (paste several separated by spaces/newlines).
    /// URLs already queued (or mid-download) are skipped so the same link can't
    /// be queued twice back-to-back.
    func download(_ text: String) {
        var seen = Set(downloadQueue.map(\.url))
        let urls = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map(String.init)
            .filter { $0.contains("http") }
        var newItems: [DownloadItem] = []
        var skippedOwned = false
        for url in urls {
            if isAlreadyDownloaded(url) { skippedOwned = true; continue }  // instant, no network
            guard seen.insert(url).inserted else { continue }
            newItems.append(DownloadItem(url: url))
        }
        if skippedOwned { downloader.notice = "Already in library" }
        urlInput = ""
        guard !newItems.isEmpty else { return }
        downloadQueue.append(contentsOf: newItems)
        processDownloads()
    }

    /// Instant, no-network check: is this URL's video already in the library?
    /// Only decides for URLs whose id we can parse locally; anything else returns
    /// false here and is resolved for real at download time.
    func isAlreadyDownloaded(_ url: String) -> Bool {
        guard let id = Track.youtubeID(from: url) else { return false }
        return library.tracks.contains { $0.videoID == id }
    }

    /// Is this exact URL already sitting in the download queue (submitted, waiting
    /// or mid-download)? The staging UI combines this with its own not-yet-submitted
    /// chips to decide "shake the existing chip" vs "stage a new one".
    func isQueued(_ url: String) -> Bool {
        downloadQueue.contains { $0.url == url }
    }

    private func processDownloads() {
        guard !isProcessingDownloads, let next = downloadQueue.first else { return }
        isProcessingDownloads = true
        Task {
            await runDownload(next.url)
            downloadQueue.removeAll { $0.id == next.id }
            isProcessingDownloads = false
            processDownloads()          // next in the queue
        }
    }

    private func runDownload(_ url: String) async {
        // Skip if we already have this exact video (matched by its id).
        downloader.beginChecking()
        // Dedupe with the locally-parsed id first; only ask yt-dlp when we can't
        // parse the URL ourselves.
        var videoID = Track.youtubeID(from: url)
        if videoID == nil { videoID = await downloader.fetchVideoID(url) }
        if let videoID, library.tracks.contains(where: { $0.videoID == videoID }) {
            downloader.finishChecking(message: "Already in library")
            downloader.notice = "Already in library"   // surfaced as a toast
            return
        }
        // Stage the download in a hidden dir the watcher never sees, so a
        // half-written file can never appear as a (deletable, race-prone) row.
        // The finished file is adopted into the library; staging is discarded on
        // every exit path — cancel, failure, adopt failure, and success.
        guard let stagingDir = library.makeStagingDir() else {
            downloader.lastError = "Couldn't prepare download"
            return
        }
        guard let fileURL = await downloader.download(url, into: stagingDir) else {
            library.discardStaging(stagingDir)
            return
        }
        // Just add it to the library — don't hijack whatever is currently playing.
        guard await library.adopt(fileURL) != nil else {
            downloader.lastError = "Couldn't add to library"
            library.discardStaging(stagingDir)
            return
        }
        library.discardStaging(stagingDir)
        downloader.notice = "Added to library"          // success toast
    }

    /// Import audio files already on disk (Open File / drag-drop) into the library.
    /// Mirrors a download: add each to the library and surface an "Added" toast,
    /// without hijacking whatever is currently playing.
    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task { @MainActor in
            for url in urls { await library.add(url) }
            downloader.notice = urls.count == 1 ? "Added to library" : "Added \(urls.count) to library"
        }
    }

    /// Drop one queued (not-yet-started) item. No-op for the active download —
    /// use `cancelDownload()` to stop that.
    func removeFromQueue(_ id: DownloadItem.ID) {
        guard id != currentDownloadID else { return }
        downloadQueue.removeAll { $0.id == id }
    }

    /// Cancel the current download and clear the whole queue.
    func cancelDownload() {
        downloadQueue.removeAll()
        downloader.cancel()
    }

    // MARK: Now Playing

    private func updateNowPlaying() {
        nowPlaying.update(track: currentTrack,
                          isPlaying: engine.isPlaying,
                          elapsed: engine.currentTime,
                          duration: engine.duration)
    }

    // MARK: Persistence

    /// Persist everything now — called on quit so an in-progress track's
    /// position is remembered even if it never paused.
    func saveOnQuit() { save() }

    private func save() {
        guard !isRestoring else { return }
        prefs.volume = engine.volume
        prefs.eqGains = engine.eqGains
        prefs.eqEnabled = engine.eqEnabled
        prefs.shuffle = shuffle
        prefs.repeatMode = repeatMode
        prefs.themeName = VisualizerTheme.all[min(max(themeIndex, 0), VisualizerTheme.all.count - 1)].name
        prefs.albumTheme = albumTheme
        // Only touch the last track/position when something is actually loaded —
        // otherwise a save while idle would wipe the value we want to restore.
        if let track = currentTrack {
            prefs.lastTrack = track.url.path
            prefs.lastPosition = engine.currentTime
        }
    }

    private func restorePreferences() {
        isRestoring = true
        defer { isRestoring = false }
        if let volume = prefs.volume { engine.volume = volume }
        if let gains = prefs.eqGains, gains.count == 10 { engine.eqGains = gains }
        engine.eqEnabled = prefs.eqEnabled ?? true
        shuffle = prefs.shuffle
        repeatMode = prefs.repeatMode
        if let name = prefs.themeName,
           let index = VisualizerTheme.all.firstIndex(where: { $0.name == name }) {
            themeIndex = index
        }
        albumTheme = prefs.albumTheme ?? true
    }

    private func restoreLastTrack(from tracks: [Track]) {
        guard currentTrack == nil,
              let path = prefs.lastTrack,
              let track = tracks.first(where: { $0.url.path == path }) else { return }
        // Read the saved position BEFORE loading — engine.load() calls stop(),
        // which resets currentTime to 0 and would clobber the stored value.
        let position = prefs.lastPosition
        // Adopt the restored track as the context + the sole history entry, so ⏮/⏭
        // and forward generation have a valid starting point. Source isn't persisted,
        // so it restores as the library.
        scope = library.tracks
        liveSourceID = nil
        resumeAnchor = track
        history.reset(to: PlayHistoryEntry(track: track, sourceID: nil, fromQueue: false))
        currentTrack = track
        engine.load(url: track.url, autoplay: false)
        if position > 1 { engine.seek(to: position) }
        updateNowPlaying()
    }

    // MARK: Seek & volume (keyboard)

    func seekBy(_ delta: TimeInterval) {
        guard engine.duration > 0 else { return }
        engine.seek(to: min(max(engine.currentTime + delta, 0), engine.duration))
    }

    func adjustVolume(_ delta: Float) {
        engine.volume = min(max(engine.volume + delta, 0), 1)
    }

    // MARK: Sleep timer

    @Published private(set) var sleepMode: SleepMode = .off
    @Published private(set) var sleepRemaining: TimeInterval?  // seconds left (timer mode)
    private var sleepEndDate: Date?
    private var sleepStopTimer: Timer?     // single precise fire that performs the stop
    private var sleepDisplayTimer: Timer?  // 1 Hz UI-only tick; recomputes sleepRemaining from sleepEndDate

    func setSleep(_ mode: SleepMode) {
        sleepStopTimer?.invalidate()
        sleepStopTimer = nil
        sleepDisplayTimer?.invalidate()
        sleepDisplayTimer = nil
        sleepEndDate = nil
        sleepMode = mode
        switch mode {
        case .off, .endOfTrack:
            sleepRemaining = nil
        case .timer(let minutes):
            let interval = TimeInterval(max(1, minutes) * 60)
            let endDate = Date().addingTimeInterval(interval)
            sleepEndDate = endDate
            sleepRemaining = interval

            let stopTimer = Timer(fire: endDate, interval: 0, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.fireSleepStop() }
            }
            RunLoop.main.add(stopTimer, forMode: .common)
            sleepStopTimer = stopTimer

            sleepDisplayTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tickSleepDisplay() }
            }
        }
    }

    private func tickSleepDisplay() {
        guard let endDate = sleepEndDate else { return }
        sleepRemaining = max(0, endDate.timeIntervalSinceNow)
    }

    private func fireSleepStop() {
        engine.pause()
        setSleep(.off)
    }
}
