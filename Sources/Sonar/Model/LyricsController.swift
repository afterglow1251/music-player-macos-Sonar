import Foundation
import Combine

/// Holds the synced lyrics for whatever's playing, fetching them (local `.lrc`
/// first, then LRCLIB) whenever the song changes.
///
/// For a plain file the song is the track. For a chaptered mix (a DJ set, a
/// mashup compilation) each chapter is its own song, so the controller follows the
/// playback clock and swaps lyrics as playback crosses into the next chapter —
/// looking each one up by its chapter title, with timestamps shifted to the
/// chapter's start so they line up with the file's clock.
@MainActor
final class LyricsController: ObservableObject {
    enum State: Equatable {
        case idle          // nothing playing
        case loading       // cache miss — searching the network, spinner warranted
        case loaded
        case unavailable   // looked, found none
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lines: [LyricLine] = []
    /// Karaoke granularity, remembered across launches.
    @Published var fill: KaraokeFill = Preferences().karaokeFill {
        didSet { Preferences().karaokeFill = fill }
    }

    private var track: Track?
    private var loadTask: Task<Void, Never>?
    private var loaded: LyricsSubject?
    private var clockSubscription: AnyCancellable?

    /// The chapter whose lyrics are being fetched ahead of time (see `prefetch`),
    /// so one approaching boundary triggers one request, not one per tick.
    private var prefetching: LyricsSubject?
    private var prefetchTask: Task<Void, Never>?
    /// How far ahead of a chapter boundary the next chapter's lyrics are fetched.
    private static let prefetchLead: TimeInterval = 15

    /// Follow the playback clock so a chaptered mix reloads lyrics as the section
    /// changes. Cheap: every tick only compares a chapter index; nothing is
    /// published unless the song actually changed.
    func follow(_ clock: PlaybackClock) {
        clockSubscription = clock.$currentTime.sink { [weak self] time in
            guard let self, let track, !track.chapters.isEmpty else { return }
            self.reload(for: track, at: time)
            self.prefetch(for: track, at: time)
        }
    }

    /// Warm the on-disk cache for the chapter after the one playing, once its
    /// start is within `prefetchLead` seconds. Then the actual switch is a
    /// synchronous cache hit: the new song's lines are on screen — and highlighting
    /// from its first line — the moment the boundary passes, with no spinner and no
    /// network round-trip eating into the song.
    private func prefetch(for track: Track, at time: TimeInterval) {
        guard let current = track.chapterIndex(at: time) else { return }
        let next = current + 1
        guard next < track.chapters.count,
              track.chapters[next].start - time <= Self.prefetchLead else { return }
        let subject = LyricsSubject(track: track, chapter: next)
        guard subject != prefetching, subject != loaded,
              !subject.title.trimmingCharacters(in: .whitespaces).isEmpty,
              LyricsProvider.cached(for: subject) == nil else { return }

        prefetchTask?.cancel()
        prefetching = subject
        prefetchTask = Task { [weak self] in
            // fetchRemote writes the cache itself; nothing to publish here. If the
            // boundary passes before this lands, `reload`'s own fetch takes over.
            _ = await LyricsProvider.fetchRemote(for: subject)
            guard !Task.isCancelled, let self, self.prefetching == subject else { return }
            self.prefetching = nil
        }
    }

    /// Fetch lyrics for a track (or clear them for nil) at playback position
    /// `time` — which picks the chapter for a mix. No-op if the same song is
    /// already loaded, so seeking/pausing doesn't refetch.
    func load(for track: Track?, at time: TimeInterval = 0) {
        self.track = track
        guard let track else {
            loadTask?.cancel()
            prefetchTask?.cancel()
            prefetching = nil
            loaded = nil
            lines = []
            state = .idle
            return
        }
        reload(for: track, at: time)
    }

    /// Use a user-picked `.lrc` file for the song playing at `time` (the current
    /// chapter, in a mix) and show it right away. Throws
    /// `LyricsProvider.ImportError` if the file can't be read or isn't synced.
    func importLyrics(from file: URL, at time: TimeInterval) throws {
        guard let track else { return }
        let subject = Self.subject(for: track, at: time)
        show(try LyricsProvider.importFile(file, for: subject), for: subject)
    }

