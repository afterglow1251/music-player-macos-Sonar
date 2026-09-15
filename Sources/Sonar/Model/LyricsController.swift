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

    private var track: Track?
    private var loadTask: Task<Void, Never>?
    private var loaded: LyricsSubject?
    private var clockSubscription: AnyCancellable?

    /// Follow the playback clock so a chaptered mix reloads lyrics as the section
    /// changes. Cheap: every tick only compares a chapter index; nothing is
    /// published unless the song actually changed.
    func follow(_ clock: PlaybackClock) {
        clockSubscription = clock.$currentTime.sink { [weak self] time in
            guard let self, let track, !track.chapters.isEmpty else { return }
            self.reload(for: track, at: time)
        }
    }

    /// Fetch lyrics for a track (or clear them for nil) at playback position
    /// `time` — which picks the chapter for a mix. No-op if the same song is
    /// already loaded, so seeking/pausing doesn't refetch.
    func load(for track: Track?, at time: TimeInterval = 0) {
        self.track = track
        guard let track else {
            loadTask?.cancel()
            loaded = nil
            lines = []
            state = .idle
            return
        }
        reload(for: track, at: time)
    }

    private func reload(for track: Track, at time: TimeInterval) {
        let subject = track.chapterIndex(at: time)
            .map { LyricsSubject(track: track, chapter: $0) } ?? LyricsSubject(track: track)
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
