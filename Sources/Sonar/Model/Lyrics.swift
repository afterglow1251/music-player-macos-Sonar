import Foundation

/// One timestamped line of a synced lyric.
struct LyricLine: Identifiable, Hashable {
    let id = UUID()
    let time: TimeInterval   // seconds from the start of the track
    let text: String
    /// Per-word timing, when the LRC is "Enhanced" (`<mm:ss.xx>` before each
    /// word) — drives the karaoke fill across the active line. Empty for a
    /// plain line-synced LRC, which highlights the line as a whole.
    var words: [LyricWord] = []
}

/// One word of an Enhanced-LRC line and when it's sung.
struct LyricWord: Hashable {
    let time: TimeInterval
    let text: String
    /// When each of `text`'s characters is sung — real per-letter timing from
    /// ElevenLabs, kept beside the LRC (which can only hold word times). Empty
    /// when there's none; one entry per `Character` of `text` otherwise.
    var letters: [TimeInterval] = []
}

/// The song a lyrics lookup is about. Usually the whole file, but for a chaptered
/// mix (a DJ set, a mashup compilation) each chapter is its own song: the file's
/// title names the mix, so only the chapter title can find the right lyrics.
struct LyricsSubject: Hashable, Sendable {
    /// The audio file the lyrics belong to (keys the on-disk cache).
    let url: URL
    /// Which chapter of the file, or nil for the file as a whole.
    let chapterIndex: Int?
    /// What we know about the song: its (display) title, artist tag, and length.
    let title: String
    let artist: String
    let duration: TimeInterval
    /// Seconds into the file where this song starts — lyric timestamps are shifted
    /// by this much so they line up with the file's clock. 0 for a whole file.
    let offset: TimeInterval
    /// Whether the length is the song's own. A chapter's span in a mix is only a
    /// rough guide (songs get cut short or extended), so the strict duration match
    /// is relaxed for it.
    let strictDuration: Bool
    /// Whether the title may read "Song - Artist" as well as "Artist - Title".
    /// Chapter names in a mix come in either order.
    let eitherDashOrder: Bool

    /// The whole file as one song.
    init(track: Track) {
        url = track.url
        chapterIndex = nil
        title = track.displayTitle
        artist = track.artist
        duration = track.duration
        offset = 0
        strictDuration = true
        eitherDashOrder = false
    }

    /// One chapter of a mix. The file's artist tag is deliberately dropped: on a
    /// DJ set it names the DJ or the channel, not whoever sang this song.
    init(track: Track, chapter index: Int) {
        url = track.url
        chapterIndex = index
        title = track.chapters[index].title
        artist = ""
        duration = track.chapterDuration(at: index)
        offset = track.chapters[index].start
        strictDuration = false
        eitherDashOrder = true
    }
}

/// Where a track's synced lyrics come from, and how they're parsed.
///
/// Lookup order: a cached `.lrc` in the hidden `.sonar/` folder beside the audio
/// (so downloaded lyrics work offline), then LRCLIB — a free, keyless community
/// lyrics API matched on artist + title + **duration** (so the timestamps line up
/// with our exact copy). A hit from the network is cached back to `.sonar/`.
enum LyricsProvider {

    /// Fetch synced lyrics for a song, or nil if none are available.
    static func fetch(for subject: LyricsSubject) async -> [LyricLine]? {
        if let local = cached(for: subject) { return local }
        return await fetchRemote(for: subject)
    }

    /// Synchronous cache-only lookup — a fast local `.lrc` read, no network. Lets a
    /// caller show cached lyrics instantly (no loading spinner) and reserve the async
    /// network path for an actual cache miss.
    static func cached(for subject: LyricsSubject) -> [LyricLine]? {
        loadCache(for: subject).map { shifted($0, by: subject.offset) }
    }

    /// Network lookup (LRCLIB) for a cache miss; caches the result on a hit.
    static func fetchRemote(for subject: LyricsSubject) async -> [LyricLine]? {
        guard let raw = await fetchFromLRCLIB(subject, .synced) else { return nil }
        writeCache(raw, for: subject)
        return shifted(parse(raw), by: subject.offset)
    }

    /// The song's words from LRCLIB even when nobody has timed them — its plain
    /// lyrics (or the text of its synced ones). What ElevenLabs aligns against when
    /// there's no synced LRC to start from. Same matching as the synced lookup.
    static func fetchPlainText(for subject: LyricsSubject) async -> String? {
        await fetchFromLRCLIB(subject, .plain)
    }