    /// Same, from a pasted link (downloaded first — see `LyricsProvider.importLink`).
    func importLyrics(fromLink link: URL, at time: TimeInterval) async throws {
        guard let track else { return }
        let subject = Self.subject(for: track, at: time)
        show(try await LyricsProvider.importLink(link, for: subject), for: subject)
    }

    /// Whether the lyrics on screen already carry per-word timing (karaoke).
    var hasWordTimings: Bool { lines.contains { !$0.words.isEmpty } }
    /// …and real per-letter timing too — what the Letters fill needs.
    var hasLetterTimings: Bool { lines.contains { $0.words.contains { !$0.letters.isEmpty } } }

    /// How much audio a sync at `time` would send — the chapter's length in a
    /// mix, else the whole track's. Nil with nothing loaded.
    func syncDuration(at time: TimeInterval) -> TimeInterval? {
        track.map { Self.subject(for: $0, at: time).duration }
    }

    /// Time the song playing at `time` word by word through ElevenLabs and show the
    /// result. Uses the best text there is: the lyrics already on screen (their
    /// line times are kept as a fallback), else LRCLIB's plain lyrics, else none —
    /// ElevenLabs then transcribes the song itself. Throws
    /// `ElevenLabsSync.Failure` or a cache-write error.
    func syncWords(at time: TimeInterval) async throws {
        guard let track else { return }
        let subject = Self.subject(for: track, at: time)
        var source: [ElevenLabsSync.SourceLine]
        if loaded == subject, state == .loaded, !lines.isEmpty {
            source = lines.map { .init(text: $0.text, time: $0.time - subject.offset) }
        } else if let plain = await LyricsProvider.fetchPlainText(for: subject) {
            source = plain.split(separator: "\n", omittingEmptySubsequences: false).map {
                .init(text: $0.trimmingCharacters(in: .whitespaces), time: nil)
            }
        } else {
            source = []
        }
        let timed = try await ElevenLabsSync.timedLyrics(for: subject, lines: source)
        try Task.checkCancellation()   // cancelled while it was in flight: keep nothing
        show(try LyricsProvider.install(timed.lrc, for: subject, letters: timed.letters), for: subject)
    }

    /// Put freshly imported lines on screen — unless playback moved on to another
    /// song (or chapter) while they downloaded; they're cached for it either way.
    private func show(_ imported: [LyricLine], for subject: LyricsSubject) {
        guard loaded == subject else { return }
        loadTask?.cancel()
        lines = imported
        state = .loaded
    }

    private static func subject(for track: Track, at time: TimeInterval) -> LyricsSubject {
        track.chapterIndex(at: time)
            .map { LyricsSubject(track: track, chapter: $0) } ?? LyricsSubject(track: track)
    }

    private func reload(for track: Track, at time: TimeInterval) {
        let subject = Self.subject(for: track, at: time)
        guard subject != loaded else { return }

        loadTask?.cancel()
        loaded = subject

        // An untitled chapter names nothing to search for.
        if subject.chapterIndex != nil, subject.title.trimmingCharacters(in: .whitespaces).isEmpty {
            lines = []
            state = .unavailable
            return
        }

        // Cache first — a fast synchronous local read. On a hit the lyrics appear in
        // the same update as the song change: no spinner, no flash, and the previous
        // song's text is replaced outright rather than lingering. Most switches hit
        // this path (a song played once is cached beside its file).
        if let cached = LyricsProvider.cached(for: subject) {
            lines = cached
            state = .loaded
            return
        }

        // Cache miss → we actually have to search the network, so the spinner is
        // honest here (not a one-frame blink on an instant cached load).
        lines = []
        state = .loading
        loadTask = Task { [weak self] in
            let fetched = await LyricsProvider.fetchRemote(for: subject)
            guard !Task.isCancelled, let self, self.loaded == subject else { return }
            if let fetched {
                self.lines = fetched
                self.state = .loaded
            } else {
                self.state = .unavailable
            }
        }
    }

    /// The line active at `time`, or nil before the first line / when empty.
    func activeIndex(at time: TimeInterval) -> Int? {
        LyricsProvider.activeIndex(in: lines, at: time)
    }
}
