import Foundation
import AVFoundation

/// Word-by-word lyric timing via ElevenLabs — turns a song's audio into an
/// Enhanced LRC (`<mm:ss.xx>` before every word) for the karaoke fill.
///
/// Two routes, picked by what text we have:
/// - **Forced Alignment** (preferred) — audio + the known lyrics → when each of
///   *those* words is sung. The words are guaranteed right; only timing is inferred.
/// - **Speech-to-Text (Scribe)** — no lyrics anywhere: it hears the words itself.
///   Mishearings are possible, and lines are split at pauses.
/// Both bill the same (per hour of audio), so a mix chapter is cut out and sent
/// alone rather than paying for the whole mix.
enum ElevenLabsSync {

    /// One line of the lyrics to time. `time` is its existing start (seconds from
    /// the song's own start) when it came from a synced LRC — kept for a line the
    /// alignment gets wrong — or nil for plain text.
    struct SourceLine {
        let text: String
        let time: TimeInterval?
    }

    enum Failure: LocalizedError {
        case noKey
        case invalidKey
        case quotaExceeded
        case network
        case server(String)
        case mismatch
        case nothingHeard

        var errorDescription: String? {
            switch self {
            case .noKey: "Add your ElevenLabs API key in Settings first"
            case .invalidKey: "ElevenLabs rejected the API key — check it in Settings"
            case .quotaExceeded: "Out of ElevenLabs credits for this month"
            case .network: "Couldn't reach ElevenLabs"
            case .server(let message): "ElevenLabs: \(message)"
            case .mismatch: "ElevenLabs returned timings that don't match the lyrics"
            case .nothingHeard: "ElevenLabs didn't hear any words in this song"
            }
        }
    }

    /// The timed lyrics: an Enhanced LRC (word times) plus, from alignment, when
    /// every letter of every stamped word is sung — the LRC format has no room for
    /// those, so they travel separately (see `LyricsProvider.install`).
    struct Output {
        let lrc: String
        let letters: [[TimeInterval]]?
    }

    /// Timed lyrics for `subject`, from its audio. Timestamps count from the
    /// song's own start (a chapter's, in a mix) — the cache's convention. Empty
    /// `lines` → transcribe instead of align (word timing only, no letters).
    static func timedLyrics(for subject: LyricsSubject, lines: [SourceLine]) async throws -> Output {
        guard let key = ElevenLabsKey.read() else { throw Failure.noKey }
        let audio = try await audioFile(for: subject)
        defer { if audio != subject.url { try? FileManager.default.removeItem(at: audio) } }

        let hasText = lines.contains { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        if hasText {
            let text = lines.map(\.text).joined(separator: "\n")
            let response: AlignmentResponse = try await post(
                "forced-alignment", key: key, audio: audio, fields: ["text": text])
            return try build(lines, words: response.words.filter { !$0.text.allSatisfy(\.isWhitespace) },
                             characters: response.characters)
        } else {
            let response: TranscriptResponse = try await post(
                "speech-to-text", key: key, audio: audio,
                fields: ["model_id": "scribe_v1", "timestamps_granularity": "word", "tag_audio_events": "false"])
            let words = response.words.filter { $0.type == "word" }
            guard !words.isEmpty else { throw Failure.nothingHeard }
            return try build(transcriptLines(words), words: words.map {
                AlignedWord(text: $0.text, start: $0.start, end: $0.end, loss: nil)
            })
        }
    }

    // MARK: Building the LRC

    /// One character's timing from alignment — every character of the sent text,
    /// whitespace included.
    struct AlignedChar: Decodable {
        let text: String
        let start: TimeInterval
    }

    /// A word's timing as the API returns it (seconds from the audio's start).
    struct AlignedWord: Decodable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
        let loss: Double?
    }