    enum ImportError: LocalizedError {
        case unreadable
        case download
        case notSynced

        var errorDescription: String? {
            switch self {
            case .unreadable: "Couldn't read that file"
            case .download: "Couldn't download that link"
            case .notSynced: "No timestamped lyrics there — it needs to be a synced .lrc"
            }
        }
    }

    /// Use a user-picked `.lrc` file as this song's lyrics — for when the LRCLIB
    /// lookup can't find the song by name. See `install`.
    static func importFile(_ file: URL, for subject: LyricsSubject) throws -> [LyricLine] {
        var encoding = String.Encoding.utf8
        guard let text = try? String(contentsOf: file, usedEncoding: &encoding) else {
            throw ImportError.unreadable
        }
        return try install(text, for: subject)
    }

    /// Download synced lyrics from a user-pasted link and use them for this song.
    /// Takes whatever the link serves: a raw `.lrc` (GitHub/Gist raw, any file
    /// host), an LRCLIB record (its `/api/get/<id>` JSON, or an lrclib.net link
    /// carrying the record id), or an ordinary lyrics web page — its HTML is
    /// flattened to text and only the timestamped lines are kept.
    static func importLink(_ link: URL, for subject: LyricsSubject) async throws -> [LyricLine] {
        var request = URLRequest(url: resolved(link))
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ImportError.download
        }
        let body = String(decoding: data, as: UTF8.self)
        if let record = try? JSONDecoder().decode(LRCLIBRecord.self, from: data),
           let synced = record.syncedLyrics, !synced.isEmpty {
            return try install(synced, for: subject)
        }
        if !parse(body).isEmpty { return try install(body, for: subject) }
        return try install(plainText(fromHTML: body), for: subject)
    }

    /// Where to actually fetch a pasted link from: a GitHub file page → its raw
    /// file, and an lrclib.net link with a record id → that record's JSON.
    private static func resolved(_ link: URL) -> URL {
        let host = link.host()?.lowercased() ?? ""
        if host == "github.com", link.pathComponents.count > 4, link.pathComponents[3] == "blob" {
            // /<owner>/<repo>/blob/<ref>/<path…> → raw.githubusercontent.com/<owner>/<repo>/<ref>/<path…>
            var parts = link.pathComponents.dropFirst()   // drop the leading "/"
            parts.remove(at: parts.startIndex + 2)         // drop "blob"
            return URL(string: "https://raw.githubusercontent.com/" + parts.joined(separator: "/")) ?? link
        }
        if host.hasSuffix("lrclib.net"), !link.path().hasPrefix("/api/"),
           let id = link.pathComponents.last(where: { Int($0) != nil }) {
            return URL(string: "https://lrclib.net/api/get/\(id)") ?? link
        }
        return link
    }

    /// Flatten an HTML page to plain text — line breaks kept, tags dropped, the
    /// common entities decoded — so LRC lines shown on a web page parse as usual.
    private static func plainText(fromHTML html: String) -> String {
        var text = html.replacing(htmlBreakRegex, with: "\n").replacing(htmlTagRegex, with: "")
        for (entity, char) in ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
                               "&lt;": "<", "&gt;": ">", "&nbsp;": " "] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        return text
    }

    nonisolated(unsafe) private static let htmlBreakRegex = /(?i)<br\s*\/?>|<\/(?:p|div|li|span)>/
    nonisolated(unsafe) private static let htmlTagRegex = /<[^>]+>/

    /// Copy user-supplied LRC text into the song's cache slot, so from then on it
    /// loads exactly like a downloaded lyric (instantly, offline) and the song
    /// never hits the name lookup again. Rejects text with no timestamps rather
    /// than caching lyrics that could never highlight.
    ///
    /// `letters` — per-letter times for every word-stamped word, in order — are
    /// saved beside it; without them any old letter file is removed, so it can
    /// never be paired with different lyrics.
    static func install(_ text: String, for subject: LyricsSubject,
                        letters: [[TimeInterval]]? = nil) throws -> [LyricLine] {
        var lines = parse(text)
        guard !lines.isEmpty else { throw ImportError.notSynced }
        let url = cacheURL(for: subject)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if let letters, let data = try? JSONEncoder().encode(letters) {
            try data.write(to: lettersURL(for: subject), options: .atomic)
            lines = attaching(letters, to: lines)
        } else {
            try? FileManager.default.removeItem(at: lettersURL(for: subject))
        }
        return shifted(lines, by: subject.offset)
    }

    /// Hand each word its letter times, in reading order. All-or-nothing: if the
    /// counts don't line up word for word (the LRC was edited since), none are
    /// attached rather than mis-timed ones.
    private static func attaching(_ letters: [[TimeInterval]], to lines: [LyricLine]) -> [LyricLine] {
        let words = lines.flatMap(\.words)
        guard words.count == letters.count,
              zip(words, letters).allSatisfy({ $0.text.count == $1.count }) else { return lines }
        var next = letters.makeIterator()
        return lines.map { line in
            var line = line
            line.words = line.words.map { word in
                var word = word
                word.letters = next.next() ?? []
                return word
            }
            return line
        }
    }

    /// Move every timestamp later by `offset` — an LRC counts from the song's own
    /// start, but a chapter's song starts partway into the file.
    private static func shifted(_ lines: [LyricLine], by offset: TimeInterval) -> [LyricLine] {
        offset == 0 ? lines : lines.map { line in
            LyricLine(time: line.time + offset, text: line.text,
                      words: line.words.map {
                          LyricWord(time: $0.time + offset, text: $0.text, letters: $0.letters.map { $0 + offset })
                      })
        }
    }

    // MARK: On-disk cache (hidden `.sonar/lyrics/` folder beside the audio)

    /// The cache file for a song: `<audio dir>/.sonar/lyrics/<audio filename>.lrc`,
    /// or `<audio filename>.ch<N>.lrc` for chapter N of a mix. A typed subfolder of
    /// the shared hidden `.sonar/` dir (alongside `waveforms/` and the download
    /// `staging/`) keeps the music folder itself clean while the cache still travels
    /// with the library and works offline. Keying on the full filename (extension
    /// included) avoids collisions between same-named tracks of different formats.
    private static func cacheURL(for subject: LyricsSubject) -> URL {
        let audio = subject.url
        var name = audio.lastPathComponent
        if let index = subject.chapterIndex { name += ".ch\(index)" }
        return audio.deletingLastPathComponent()
            .appendingPathComponent(".sonar", isDirectory: true)
            .appendingPathComponent("lyrics", isDirectory: true)
            .appendingPathComponent(name)
            .appendingPathExtension("lrc")
    }

    /// The per-letter timing file beside a song's LRC (`….lrc.letters`, JSON).
    private static func lettersURL(for subject: LyricsSubject) -> URL {
        cacheURL(for: subject).appendingPathExtension("letters")
    }

    private static func loadCache(for subject: LyricsSubject) -> [LyricLine]? {
        guard let text = try? String(contentsOf: cacheURL(for: subject), encoding: .utf8)
        else { return nil }
        let lines = parse(text)
        guard !lines.isEmpty else { return nil }
        guard let data = try? Data(contentsOf: lettersURL(for: subject)),
              let letters = try? JSONDecoder().decode([[TimeInterval]].self, from: data) else { return lines }
        return attaching(letters, to: lines)
    }

    private static func writeCache(_ raw: String, for subject: LyricsSubject) {
        guard !raw.isEmpty else { return }
        let url = cacheURL(for: subject)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        try? raw.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: lettersURL(for: subject))
    }

    // MARK: LRCLIB

    /// Which of an LRCLIB record's texts a lookup is after.
    private enum LRCLIBField {
        case synced   // the timed LRC
        case plain    // just the words — for alignment

        /// The record's usable text of this kind, or nil. A synced LRC must parse
        /// to at least one line; plain text falls back to a synced LRC's words.
        func text(of record: LRCLIBRecord) -> String? {
            switch self {
            case .synced:
                guard let lrc = record.syncedLyrics, !parse(lrc).isEmpty else { return nil }
                return lrc
            case .plain:
                if let plain = record.plainLyrics,
                   !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return plain }
                guard let lrc = record.syncedLyrics else { return nil }
                let lines = parse(lrc).map(\.text)
                return lines.contains(where: { !$0.isEmpty }) ? lines.joined(separator: "\n") : nil
            }
        }
    }

    private static func fetchFromLRCLIB(_ subject: LyricsSubject, _ field: LRCLIBField) async -> String? {
        let lookups = lookups(for: subject)
        guard !lookups.isEmpty else { return nil }

        // 1. Exact /api/get on each candidate (artist, title) — precise and cheap when
        //    the tags (or a clean "Artist - Title" display name) are accurate. Only
        //    pinned to the duration when it's the song's own.
        for lk in lookups {
            for artist in lk.artists {
                if let hit = await lrclibGetExact(artist: artist, title: lk.title,
                                                  duration: subject.strictDuration ? subject.duration : 0,
                                                  field) {
                    return hit
                }
            }
        }
        // 2. Fuzzy search fallback for messy names, but only ACCEPT a result that
        //    verifiably matches this song. Better no lyrics than someone else's.
        for lk in lookups {
            if let hit = await lrclibSearch(lk, subject: subject, field) { return hit }
        }
        return nil
    }

    /// Exact lookup by artist + title. Tries with the duration first (LRCLIB's most
    /// precise match), then without it, so a track whose length differs slightly from
    /// LRCLIB's copy still resolves. Exact on artist+title, so it never mis-matches.
    private static func lrclibGetExact(artist: String, title: String, duration: TimeInterval,
                                       _ field: LRCLIBField) async -> String? {
        for includeDuration in [true, false] where !(includeDuration && duration <= 0) {
            guard var components = URLComponents(string: "https://lrclib.net/api/get") else { continue }
            var items = [
                URLQueryItem(name: "artist_name", value: artist),
                URLQueryItem(name: "track_name", value: title),
            ]
            if includeDuration, duration > 0 {
                items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded()))))
            }
            components.queryItems = items
            guard let url = components.url,
                  let payload: LRCLIBRecord = await get(url),
                  let text = field.text(of: payload) else { continue }
            return text
        }
        return nil
    }

    /// Fuzzy fallback, keeping only results that pass a confidence gate (duration
    /// within a few seconds AND the title/artist words actually match). Tries the
    /// queries in priority order and, on the first that yields survivors, returns the
    /// one whose duration is closest. If nothing qualifies → nil.
    ///
    /// Query order matters for both recall and precision:
    ///   1. Structured `track_name` + `artist_name` — LRCLIB's fuzzy field search, the
    ///      highest-recall option for collab names however they're joined server-side.
    ///   2. Free-text `q=` with a separator-normalized artist + title — a broader net.
    ///   3. Title alone, but only when we have no artist at all (the gate guards it).
    private static func lrclibSearch(_ lk: Lookup, subject: LyricsSubject,
                                     _ field: LRCLIBField) async -> String? {
        var queries: [SearchQuery] = []
        for artist in lk.artists {
            queries.append(SearchQuery(track: lk.title, artist: normalizeArtist(artist)))
        }
        for artist in lk.artists {
            let q = (normalizeArtist(artist) + " " + lk.title).trimmingCharacters(in: .whitespaces)
            queries.append(SearchQuery(q: q))
        }
        if lk.artists.isEmpty { queries.append(SearchQuery(q: lk.title)) }

        var seen = Set<SearchQuery>()
        for query in queries where seen.insert(query).inserted {
            guard let results = await runSearch(query) else { continue }
            let candidates = results.filter {
                field.text(of: $0) != nil
                    && isConfidentMatch(title: $0.trackName ?? "", artist: $0.artistName ?? "",
                                        duration: $0.duration, subject: subject)
            }
            guard !candidates.isEmpty else { continue }
            let best = subject.duration > 0
                ? candidates.min { abs(($0.duration ?? .greatestFiniteMagnitude) - subject.duration)
                                 < abs(($1.duration ?? .greatestFiniteMagnitude) - subject.duration) }!
                : candidates[0]
            if let text = field.text(of: best) { return text }
        }
        return nil
    }

    /// One `/api/search` request. Either free-text (`q`) or structured (`track_name`
    /// + optional `artist_name`); blank artist fields are dropped so LRCLIB doesn't
    /// over-constrain.
    private static func runSearch(_ query: SearchQuery) async -> [LRCLIBRecord]? {
        guard var components = URLComponents(string: "https://lrclib.net/api/search") else { return nil }
        var items: [URLQueryItem] = []
        if let q = query.q, !q.isEmpty { items.append(URLQueryItem(name: "q", value: q)) }
        if let track = query.track, !track.isEmpty { items.append(URLQueryItem(name: "track_name", value: track)) }
        if let artist = query.artist, !artist.isEmpty { items.append(URLQueryItem(name: "artist_name", value: artist)) }
        guard !items.isEmpty else { return nil }
        components.queryItems = items
        guard let url = components.url else { return nil }
        return await get(url)
    }

    // MARK: Match confidence

    /// Whether a search result is really *this* song. Rejects wrong-song matches
    /// (different length, or a title whose words we don't have) so a fuzzy search
    /// can't surface an unrelated song's lyrics.
    private static func isConfidentMatch(title candTitle: String, artist candArtist: String,
                                         duration candDuration: Double?, subject: LyricsSubject) -> Bool {
        // Duration gate — LRCLIB lengths are per-recording accurate; a big gap means
        // a different song. Enforced only when both lengths are known and the
        // subject's length is its own (a chapter's span in a mix is not).
        if subject.strictDuration, subject.duration > 0, let d = candDuration,
           abs(d - subject.duration) > 8 { return false }

        // What we actually know about the song: words from its title AND artist tag.
        let known = tokens(subject.title).union(tokens(subject.artist))
        let candTitleTokens = tokens(candTitle)
        guard !known.isEmpty, !candTitleTokens.isEmpty else { return false }

        // Most of the candidate's title words must be words we have.
        let containment = Double(candTitleTokens.intersection(known).count) / Double(candTitleTokens.count)
        if containment < 0.67 { return false }

        // The candidate's artist should also appear (softer: a YouTube "artist" is the
        // channel, but the real one is usually in the title) — unless the title is a
        // near-perfect match.
        let candArtistTokens = tokens(candArtist)
        return candArtistTokens.isEmpty
            || !candArtistTokens.isDisjoint(with: known)
            || containment >= 0.9
    }

    /// Normalize a string to a set of comparable word tokens: lowercased, diacritics
    /// folded, bracketed/`feat` noise removed, punctuation dropped, 1-char words out.
    private static func tokens(_ string: String) -> Set<String> {
        var text = string.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        text = text.replacing(bracketRegex, with: " ").replacing(featRegex, with: " ")
        let cleaned = String(text.map { $0.isLetter || $0.isNumber ? $0 : " " })
        return Set(cleaned.split(separator: " ").map(String.init).filter { $0.count >= 2 })
    }

    // MARK: Query building

    /// One `/api/search` request's parameters — free-text (`q`) or structured
    /// (`track` + `artist`). Hashable so duplicate queries are only issued once.
    private struct SearchQuery: Hashable {
        var track: String?
        var artist: String?
        var q: String?
    }

    /// Normalized lookup terms for a song: a cleaned title plus candidate artist
    /// strings, best guess first — the file's own artist tag, then any "Artist - Title"
    /// prefix packed into the display name (YouTube style).
    private struct Lookup {
        let title: String
        let artists: [String]
    }

    /// The lookups to try for a subject, in order. One for a plain track; for a mix
    /// chapter whose name has a dash, a second with the halves swapped, since
    /// tracklists write "Dynamite - Taio Cruz" as often as "Taio Cruz - Dynamite".
    /// Empty when there's no title to search on.
    private static func lookups(for subject: LyricsSubject) -> [Lookup] {
        let raw = subject.title.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return [] }

        guard let dash = raw.range(of: " - ") else {
            return [lookup(title: raw, artists: [subject.artist])].compactMap { $0 }
        }
        let before = String(raw[..<dash.lowerBound])
        let after = String(raw[dash.upperBound...])
        var out = [lookup(title: after, artists: [subject.artist, before])]
        if subject.eitherDashOrder {
            out.append(lookup(title: before, artists: [subject.artist, after]))
        }
        return out.compactMap { $0 }
    }

    private static func lookup(title rawTitle: String, artists candidates: [String]) -> Lookup? {
        let title = clean(rawTitle)
        guard !title.isEmpty else { return nil }
        var artists: [String] = []
        for candidate in candidates {
            let a = candidate.trimmingCharacters(in: .whitespaces)
            if !a.isEmpty, !artists.contains(where: { $0.caseInsensitiveCompare(a) == .orderedSame }) {
                artists.append(a)
            }
        }
        return Lookup(title: title, artists: artists)
    }

    /// Strip bracketed groups and any trailing feat/ft clause, then collapse whitespace.
    /// Used for the canonical title — LRCLIB indexes the bare song name, so label tags
    /// like "[Ultra Records]" and "(Official Video)" only hurt recall.
    private static func clean(_ s: String) -> String {
        s.replacing(bracketRegex, with: " ")
            .replacing(featRegex, with: " ")
            .replacing(wsRegex, with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Flatten collaboration separators (x, ×, &, vs, feat, and, /, ",", +, ;) to
    /// spaces so a query matches however LRCLIB happens to join the collaborators —
    /// "A x B", "A & B", "A, B" and "A/B" all become "A B".
    private static func normalizeArtist(_ s: String) -> String {
        clean(s).replacing(artistSepRegex, with: " ")
            .replacing(wsRegex, with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    // Bracketed groups "(…)"/"[…]" and a trailing "feat…/ft…" clause — noise for matching.
    nonisolated(unsafe) private static let bracketRegex = /[\(\[][^\)\]]*[\)\]]/
    nonisolated(unsafe) private static let featRegex = /(?i)\s*\b(?:feat|ft)\b\.?.*/
    nonisolated(unsafe) private static let wsRegex = /\s+/
    // A collaboration separator between two artists: a spaced word joiner (x/vs/and) or
    // a punctuation joiner (× & , ; / +). Normalized to a single space for search.
    nonisolated(unsafe) private static let artistSepRegex = /(?i)(?:\s+(?:x|vs|and)\b\.?|[×&,;\/+])\s*/

    private static let userAgent = "Sonar (macOS music player; github.com/afterglow1251/music-player-macos)"

    /// Shared GET → decode helper (UA header, 200-only, best-effort).
    private static func get<T: Decodable>(_ url: URL) async -> T? {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 12
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(T.self, from: data)
        else { return nil }
        return decoded
    }

    private struct LRCLIBRecord: Decodable {
        let trackName: String?
        let artistName: String?
        let syncedLyrics: String?
        let plainLyrics: String?
        let duration: Double?
    }

    // MARK: LRC parsing

    // `[mm:ss.xx]` or `[mm:ss]`; a line may carry several timestamps. Compiled once
    // and shared read-only (safe despite Regex not being Sendable).
    nonisolated(unsafe) private static let stampRegex = /\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]/

    /// Parse an LRC document into timestamped lines, sorted by time. Metadata tags
    /// (`[ar:…]`, `[ti:…]`, …) carry no numeric time and are skipped.
    static func parse(_ text: String) -> [LyricLine] {
        var out: [LyricLine] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let stamps = line.matches(of: stampRegex)
            guard !stamps.isEmpty else { continue }

            // The lyric text is whatever follows the last timestamp on the line.
            let textStart = stamps.map(\.range.upperBound).max()!
            let (content, words) = words(in: String(line[textStart...]))

            for stamp in stamps {
                out.append(LyricLine(time: seconds(stamp.1, stamp.2, stamp.3), text: content, words: words))
            }
        }
        return out.sorted { $0.time < $1.time }
    }

    // Enhanced-LRC word stamp `<mm:ss.xx>`, placed before the word it times.
    nonisolated(unsafe) private static let wordStampRegex = /<(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?>/

    /// Split a line's text into its words' timings when it carries Enhanced-LRC
    /// `<mm:ss.xx>` stamps. Returns the plain text (stamps stripped) and the words;
    /// no stamps → the text as is and no words. A trailing stamp with no word after
    /// it (an end-of-line marker) is dropped.
    private static func words(in raw: String) -> (text: String, words: [LyricWord]) {
        let stamps = raw.matches(of: wordStampRegex)
        guard !stamps.isEmpty else { return (raw.trimmingCharacters(in: .whitespaces), []) }
        var words: [LyricWord] = []
        for (i, stamp) in stamps.enumerated() {
            let end = i + 1 < stamps.count ? stamps[i + 1].range.lowerBound : raw.endIndex
            let word = raw[stamp.range.upperBound..<end].trimmingCharacters(in: .whitespaces)
            if !word.isEmpty { words.append(LyricWord(time: seconds(stamp.1, stamp.2, stamp.3), text: word)) }
        }
        return (words.map(\.text).joined(separator: " "), words)
    }

    /// Seconds for an `mm`, `ss` and optional fraction captured from a stamp.
    private static func seconds(_ minutes: Substring, _ seconds: Substring, _ fraction: Substring?) -> TimeInterval {
        let frac = fraction.map { frac -> Double in
            // "5" → .5, "05" → .05, "050" → .050
            (Double(frac) ?? 0) / pow(10, Double(frac.count))
        } ?? 0
        return (Double(minutes) ?? 0) * 60 + (Double(seconds) ?? 0) + frac
    }

    /// Index of the line active at `time` (the last line whose stamp has passed),
    /// or nil before the first line.
    static func activeIndex(in lines: [LyricLine], at time: TimeInterval) -> Int? {
        guard let first = lines.first, time >= first.time else { return nil }
        var index = 0
        for (i, line) in lines.enumerated() where line.time <= time { index = i }
        return index
    }
}
