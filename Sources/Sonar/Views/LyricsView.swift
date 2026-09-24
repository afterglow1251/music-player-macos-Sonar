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
        .onChange(of: controller.currentTrack?.url) { _, _ in isReplacing = false }
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
            VStack(spacing: 14) {
                status("No synced lyrics found")
                importForm
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
                        if isHovering {
                            Button("Wrong lyrics?") { isReplacing = true }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.7))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(Color.black.opacity(0.55)))
                                .padding(.bottom, 10)
                                .transition(.opacity)
                        }
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
            if let importError {
                Text(importError)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .onDisappear { importError = nil; lyricsLink = "" }
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
                        lineView(line.text, active: index == activeIndex)
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

    private func lineView(_ text: String, active: Bool) -> some View {
        Text(text.isEmpty ? "♪" : text)
            .font(.system(size: active ? 17 : 15, weight: active ? .bold : .medium))
            .foregroundStyle(active ? accent : .white.opacity(0.4))
            .fixedSize(horizontal: false, vertical: true)
            .animation(.easeInOut(duration: 0.2), value: active)
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
