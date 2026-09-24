import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension PlayerWindow {
    // MARK: Hero artwork (whole photo, never cropped)

    private var heroArt: some View { heroArtView(width: contentWidth, height: artHeight) }

    /// The breathing cover, at an arbitrary size (fullscreen uses a big square).
    private func heroArtView(width: CGFloat, height: CGFloat) -> some View {
        // The artwork gently "breathes" with the bass while playing (capped at
        // 30fps, and stopped when paused or unseen so it doesn't spin the CPU).
        // Built once out here: each frame re-applies only the scale to the same
        // view value instead of rebuilding the whole artwork ZStack.
        let content = artworkContent(width: width, height: height)
        return TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                       paused: !engine.isPlaying || !windowOcclusion.isVisible)) { _ in
            // bassLevel eases to 0 when paused, so the scale glides back to 1
            // smoothly instead of snapping.
            let bass = CGFloat(min(max(engine.analyzer.bassLevel, 0), 1))
            content.scaleEffect(1 + bass * 0.035)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // Click the cover to dismiss the URL field's cursor.
        .contentShape(Rectangle())
        .onTapGesture { dismissFocus() }
    }

    private func artworkContent(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            if let image = artworkImage {
                // Photo FILLS the whole box edge-to-edge (no bands); overflow clipped.
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()
            } else {
                ZStack {
                    LinearGradient(colors: [Color(white: 0.18), Color(white: 0.08)],
                                   startPoint: .top, endPoint: .bottom)
                    Image(systemName: "music.note")
                        .font(.system(size: height > 400 ? 130 : 92))
                        .foregroundStyle(.white.opacity(0.25))
                }
            }
        }
        .frame(width: width, height: height)
        .background(Color.black)
    }

    // MARK: Now-playing info

    var infoStrip: some View {
        let track = controller.currentTrack
        let hasArtist = !(track?.artist.isEmpty ?? true)
        return VStack(alignment: .leading, spacing: 3) {
            // "Playing from <source>" — Spotify-style, so which playlist/library is
            // live is always on screen instead of hidden among the source tabs.
            if let source = playingSourceName {
                playingFromLabel(source)
            }
            // Title line: click the title to copy it; a YouTube-sourced track also
            // reveals an "open on YouTube" link on hover, tucked after the title.
            HStack(spacing: 6) {
                // For a chaptered mix this follows the clock and shows the current
                // section (the song), not the long video title.
                NowPlayingTitle(clock: engine.clock, track: track,
                                isScrubbing: isScrubbing, scrubTime: scrubTime,
                                paused: !windowOcclusion.isVisible)
                if let youtubeURL = track?.youtubeURL {
                    Button { openInBrowser(youtubeURL) } label: {
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(accent)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableButtonStyle())
                    .tooltip("Open on YouTube")
                    .opacity(nowPlayingHover ? 1 : 0)
                    .allowsHitTesting(nowPlayingHover)
                }
            }
            HStack(spacing: 8) {
                Text(nowPlayingArtist)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: true, vertical: false)
                    .copyOnClick(nowPlayingArtist, help: "Click to copy artist", enabled: hasArtist)
                Spacer(minLength: 8)
                SeekTimeLabel(clock: engine.clock, isScrubbing: isScrubbing,
                              scrubTime: scrubTime, accent: accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { nowPlayingHover = $0 }
        .animation(.easeOut(duration: 0.15), value: nowPlayingHover)
        // Right-click mirrors the click affordances, so the actions are also
        // discoverable the standard macOS way.
        .contextMenu {
            if let track {
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
            }
        }
    }

    /// The "Playing from <source>" strip above the title. Dancing bars + a muted
    /// caption naming the live source, and clicking it lands on the playing track
    /// inside that source — so the track is always findable, never lost among the
    /// tabs or scrolled away. Magenta bars here (no coloured fill to clash with)
    /// keep the same "this is the playing source" language as the source tabs.
    ///
    /// This is the *only* jump affordance. A "Now playing" pill in the list header
    /// used to offer the same thing whenever the row scrolled out of view, which
    /// meant two controls for one job — and the pill needed a whole geometry
    /// pipeline (a marker behind the row, viewport measuring, deferred reports) to
    /// work out when to exist. This label is already on screen whenever a track is
    /// loaded, so it can simply always be there.
    private func playingFromLabel(_ name: String) -> some View {
        Button {
            goToCurrentTrack()
        } label: {
            HStack(spacing: 5) {
                // Still here on purpose: the playing row in the list carries the
                // moving bars. One animated "now playing" mark is enough — two in
                // view at once just split the eye.
                NowPlayingBars(color: Theme.logo, animating: false)
                // The source keeps naming the playlist/library even while a queued
                // track is playing — the queue is an overlay on it — so a muted
                // "· from queue" note carries that fact instead of a separate badge.
                (Text("Playing from ").foregroundStyle(.white.opacity(0.4))
                    + Text(name).foregroundStyle(.white.opacity(0.75))
                    + (controller.playingFromQueue
                        ? Text("  ·  from queue").foregroundStyle(Theme.logo.opacity(0.85))
                        : Text("")))
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Go to \(name)")
    }

    var visualizerStrip: some View {
        VisualizerView(engine: engine, mode: $visualizerMode, theme: controller.theme,
                       rows: usesWideLayout ? 22 : 16, columnScale: usesWideLayout ? 2 : 1,
                       // Transparent in both modes so the ambient cover-tinted
                       // backdrop shows through the gaps between the tiles
                       // instead of a black block breaking the wash.
                       transparentBackground: true,
                       suspended: !windowOcclusion.isVisible)
            .frame(height: usesWideLayout ? 88 : 48)
            .frame(maxWidth: .infinity)
    }

    // MARK: Position slider

    var positionSlider: some View {
        WaveformSeekBar(clock: engine.clock, waveforms: controller.waveforms,
                        engine: engine, accent: accent,
                        chapters: controller.currentTrack?.chapters ?? [],
                        isScrubbing: $isScrubbing, scrubTime: $scrubTime, seekHoverX: $seekHoverX)
    }

    // MARK: Transport

    var transportRow: some View {
        // Spotify-style: plain icons, one big Play, shuffle/repeat inline, centered.
        HStack(spacing: 20) {
            Spacer(minLength: 0)
            toggleIcon("shuffle", active: controller.shuffle, size: 15, help: "Shuffle") {
                controller.shuffle.toggle()
            }
            iconButton("backward.end.fill", size: 15, help: "Previous", hotkey: "⌘◀") { controller.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            iconButton("gobackward.10", size: 15, help: "Back 10 seconds", hotkey: "◀") { controller.seekBy(-10) }
            playButton
            iconButton("goforward.10", size: 15, help: "Forward 10 seconds", hotkey: "▶") { controller.seekBy(10) }
            iconButton("forward.end.fill", size: 15, help: "Next", hotkey: "⌘▶") { controller.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            toggleIcon(controller.repeatMode == .one ? "repeat.1" : "repeat",
                       active: controller.repeatMode != .off, size: 15, help: "Repeat") {
                controller.cycleRepeat()
            }
            Spacer(minLength: 0)
        }
    }

    private var playButton: some View {
        Button { controller.togglePlayPause() } label: {
            Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 18, weight: .heavy))
                .foregroundStyle(.black)
                .frame(width: 48, height: 48)
                .background(Circle().fill(accent))
                .shadow(color: accent.opacity(0.5), radius: 8)
        }
        .buttonStyle(PressableButtonStyle(hoverScale: 1.06))
        .tooltip(engine.isPlaying ? "Pause" : "Play", hotkey: "Space")
        .keyboardShortcut(.space, modifiers: [])
    }

    /// Plain transport icon — no background circle (Spotify-style).
    private func iconButton(_ symbol: String, size: CGFloat, weight: Font.Weight = .medium,
                            help: String, hotkey: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .tooltip(help, hotkey: hotkey)
    }

    /// Toggle icon (shuffle/repeat) — green when active, gray when off.
    private func toggleIcon(_ symbol: String, active: Bool, size: CGFloat, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(active ? accent : .white.opacity(0.55))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .tooltip(help)
    }

    // MARK: Utility row (open file + volume — de-emphasized)

    var utilityRow: some View {
        HStack(spacing: 8) {
            iconButton("folder", size: 13, help: "Open file") { openFile() }
            Spacer()
            // A normal icon button like its neighbours (hover/press feedback), but
            // with an AppKit click-catcher on top. The menu-bar player is a
            // `.nonactivatingPanel`, which never becomes key from a plain button
            // press, so a bare SwiftUI Button only fired after the volume NSSlider
            // (which does take key) had been touched. FirstMouseButton owns the
            // click and works without the panel being key.
            Image(systemName: engine.isMuted ? "speaker.slash.fill" : "speaker.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(engine.isMuted ? .red.opacity(0.85) : .white.opacity(0.85))
                .brightness(muteHovering ? 0.10 : 0)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
                // Grow on hover to match the neighbouring buttons. The catcher on top
                // eats the hover events, so it reports them back to drive the scale.
                .scaleEffect(muteHovering ? 1.10 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: muteHovering)
                .overlay(FirstMouseButton(action: { engine.toggleMute() },
                                          onHover: { muteHovering = $0 }))
                .tooltip(engine.isMuted ? "Unmute" : "Mute")
            Slider(value: Binding(get: { engine.volume }, set: { engine.volume = $0 }), in: 0...1)
                .controlSize(.mini)
                .tint(accent)
                .frame(width: 96)
                .scrollToAdjust { engine.volume = min(max(engine.volume + Float($0) * 0.05, 0), 1) }
        }
    }

    // MARK: Top bar (settings lives here, top-right)

    /// The cover slot: artwork (or the Settings panel), with the settings toggle
    /// and sleep badge floating over its top corners — no separate top bar needed.
    func heroSlot(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .top) {
            if showSettings {
                SettingsView(controller: controller, width: width, height: height)
                    .transition(.opacity)
            } else if showLyrics {
                LyricsView(controller: controller, clock: engine.clock, width: width, height: height)
                    .transition(.opacity)
            } else {
                heroArtView(width: width, height: height)
            }
            HStack(spacing: 8) {
                // The sleep badge floats over the artwork only — over the Settings
                // panel it would collide with the "Settings" title (and the panel
                // shows its own countdown), and over Lyrics it covers the words.
                if !showSettings && !showLyrics {
                    if let remaining = controller.sleepRemaining {
                        sleepBadge(clockTimeString(remaining))
                    } else if controller.sleepMode == .endOfTrack {
                        sleepBadge("track end")
                    }
                }
                Spacer()
                lyricsToggle
                settingsToggle
            }
            .padding(10)
            .frame(width: width)
        }
        .frame(width: width, height: height)
    }

    private var lyricsToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) {
                showLyrics.toggle()
                if showLyrics { showSettings = false }
            }
        } label: {
            Image(systemName: "quote.bubble")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(showLyrics ? accent : .white.opacity(0.9))
                .frame(width: 30, height: 30)
                .background(Circle().fill(.black.opacity(0.35)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .tooltip("Lyrics")
    }

    private var settingsToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) {
                showSettings.toggle()
                if showSettings { showLyrics = false }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(showSettings ? accent : .white.opacity(0.9))
                .frame(width: 30, height: 30)
                .background(Circle().fill(.black.opacity(0.35)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .tooltip("Settings")
    }

    private func sleepBadge(_ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "moon.fill").font(.system(size: 9))
            Text(text).font(.system(size: 10, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(accent)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Capsule().fill(.black.opacity(0.35)))
    }

    // MARK: Now-playing text

    private var nowPlayingArtist: String {
        guard let track = controller.currentTrack, !track.artist.isEmpty else { return "SONAR" }
        return track.artist
    }

    private func openFile() {
        let panel = NSOpenPanel()
        var contentTypes: [UTType] = [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
        if let flac = UTType(filenameExtension: "flac") {
            contentTypes.append(flac)
        }
        panel.allowedContentTypes = contentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        controller.importFiles(panel.urls)
    }
}