    /// Lay `words` (one per whitespace-separated token of `lines`, in order) back
    /// onto the lines as Enhanced LRC.
    ///
    /// With `characters`, each stamped word also gets its letters' real times
    /// (the non-whitespace characters, in order, map one-to-one onto the tokens'
    /// characters), and a word starts when its first letter does.
    ///
    /// Clean-ups on the model's output:
    /// - A "parked" first letter — pinned far before the rest of its word (seen in
    ///   practice: the song's very first letter at 0.08 s, the rest at 11 s) — is
    ///   moved up to just before the second. Without letters, a word whose start
    ///   sits far before the next word's is moved up to just before its own end.
    /// - Times never run backwards.
    /// - A line the model plainly struggled with (high average loss — usually text
    ///   that isn't sung as written, e.g. an extra chorus repeat) keeps its old
    ///   line time without word stamps, when it had one, rather than a bad guess.
    static func build(_ lines: [SourceLine], words: [AlignedWord],
                      characters: [AlignedChar]? = nil) throws -> Output {
        let tokenCount = lines.reduce(0) { $0 + tokens($1.text).count }
        guard tokenCount == words.count, tokenCount > 0 else { throw Failure.mismatch }
        let letterTimes = characters.flatMap { letters(for: lines, from: $0) }
        var stampedLetters: [[TimeInterval]] = []
        var tokenIndex = 0

        var out: [String] = []
        var cursor = 0
        var lastTime: TimeInterval = 0
        var previousEnd: TimeInterval?
        for line in lines {
            let toks = tokens(line.text)
            guard !toks.isEmpty else {
                // A stanza break: a blank stamped line, so the previous line stops
                // highlighting when it's done instead of lingering through the gap.
                if let at = line.time ?? previousEnd {
                    lastTime = max(lastTime, at)
                    out.append("[\(stamp(lastTime))]")
                }
                continue
            }
            let slice = Array(words[cursor..<cursor + toks.count])
            cursor += toks.count
            let lineLetters = letterTimes.map { Array($0[tokenIndex..<tokenIndex + toks.count]) }
            tokenIndex += toks.count
            var times = slice.enumerated().map { i, word -> TimeInterval in
                if let first = lineLetters?[i].first { return first }
                let next = i + 1 < slice.count ? slice[i + 1].start : word.end
                return next - word.start > 4 ? max(word.end - 0.6, word.start) : word.start
            }
            for i in times.indices { times[i] = max(times[i], i == 0 ? lastTime : times[i - 1]) }

            let losses = slice.compactMap(\.loss)
            let struggled = !losses.isEmpty && losses.reduce(0, +) / Double(losses.count) > 2.5
            if struggled, let old = line.time {
                lastTime = max(lastTime, old)
                out.append("[\(stamp(lastTime))]\(toks.joined(separator: " "))")
            } else {
                lastTime = times[0]
                // Rounded as they're written, so letters are compared against the
                // same word start the LRC will be read back with.
                let written = times.map { ($0 * 100).rounded() / 100 }
                out.append("[\(stamp(written[0]))]"
                           + zip(written, toks).map { "<\(stamp($0))>\($1)" }.joined(separator: " "))
                if let lineLetters {
                    stampedLetters += zip(written, lineLetters).map { start, letters in
                        letters.map { max($0, start) }
                    }
                }
            }
            lastTime = max(lastTime, times.last ?? lastTime)
            previousEnd = slice.last?.end
        }
        return Output(lrc: out.joined(separator: "\n") + "\n",
                      letters: letterTimes == nil ? nil : stampedLetters)
    }

    /// Per-token letter times from the alignment's characters: its non-whitespace
    /// characters, in order, dealt out to the tokens' characters. Nil if the counts
    /// don't match (the model normalised something) — then words only.
    private static func letters(for lines: [SourceLine], from characters: [AlignedChar]) -> [[TimeInterval]]? {
        let glyphs = characters.filter { !$0.text.allSatisfy(\.isWhitespace) }
        let toks = lines.flatMap { tokens($0.text) }
        guard glyphs.count == toks.reduce(0, { $0 + $1.count }) else { return nil }
        var index = 0
        return toks.map { token in
            var times = glyphs[index..<index + token.count].map(\.start)
            index += token.count
            if times.count > 1, times[1] - times[0] > 1 { times[0] = max(times[1] - 0.06, 0) }
            for i in times.indices.dropFirst() { times[i] = max(times[i], times[i - 1]) }
            return times
        }
    }

