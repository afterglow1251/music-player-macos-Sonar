import SwiftUI

/// The position bar, drawn as the track's real waveform. Observes the clock for
/// the live position and the waveform store for the peaks; scrub/hover state is
/// bound back to the parent. Isolated so ticking doesn't re-render the rest of the
/// window. Click/drag anywhere to seek; the played portion is drawn in accent.
///
/// Shared between the main window's seek bar and the menu-bar mini player —
/// geometry and the unplayed-bar colour are parameters so each host can size it
/// (and keep it legible on its own background: the main window is always dark,
/// the panel's `.menu` material follows the system appearance).
struct WaveformSeekBar: View {
    @ObservedObject var clock: PlaybackClock
    @ObservedObject var waveforms: WaveformStore
    let engine: AudioEngine
    let accent: Color
    /// Chapter markers for the loaded track (empty for the common single-song
    /// case). Drawn as dividers over the waveform; a click near one snaps to it.
    var chapters: [Chapter] = []
    @Binding var isScrubbing: Bool
    @Binding var scrubTime: TimeInterval
    @Binding var seekHoverX: CGFloat?

    /// Column geometry — a thin bar with a hair of gap, SoundCloud-style.
    var barWidth: CGFloat = 2
    var barGap: CGFloat = 1
    var height: CGFloat = 30
    /// The unplayed portion's colour.
    var muted: Color = .white.opacity(0.22)

    /// A floor so silent stretches still show a sliver, not a gap.
    private let minBarFraction: CGFloat = 0.08

    /// Prebuilt bar geometry, rebuilt only when the waveform/size changes — never
    /// on a playback tick. See `barsPath`.
    @State private var cache = BarsCache()

    /// Debounces scroll-driven seeks; see `ScrollSeekDebounce`.
    @State private var scrollSeek = ScrollSeekDebounce()

    /// The hover tooltip's measured width, used to keep it inside the bar.
    @State private var tooltipWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let duration = clock.duration
            let position = isScrubbing ? scrubTime : clock.currentTime
            let progress = duration > 0 ? min(max(position / duration, 0), 1) : 0

