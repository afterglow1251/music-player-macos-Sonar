import Testing
@testable import Sonar

@Suite struct ElevenLabsSyncTests {
    typealias Word = ElevenLabsSync.AlignedWord
    typealias Char = ElevenLabsSync.AlignedChar
    typealias Line = ElevenLabsSync.SourceLine

    @Test func buildsEnhancedLRCFromPlainLines() throws {
        let lines = [Line(text: "Yellow diamonds shine", time: nil), Line(text: "", time: nil),
                     Line(text: "We found", time: nil)]
        let words = [Word(text: "Yellow", start: 10.68, end: 11.2, loss: 0.9),
                     Word(text: "diamonds", start: 11.32, end: 11.4, loss: 0.9),
                     Word(text: "shine", start: 11.48, end: 11.8, loss: 0.9),
                     Word(text: "We", start: 13.24, end: 13.3, loss: 0.7),
                     Word(text: "found", start: 13.34, end: 13.6, loss: 0.7)]
        let lrc = try ElevenLabsSync.build(lines, words: words).lrc
        #expect(lrc == """
        [00:10.68]<00:10.68>Yellow <00:11.32>diamonds <00:11.48>shine
        [00:11.80]
        [00:13.24]<00:13.24>We <00:13.34>found

        """)
        // …and Sonar's own parser reads the word timings back.
        let parsed = LyricsProvider.parse(lrc)
        #expect(parsed.first?.words.map(\.text) == ["Yellow", "diamonds", "shine"])
        #expect(parsed.first?.text == "Yellow diamonds shine")
    }

    @Test func movesAParkedFirstLetterUpToItsWord() throws {
        let words = [Word(text: "Yellow", start: 0.08, end: 11.2, loss: 1),
                     Word(text: "diamonds", start: 11.32, end: 11.4, loss: 1)]
        let lrc = try ElevenLabsSync.build([Line(text: "Yellow diamonds", time: nil)], words: words).lrc
        #expect(lrc.hasPrefix("[00:10.60]<00:10.60>Yellow"))
    }

    @Test func keepsTheOldLineTimeWhereAlignmentStruggled() throws {
        let words = [Word(text: "Dream", start: 192.82, end: 192.9, loss: 4),
                     Word(text: "on", start: 192.9, end: 193.0, loss: 4)]
        let lrc = try ElevenLabsSync.build([Line(text: "Dream on", time: 190.5)], words: words).lrc
        #expect(lrc == "[03:10.50]Dream on\n")
    }

    @Test func rejectsWordCountMismatch() {
        #expect(throws: ElevenLabsSync.Failure.self) {
            try ElevenLabsSync.build([Line(text: "a b c", time: nil)],
                                     words: [Word(text: "a", start: 0, end: 1, loss: nil)])
        }
    }

    @Test func carriesRealLetterTimesAndUnparksTheFirstLetter() throws {
        // "So high": the first letter parked at the song's start, as seen live.
        let chars = [Char(text: "S", start: 0.08), Char(text: "o", start: 11.34), Char(text: " ", start: 11.4),
                     Char(text: "h", start: 11.48), Char(text: "i", start: 11.5), Char(text: "g", start: 11.62),
                     Char(text: "h", start: 11.7)]
        let words = [Word(text: "So", start: 0.08, end: 11.4, loss: 1),
                     Word(text: "high", start: 11.48, end: 11.8, loss: 1)]
        let out = try ElevenLabsSync.build([Line(text: "So high", time: nil)], words: words, characters: chars)
        #expect(out.lrc == "[00:11.28]<00:11.28>So <00:11.48>high\n")
        #expect(out.letters == [[11.28, 11.34], [11.48, 11.5, 11.62, 11.7]])
    }

    @Test func transcriptLettersMapOntoHeardWords() throws {
        // What the Scribe path hands to `build`: the heard words, split into lines,
        // and their characters flattened in order.
        let heard = [ElevenLabsSync.TranscriptWord(text: "Take", start: 6.84, end: 7.1, type: "word",
                                                   characters: [.init(text: "T", start: 6.84), .init(text: "a", start: 6.9),
                                                                .init(text: "k", start: 6.98), .init(text: "e", start: nil)]),
                     ElevenLabsSync.TranscriptWord(text: "me", start: 7.12, end: 7.3, type: "word",
                                                   characters: [.init(text: "m", start: 7.12), .init(text: "e", start: 7.2)])]
        let chars = heard.flatMap { word in
            (word.characters ?? []).map { Char(text: $0.text, start: $0.start ?? word.start) }
        }
        let out = try ElevenLabsSync.build(ElevenLabsSync.transcriptLines(heard),
                                           words: heard.map { Word(text: $0.text, start: $0.start, end: $0.end, loss: nil) },
                                           characters: chars)
        #expect(out.lrc == "[00:06.84]<00:06.84>Take <00:07.12>me\n")
        // The untimed "e" borrows its word's start, then is clamped forward.
        #expect(out.letters == [[6.84, 6.9, 6.98, 6.98], [7.12, 7.2]])
    }

    @Test func toleratesTheModelSplittingWordsDifferently() throws {
        // A lone "—" in the lyrics that the model doesn't count as a word: its
        // word list is one short, but the characters still line up with the text.
        let text = "Run — now"
        var t = 1.0
        let chars = text.map { c -> Char in t += 0.1; return Char(text: String(c), start: t) }
        let words = [Word(text: "Run", start: 1.1, end: 1.4, loss: 1),
                     Word(text: "now", start: 1.7, end: 2.0, loss: 1)]
        let out = try ElevenLabsSync.build([Line(text: text, time: nil)], words: words, characters: chars)
        #expect(out.lrc == "[00:01.10]<00:01.10>Run <00:01.50>— <00:01.70>now\n")
        #expect(out.letters?.count == 3)
    }
}
