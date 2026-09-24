import SwiftUI
import UniformTypeIdentifiers

/// Synced lyrics that scroll with playback, filling the hero area (like Settings).
/// The active line is highlighted and kept centered; the rest dim with distance.
struct LyricsView: View {
    @ObservedObject var controller: PlayerController
    /// Observed directly so the highlighted line tracks playback — currentTime no
    /// longer flows through `controller`, so observing it here keeps the rest of
    /// the app off the ~10 Hz tick.
    @ObservedObject var clock: PlaybackClock
    var width: CGFloat
    var height: CGFloat

    private var engine: AudioEngine { controller.engine }
    private let accent = Theme.accent
    private static let lrclibURL = "https://lrclib.net"

    /// A pasted link to synced lyrics, for when the name lookup finds nothing.
    @State private var lyricsLink = ""
    @State private var isImporting = false
    /// Why the last import attempt was rejected, shown under the field.
    @State private var importError: String?
    /// Showing the import form over lyrics that were found but are the wrong song.
    @State private var isReplacing = false
    /// Pointer over the panel — reveals the "Wrong lyrics?" link, so found lyrics
    /// carry no resting chrome.
    @State private var isHovering = false
    /// The saved ElevenLabs key (masked) — whether "Sync words" is on offer.
    @ObservedObject private var elevenLabs = ElevenLabsKey.shared
    @State private var isSyncing = false
    /// Why the last word sync failed, shown until the next attempt or song.
    @State private var syncError: String?
    /// The running sync, so it can be cancelled.
    @State private var syncTask: Task<Void, Never>?
    /// Which sync is current — a cancelled one finishing late mustn't reset the
    /// state of one started after it.
    @State private var syncRun = UUID()
    /// Audio length awaiting a go-ahead: a long track is confirmed (with its cost)
    /// before anything is sent.
    @State private var pendingSyncDuration: TimeInterval?
    /// Tracks longer than this ask first.
    private static let confirmAbove: TimeInterval = 15 * 60

    private var activeIndex: Int? {
        controller.lyrics.activeIndex(at: clock.currentTime)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
            content
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { isHovering = $0 }
        // A new song starts with its own lyrics, not the previous one's form.
        .onChange(of: controller.currentTrack?.url) { _, _ in
            isReplacing = false
            syncError = nil
            pendingSyncDuration = nil
        }
    }

    @ViewBuilder
    private var content: some View {
        switch controller.lyrics.state {
        case .loading:
            status(spinner: true, "Finding lyrics…")
        case .idle:
            status("Play a track to see its lyrics")
        case .unavailable:
            // The lookup goes by the song's name, which can miss — let the user
            // point at the right lyrics instead: paste a link, or pick a file.
            if isSyncing {
                VStack(spacing: 10) {
                    status(spinner: true, "Syncing words…")
                    Button("Cancel", action: cancelSync)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
            } else {
                VStack(spacing: 14) {
                    status("No synced lyrics found")
                    // ElevenLabs can time the words itself — from LRCLIB's plain
                    // lyrics when there are some, else by listening.
                    // The button and its long-track confirmation share one fixed-height
                    // slot, so swapping them doesn't nudge everything below.
                    if elevenLabs.isSet {
                        Group {
                            if let pending = pendingSyncDuration {
                                confirmation(pending)
                            } else {
                                Button("Sync with ElevenLabs", action: syncWords)
                                    .buttonStyle(.plain)
                                    .foregroundStyle(accent)
                            }
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .frame(height: 18)
                    }
                    if let syncError { note(syncError) }
                    importForm
                }
            }
        case .loaded:
            // Identity tied to the loaded lyrics themselves (each fetch makes fresh
            // LyricLine ids), so the scroller is rebuilt exactly when the text changes
            // to a new song — refreshing the lines and re-running its onAppear to
            // recenter/reset the scroll. Previously the loading-state flash recreated
            // it as a side effect; this does it deliberately, without the flash.
            if isReplacing {
                // The name lookup can also land on the wrong song — same form,
                // replacing what was found.
                VStack(spacing: 14) {
                    Text("Replace these lyrics")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                    importForm
                    Button("Cancel") { isReplacing = false }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                        .disabled(isImporting)
                }
            } else {
                scroller
                    .id(controller.lyrics.lines.first?.id)
                    .overlay(alignment: .bottom) {
                        HStack(spacing: 8) {
                            if isSyncing {
                                // Stays up while it runs — it takes a few seconds.
                                pill {
                                    HStack(spacing: 6) {
                                        ProgressView().controlSize(.mini).tint(.white.opacity(0.7))
                                        Text("Syncing words…")
                                        Button("Cancel", action: cancelSync)
                                            .buttonStyle(.plain)
                                            .foregroundStyle(.white.opacity(0.45))
                                    }
                                }
                            } else if let pending = pendingSyncDuration {
                                pill { confirmation(pending) }
                            } else if let syncError {
                                pill { Text(syncError) }
                            } else if isHovering {
                                // Line-synced lyrics can be upgraded to karaoke — and karaoke
                                // re-timed (a bad pass, or one from before letter timing),
                                // overwriting the song's LRC.
                                if elevenLabs.isSet {
                                    pill {
                                        Button(controller.lyrics.hasWordTimings ? "Re-sync with ElevenLabs" : "Sync with ElevenLabs",
                                               action: syncWords)
                                            .buttonStyle(.plain)
                                    }
                                }
                                // Letters needs real letter timing — no picker without it.
                                if controller.lyrics.hasLetterTimings { fillPicker }
                                pill { Button("Wrong lyrics?") { isReplacing = true }.buttonStyle(.plain) }
                            }
                        }
                        .padding(.bottom, 10)
                        .transition(.opacity)
                    }
                    .animation(.easeOut(duration: 0.15), value: isHovering)
            }
        }
    }

    /// Where to get lyrics by hand: a pointer to LRCLIB, a link field, and a file
    /// picker. Shown when nothing was found, and when replacing a wrong match.
    private var importForm: some View {
        VStack(spacing: 14) {
            // Where to go looking: click copies LRCLIB's address (same
            // click-to-copy as the now-playing title), so the user can search
            // the song there by hand and paste its link below.
            Text("Use LRCLIB")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
                .copyOnClick(Self.lrclibURL,
                             help: "Copy \(Self.lrclibURL) — find the song there, then paste its link below")
            linkField
            Button("or choose a file…", action: pickLyricsFile)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .disabled(isImporting)
            if let importError { note(importError) }
        }
        .onDisappear { importError = nil; lyricsLink = "" }
    }

    /// A small dark capsule floated over the lyrics (actions, sync status).
    private func pill<Label: View>(@ViewBuilder _ label: () -> Label) -> some View {
        label()
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.black.opacity(0.55)))
    }

