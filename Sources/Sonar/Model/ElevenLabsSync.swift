import Foundation
import AVFoundation

/// Word-by-word lyric timing via ElevenLabs — turns a song's audio into an
/// Enhanced LRC (`<mm:ss.xx>` before every word) for the karaoke fill.
///
/// Two routes, picked by what text we have:
/// - **Forced Alignment** (preferred) — audio + the known lyrics → when each of
///   *those* words is sung. The words are guaranteed right; only timing is inferred.
/// - **Speech-to-Text (Scribe)** — no lyrics anywhere: it hears the words itself,
///   letters timed too. Mishearings are possible, and lines are split at pauses.
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
    /// `lines` → transcribe instead of align (still one request, letters included).
    static func timedLyrics(for subject: LyricsSubject, lines: [SourceLine]) async throws -> Output {
        guard let key = ElevenLabsKey.read() else { throw Failure.noKey }
        let audio = try await audioFile(for: subject)
        defer { if audio != subject.url { try? FileManager.default.removeItem(at: audio) } }
        try Task.checkCancellation()

        let hasText = lines.contains { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        if hasText {
            let text = lines.map(\.text).joined(separator: "\n")
            let response: AlignmentResponse = try await post(
                "forced-alignment", key: key, audio: audio, duration: subject.duration, fields: ["text": text])
            return try build(lines, words: response.words.filter { !$0.text.allSatisfy(\.isWhitespace) },
                             characters: response.characters)
        } else {
            let response: TranscriptResponse = try await post(
                "speech-to-text", key: key, audio: audio, duration: subject.duration,
                fields: ["model_id": "scribe_v1", "timestamps_granularity": "character",
                         "tag_audio_events": "false"])
            let words = response.words.filter { $0.type == "word" }
            guard !words.isEmpty else { throw Failure.nothingHeard }
            // Character granularity gives each heard word its letters' times, so a
            // transcribed song gets real letter timing from this one request too.
            // A letter without a time borrows its word's start (then clamped
            // forward in `letters(for:from:)`).
            let characters = words.flatMap { word in
                (word.characters ?? []).map { AlignedChar(text: $0.text, start: $0.start ?? word.start) }
            }
            return try build(transcriptLines(words), words: words.map {
                AlignedWord(text: $0.text, start: $0.start, end: $0.end, loss: nil)
            }, characters: characters)
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

    /// Lay the timings back onto `lines` as Enhanced LRC, one stamp per
    /// whitespace-separated token.
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
        let allTokens = lines.flatMap { tokens($0.text) }
        guard !allTokens.isEmpty else { throw Failure.mismatch }
        // Letters come from the characters list, which mirrors the sent text
        // character for character — so they (and word starts taken from them)
        // don't depend on how ElevenLabs happens to split the text into words:
        // a lone "—" or "..." it doesn't count as a word no longer throws the
        // whole result away. Its own word list is used only when it lines up
        // one-to-one with our tokens (for loss and word ends), or as the sole
        // source when there are no characters.
        let letterTimes = characters.flatMap { letters(for: lines, from: $0) }
        let wordsMatch = words.count == allTokens.count
        guard letterTimes != nil || wordsMatch else { throw Failure.mismatch }

        var stampedLetters: [[TimeInterval]] = []
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
            let range = cursor..<cursor + toks.count
            cursor += toks.count
            let slice = wordsMatch ? Array(words[range]) : nil
            let lineLetters = letterTimes.map { Array($0[range]) }
            var times = toks.indices.map { i -> TimeInterval in
                if let first = lineLetters?[i].first { return first }
                let word = slice![i]   // no letters → the words matched (guarded above)
                let next = i + 1 < toks.count ? slice![i + 1].start : word.end
                return next - word.start > 4 ? max(word.end - 0.6, word.start) : word.start
            }
            for i in times.indices { times[i] = max(times[i], i == 0 ? lastTime : times[i - 1]) }

            let losses = slice?.compactMap(\.loss) ?? []
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
            previousEnd = slice?.last?.end ?? lineLetters?.last?.last.map { $0 + 0.3 }
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
        /// Present with `timestamps_granularity=character`.
        let characters: [TranscriptChar]?
    }

    struct TranscriptChar: Decodable {
        let text: String
        let start: TimeInterval?
    }

    private struct TranscriptResponse: Decodable {
        let words: [TranscriptWord]
    }

    /// Rough cost of timing `duration` seconds of audio — ElevenLabs bills alignment
    /// and transcription alike, per hour. For the "this will cost…" confirmation.
    static func estimatedCost(of duration: TimeInterval) -> Double {
        duration / 3600 * 0.22
    }

    /// Multipart POST of `audio` + `fields` to an ElevenLabs endpoint, decoding
    /// the JSON reply or mapping the failure to something a person can act on.
    ///
    /// The body is written to a temporary file and uploaded from there, so only a
    /// few MB are ever in memory — a multi-hour file would otherwise be held twice
    /// over (read in, then copied into the body). The idle timeout grows with the
    /// audio's length: the server is silent while it works, and a long file can
    /// take minutes. Cancelling the calling task cancels the upload.
    private static func post<T: Decodable>(_ endpoint: String, key: String, audio: URL,
                                           duration: TimeInterval, fields: [String: String]) async throws -> T {
        guard let url = URL(string: "https://api.elevenlabs.io/v1/\(endpoint)") else { throw Failure.network }
        let boundary = "sonar-\(UUID().uuidString)"
        let body = try multipartBody(audio: audio, fields: fields, boundary: boundary)
        defer { try? FileManager.default.removeItem(at: body) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        // 5 min, plus a minute per half hour of audio.
        request.timeoutInterval = 300 + 60 * (max(duration, 0) / 1800).rounded(.up)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.upload(for: request, fromFile: body)
        } catch {
            try Task.checkCancellation()   // a cancel isn't a network failure
            throw Failure.network
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw Failure.network }
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

    /// Write the multipart body to a temporary file, copying the audio across in
    /// 4 MB chunks (checking for a cancel between them).
    static func multipartBody(audio: URL, fields: [String: String], boundary: String) throws -> URL {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("sonar-upload-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: out.path, contents: nil),
              let writer = try? FileHandle(forWritingTo: out),
              let reader = try? FileHandle(forReadingFrom: audio) else { throw Failure.network }
        defer { try? writer.close(); try? reader.close() }
        do {
            func write(_ string: String) throws { try writer.write(contentsOf: Data(string.utf8)) }
            for (name, value) in fields {
                try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
            }
            try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(audio.lastPathComponent)\"\r\n")
            try write("Content-Type: application/octet-stream\r\n\r\n")
            while let chunk = try reader.read(upToCount: 4 << 20), !chunk.isEmpty {
                try Task.checkCancellation()
                try writer.write(contentsOf: chunk)
            }
            try write("\r\n--\(boundary)--\r\n")
        } catch {
            try? FileManager.default.removeItem(at: out)
            if error is CancellationError { throw error }
            throw Failure.server("couldn't prepare the upload")
        }
        return out
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