    /// Break a transcript into lines at pauses (or a sentence end, or when a line
    /// gets long) — Scribe returns one flat run of words.
    static func transcriptLines(_ words: [TranscriptWord]) -> [SourceLine] {
        var lines: [SourceLine] = []
        var current: [String] = []
        for (i, word) in words.enumerated() {
            current.append(word.text)
            let next = i + 1 < words.count ? words[i + 1] : nil
            let pause = next.map { $0.start - word.end > 0.8 } ?? true
            let sentenceEnd = word.text.last.map { ".!?".contains($0) } ?? false
            if pause || sentenceEnd || current.count >= 9 {
                lines.append(SourceLine(text: current.joined(separator: " "), time: nil))
                current = []
            }
        }
        return lines
    }

    private static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func stamp(_ t: TimeInterval) -> String {
        let t = max(t, 0)
        return String(format: "%02d:%05.2f", Int(t / 60), t.truncatingRemainder(dividingBy: 60))
    }

    // MARK: Audio

    /// The audio to send: the file itself, or — for a chapter of a mix — just that
    /// chapter, cut to a temporary m4a so only its minutes are billed.
    private static func audioFile(for subject: LyricsSubject) async throws -> URL {
        guard subject.chapterIndex != nil, subject.duration > 0 else { return subject.url }
        let asset = AVURLAsset(url: subject.url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw Failure.server("couldn't cut the chapter out of the mix")
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonar-chapter-\(UUID().uuidString).m4a")
        session.timeRange = CMTimeRange(start: CMTime(seconds: subject.offset, preferredTimescale: 600),
                                        duration: CMTime(seconds: subject.duration, preferredTimescale: 600))
        do {
            if #available(macOS 15, *) {
                try await session.export(to: out, as: .m4a)
            } else {
                session.outputURL = out
                session.outputFileType = .m4a
                await session.export()
                if let error = session.error { throw error }
            }
        } catch {
            throw Failure.server("couldn't cut the chapter out of the mix")
        }
        return out
    }

    // MARK: HTTP

    private struct AlignmentResponse: Decodable {
        let words: [AlignedWord]
        let characters: [AlignedChar]?
    }

    struct TranscriptWord: Decodable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
        let type: String
    }

    private struct TranscriptResponse: Decodable {
        let words: [TranscriptWord]
    }

    /// Multipart POST of `audio` + `fields` to an ElevenLabs endpoint, decoding
    /// the JSON reply or mapping the failure to something a person can act on.
    private static func post<T: Decodable>(_ endpoint: String, key: String, audio: URL,
                                           fields: [String: String]) async throws -> T {
        guard let url = URL(string: "https://api.elevenlabs.io/v1/\(endpoint)"),
              let audioData = try? Data(contentsOf: audio) else { throw Failure.network }
        let boundary = "sonar-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        for (name, value) in fields {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(audio.lastPathComponent)\"\r\n")
        append("Content-Type: application/octet-stream\r\n\r\n")
        body.append(audioData)
        append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300

        guard let (data, response) = try? await URLSession.shared.upload(for: request, from: body),
              let status = (response as? HTTPURLResponse)?.statusCode else { throw Failure.network }
        switch status {
        case 200:
            guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
                throw Failure.server("unexpected response")
            }
            return decoded
        case 401, 402, 403, 429:
            // A spent quota comes back on several of these; the body says which.
            if quotaMessage(in: data) { throw Failure.quotaExceeded }
            if status == 401 || status == 403 { throw Failure.invalidKey }
            throw Failure.server(errorMessage(in: data) ?? "HTTP \(status)")
        default:
            throw Failure.server(errorMessage(in: data) ?? "HTTP \(status)")
        }
    }

    private static func quotaMessage(in data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self).lowercased()
        return text.contains("quota") || text.contains("credits") || text.contains("limit")
    }

    /// `detail.message` (or a plain `detail` string) from an ElevenLabs error body.
    private static func errorMessage(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let detail = json["detail"] as? [String: Any], let message = detail["message"] as? String { return message }
        return json["detail"] as? String
    }
}