    /// Words ⇄ Letters for the karaoke fill — the unselected one dimmed, like the
    /// app's other two-way toggles, rather than a boxed segmented control.
    private var fillPicker: some View {
        pill {
            HStack(spacing: 8) {
                ForEach(KaraokeFill.allCases, id: \.self) { mode in
                    Button(mode.label) { controller.lyrics.fill = mode }
                        .buttonStyle(.plain)
                        .foregroundStyle(controller.lyrics.fill == mode ? accent : .white.opacity(0.45))
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.45))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
    }

    /// Time the playing song word by word through ElevenLabs (see
    /// `LyricsController.syncWords`). A long track asks first, showing its cost.
    private func syncWords() {
        guard !isSyncing else { return }
        let time = clock.currentTime
        if let duration = controller.lyrics.syncDuration(at: time), duration > Self.confirmAbove {
            pendingSyncDuration = duration
            return
        }
        startSync(at: time)
    }

    private func startSync(at time: TimeInterval) {
        pendingSyncDuration = nil
        isSyncing = true
        syncError = nil
        let run = UUID()
        syncRun = run
        syncTask = Task {
            var failure: String?
            do {
                try await controller.lyrics.syncWords(at: time)
            } catch is CancellationError {
                // Cancelled by the user — nothing to report.
            } catch {
                failure = error.localizedDescription
            }
            guard syncRun == run else { return }
            syncError = failure
            isSyncing = false
            syncTask = nil
        }
    }

    /// Stop a running sync. The upload is cut off and nothing is saved; if the
    /// audio had already reached ElevenLabs it may still count against the quota.
    private func cancelSync() {
        syncTask?.cancel()
        syncTask = nil
        isSyncing = false
    }

    /// "2:34:10 of audio, about $0.57   Sync   Cancel" — the go-ahead for a long track.
    private func confirmation(_ duration: TimeInterval) -> some View {
        HStack(spacing: 10) {
            Text("\(Self.hms(duration)) of audio, about \(String(format: "$%.2f", ElevenLabsSync.estimatedCost(of: duration)))")
                .foregroundStyle(.white.opacity(0.7))
            Button("Sync") { startSync(at: clock.currentTime) }
                .buttonStyle(.plain)
                .foregroundStyle(accent)
            Button("Cancel") { pendingSyncDuration = nil }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.45))
        }
    }

    /// "2:34:10" / "47:05" — hours only when there are some.
    private static func hms(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    private var scroller: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                // Lazy so the whole song's worth of lines isn't rebuilt on every
                // currentTime tick (the controller republishes ~10×/s); only the
                // visible lines re-evaluate.
                LazyVStack(alignment: .leading, spacing: 12) {
                    // Small top inset so the first line starts near the top; a large
                    // bottom inset so the last line can still center during playback.
                    Color.clear.frame(height: 24)
                    ForEach(Array(controller.lyrics.lines.enumerated()), id: \.element.id) { index, line in
                        lineView(line, active: index == activeIndex)
                            .id(index)
                            .onTapGesture { engine.seek(to: line.time) }
                    }
                    Color.clear.frame(height: height * 0.4)
                }
                .padding(.horizontal, 22)
                .frame(width: width, alignment: .leading)
            }
            .scrollIndicators(.never)
            .onChange(of: activeIndex) { _, new in
                guard let new else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(new, anchor: .center)
                }
            }
            .onAppear {
                // Opening mid-song: jump straight to the current line instead of
                // waiting for the next activeIndex change to trigger a scroll.
                guard let idx = activeIndex else { return }
                proxy.scrollTo(idx, anchor: .center)
            }
        }
    }

    private func lineView(_ line: LyricLine, active: Bool) -> some View {
        lineText(line, active: active)
            .font(.system(size: active ? 17 : 15, weight: active ? .bold : .medium))
            .fixedSize(horizontal: false, vertical: true)
            .animation(.easeInOut(duration: 0.2), value: active)
    }

    /// The line's text, coloured. Karaoke on the active line of an Enhanced LRC:
    /// sung words are accent, upcoming ones white. In `.letters` mode each letter
    /// lights at its real sung time (ElevenLabs per-letter timing, when the song
    /// has it); in `.words` mode a word lights whole the moment it starts. A plain line-synced LRC lights the whole
    /// active line at once; inactive lines dim.
    private func lineText(_ line: LyricLine, active: Bool) -> Text {
        guard !line.text.isEmpty else {
            return Text("♪").foregroundStyle(active ? accent : .white.opacity(0.4))
        }
        guard active else { return Text(line.text).foregroundStyle(.white.opacity(0.4)) }
        guard !line.words.isEmpty else { return Text(line.text).foregroundStyle(accent) }
        let now = clock.currentTime
        let words = line.words
        let upcoming = Color.white.opacity(0.85)
        return words.indices.reduce(Text("")) { text, i in
            let word = words[i]
            let spaced = i == 0 ? word.text : " " + word.text
            guard word.time <= now else { return text + Text(spaced).foregroundStyle(upcoming) }
            // Letters: each letter lights when it's actually sung (ElevenLabs
            // timing). No letter data, or Words mode → the word lights whole.
            guard controller.lyrics.fill == .letters, !word.letters.isEmpty
            else { return text + Text(spaced).foregroundStyle(accent) }
            let letters = Array(word.text)
            let lit = word.letters.prefix { $0 <= now }.count
            return text + Text((i == 0 ? "" : " ") + String(letters[..<lit])).foregroundStyle(accent)
                + Text(String(letters[lit...])).foregroundStyle(upcoming)
        }
    }

    /// Paste a link to synced lyrics; ↩ or the arrow downloads it.
    private var linkField: some View {
        HStack(spacing: 8) {
            Image(systemName: "link").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
            SteadyTextField(placeholder: "Paste a link to the lyrics (.lrc)…",
                            text: $lyricsLink, onSubmit: importLink)
            if isImporting {
                ProgressView().controlSize(.small).tint(.white.opacity(0.6))
            } else {
                Button(action: importLink) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(linkURL == nil ? .white.opacity(0.25) : accent)
                }
                .buttonStyle(.plain)
                .disabled(linkURL == nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .padding(.horizontal, 28)
        .disabled(isImporting)
    }

    /// The pasted text as an http(s) URL, or nil while it isn't one.
    private var linkURL: URL? {
        let text = lyricsLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host() != nil else { return nil }
        return url
    }

    private func importLink() {
        guard let url = linkURL, !isImporting else { return }
        isImporting = true
        importError = nil
        let time = clock.currentTime
        Task {
            do {
                try await controller.lyrics.importLyrics(fromLink: url, at: time)
                lyricsLink = ""
                isReplacing = false
            } catch {
                importError = error.localizedDescription
            }
            isImporting = false
        }
    }

    /// Pick an `.lrc` and use it for the song playing now.
    private func pickLyricsFile() {
        let panel = NSOpenPanel()
        panel.message = "Choose a synced lyrics (.lrc) file"
        panel.allowedContentTypes = [UTType(filenameExtension: "lrc") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try controller.lyrics.importLyrics(from: url, at: clock.currentTime)
            importError = nil
            isReplacing = false
        } catch {
            importError = error.localizedDescription
        }
    }

    private func status(spinner: Bool = false, _ text: String) -> some View {
        VStack(spacing: 10) {
            if spinner {
                ProgressView().controlSize(.small).tint(.white.opacity(0.6))
            } else {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.white.opacity(0.3))
            }
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
        }
    }
}