            Canvas { context, size in
                // Static bars, built once per (waveform, size). Per tick only the
                // progress clip moves: fill the whole waveform muted, then repaint
                // the played span in accent through a clip rect. Two fills, no
                // per-tick path building — the 10 Hz redraw stays nearly free.
                let bars = barsPath(size: size)
                let playedWidth = CGFloat(progress) * size.width

                // Paint the whole waveform (muted, then accent over the played span)
                // into a given context — reused at full and dimmed opacity.
                func paintWaveform(into ctx: GraphicsContext) {
                    ctx.fill(bars, with: .color(muted))
                    if playedWidth > 0 {
                        var played = ctx
                        played.clip(to: Path(CGRect(x: 0, y: 0, width: playedWidth, height: size.height)))
                        played.fill(bars, with: .color(accent))
                    }
                }

                // Hovering a chaptered track spotlights the section under the
                // cursor: dim the whole wave, then repaint just that section at full
                // brightness. No lines, no cuts — the wave stays whole, and you see
                // exactly which song a click would land on.
                if let hoverX = seekHoverX, duration > 0, !chapters.isEmpty {
                    var dimmed = context
                    dimmed.opacity = 0.3
                    paintWaveform(into: dimmed)

                    let (x0, x1) = hoveredSectionX(at: hoverX, width: size.width, duration: duration)
                    var section = context
                    section.clip(to: Path(CGRect(x: x0, y: 0, width: x1 - x0, height: size.height)))
                    paintWaveform(into: section)
                } else {
                    paintWaveform(into: context)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            // Hover anywhere to preview the time at that position.
            .overlay {
                if let x = seekHoverX, duration > 0 {
                    let frac = min(max(x / width, 0), 1)
                    // Just the time — the song/chapter name is already in the
                    // title line. Centred on the cursor, but clamped by the label's
                    // measured half-width so near either end it slides inward
                    // instead of spilling past the bar.
                    let half = min(tooltipWidth, width) / 2
                    TooltipLabel(text: clockTimeString(frac * duration))
                        .background(GeometryReader { proxy in
                            Color.clear
                                .onAppear { tooltipWidth = proxy.size.width }
                                .onChange(of: proxy.size.width) { _, w in tooltipWidth = w }
                        })
                        // Hidden until measured, so the first frame can't flash
                        // at an unclamped spot.
                        .opacity(tooltipWidth > 0 ? 1 : 0)
                        .position(x: min(max(x, half), width - half), y: -18)
                        .allowsHitTesting(false)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): seekHoverX = point.x
                case .ended: seekHoverX = nil
                }
            }
            // Click or drag anywhere on the waveform to seek. minimumDistance 0 so
            // a plain click (no drag) still lands a seek at that x.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        scrollSeek.cancel()   // the drag owns the scrub now
                        isScrubbing = true
                        // Snap live, so the playhead visibly magnetizes to a nearby
                        // boundary as you press/drag near it — not just on release.
                        scrubTime = snappedTime(atX: value.location.x, duration: duration, width: width)
                    }
                    .onEnded { value in
                        guard duration > 0 else { return }
                        engine.seek(to: snappedTime(atX: value.location.x, duration: duration, width: width))
                        isScrubbing = false
                    }
            )
            // Scroll over the bar to seek ±~3s per detent. Each event only moves
            // the scrub position; the one real seek commits the moment a trackpad
            // gesture ends (fingers lifted) or, for a wheel, once scrolling goes
            // quiet — see `ScrollSeekDebounce` for why. The trackpad's momentum
            // tail is ignored: it kept the scrub drifting (and the seek waiting)
            // for seconds after a hard flick.
            .scrollToAdjust(ignoresMomentum: true, onGestureEnd: { scrollSeek.flush() }) { units in
                guard duration > 0 else { return }
                let base = isScrubbing ? scrubTime : clock.currentTime
                scrubTime = min(max(base + units * 3, 0), duration)
                isScrubbing = true
                scrollSeek.schedule {
                    engine.seek(to: scrubTime)
                    isScrubbing = false
                }
            }
        }
        .frame(height: height)
    }

    /// The full mirrored-bar shape (both played and unplayed drawn in one colour by
    /// the caller). Rebuilt only when the waveform version or the canvas size
    /// changes; otherwise the cached `Path` is returned untouched, so a playback
    /// tick draws without allocating or looping. With no waveform yet (still
    /// generating, or unreadable) the bars fall to the `minBarFraction` floor, so
    /// the bar always reads as an intentional flat row rather than emptiness.
    ///
    /// Mutating the `@State` cache here is deliberate memoization: `BarsCache` is a
    /// plain reference type (nothing `@Published`), so updating its fields does not
    /// invalidate the view — it just remembers work across redraws.
    private func barsPath(size: CGSize) -> Path {
        let columns = max(1, Int(size.width / (barWidth + barGap)))
        if cache.matches(version: waveforms.version, columns: columns, height: size.height) {
            return cache.path
        }
        let peaks = resample(waveforms.waveform?.peaks ?? [], to: columns)
        let midY = size.height / 2
        var path = Path()
        for i in 0..<columns {
            let peak = peaks.isEmpty ? 0 : CGFloat(peaks[i])
            let barHeight = max(minBarFraction, peak) * (size.height - 2)
            let x = CGFloat(i) * (barWidth + barGap)
            let rect = CGRect(x: x, y: midY - barHeight / 2, width: barWidth, height: barHeight)
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2))
        }
        cache.store(path, version: waveforms.version, columns: columns, height: size.height)
        return path
    }

    /// The pixel span `[x0, x1)` of the chapter under horizontal position `x` — its
    /// start to the next chapter's start (or the end). Used to spotlight the hovered
    /// section. Assumes the track is chaptered (callers guard `!chapters.isEmpty`).
    private func hoveredSectionX(at x: CGFloat, width: CGFloat, duration: TimeInterval) -> (CGFloat, CGFloat) {
        let time = min(max(x / width, 0), 1) * duration
        let index = chapters.lastIndex { $0.start <= time + 0.001 } ?? 0
        let start = chapters[index].start
        let end = index + 1 < chapters.count ? chapters[index + 1].start : duration
        return (CGFloat(start / duration) * width, CGFloat(end / duration) * width)
    }

    /// The seek time for a press at horizontal position `x`, magnetized to a
    /// chapter boundary within a comfortable pixel radius — so aiming at a divider
    /// (or landing a touch either side) lands exactly on that section. Pixel-based,
    /// not time-based, so the pull feels the same on a 3-minute song and a 3-hour
    /// mix. No chapter in range → the raw position under the cursor.
    private func snappedTime(atX x: CGFloat, duration: TimeInterval, width: CGFloat) -> TimeInterval {
        let raw = min(max(x / width, 0), 1) * duration
        guard !chapters.isEmpty, width > 0 else { return raw }
        let tolerance: CGFloat = 12
        var nearest: (distance: CGFloat, start: TimeInterval)?
        for chapter in chapters {
            let boundaryX = CGFloat(chapter.start / duration) * width
            let distance = abs(boundaryX - x)
            if distance <= tolerance, nearest == nil || distance < nearest!.distance {
                nearest = (distance, chapter.start)
            }
        }
        return nearest?.start ?? raw
    }

    /// Reduce `peaks` to exactly `count` columns by taking the max over each
    /// column's source range (so transients survive downsampling). Returns the
    /// input unchanged when it already matches, or empty when there's no data.
    private func resample(_ peaks: [Float], to count: Int) -> [Float] {
        guard !peaks.isEmpty, count > 0 else { return [] }
        guard peaks.count != count else { return peaks }
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let start = i * peaks.count / count
            let end = max(start + 1, (i + 1) * peaks.count / count)
            var maxV: Float = 0
            for j in start..<min(end, peaks.count) { maxV = max(maxV, peaks[j]) }
            out[i] = maxV
        }
        return out
    }
}

/// Memoizes the seek bar's prebuilt bar `Path` so it's rebuilt only when the
/// waveform (by version) or the canvas geometry changes — not on every playback
/// tick. A reference type held in `@State` so the value persists across the view's
/// redraws.
private final class BarsCache {
    private(set) var path = Path()
    private var version = -1
    private var columns = -1
    private var height: CGFloat = -1

    func matches(version: Int, columns: Int, height: CGFloat) -> Bool {
        self.version == version && self.columns == columns && self.height == height
    }

    func store(_ path: Path, version: Int, columns: Int, height: CGFloat) {
        self.path = path
        self.version = version
        self.columns = columns
        self.height = height
    }
}

/// The now-playing title line. Shows the track's own title, and — for a chaptered
/// track (a long mix with per-song timestamps) — appends the current section's
/// name after a "·", tinted, so you see both "Mix Title · Current Song" on one
/// scrolling line. Observing the clock here keeps the ~10 Hz chapter updates scoped
/// to this one line rather than re-rendering the whole window.
struct NowPlayingTitle: View {
    @ObservedObject var clock: PlaybackClock
    let track: Track?
    let isScrubbing: Bool
    let scrubTime: TimeInterval
    let paused: Bool

    private var title: String {
        track?.displayTitle ?? "No track playing"
    }

    /// The "  ·  Current Chapter" suffix, or empty when the track isn't chaptered
    /// or the current section has no title.
    private var chapterSuffix: String {
        guard let track, !track.chapters.isEmpty else { return "" }
        let time = isScrubbing ? scrubTime : clock.currentTime
        if let name = track.chapters.last(where: { $0.start <= time + 0.001 })?.title,
           !name.isEmpty {
            return "  ·  \(name)"
        }
        return ""
    }

    var body: some View {
        MarqueeText(text: title, fontSize: 15, bold: true, color: .white,
                    suffix: chapterSuffix, suffixColor: Theme.logo, paused: paused)
            .copyOnClick(title, help: "Click to copy title", enabled: track != nil)
    }
}

/// The "00:34 / 03:12" readout. Observes the clock so only this label — not the
/// whole window — re-renders as the position ticks.
struct SeekTimeLabel: View {
    @ObservedObject var clock: PlaybackClock
    let isScrubbing: Bool
    let scrubTime: TimeInterval
    let accent: Color

    var body: some View {
        Text(clockTimeString(isScrubbing ? scrubTime : clock.currentTime)
             + " / " + clockTimeString(clock.duration))
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(accent)
            .fixedSize()
    }
}
