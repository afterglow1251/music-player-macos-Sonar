import AppKit
import SwiftUI
import Combine

/// Whether the main player window is already the frontmost, focused window —
/// i.e. whether the panel's "show main window" button would have nothing to do.
@MainActor
final class MainWindowVisibility: ObservableObject {
    @Published var isFrontmost = false
}

/// A menu-bar presence for Sonar: a status-bar button that reflects play state and
/// pops a compact now-playing panel with transport controls — so you can steer
/// playback without leaving whatever app you're in.
@MainActor
final class MenuBarController {
    private let controller: PlayerController
    private let statusItem: NSStatusItem
    private let windowVisibility = MainWindowVisibility()
    private var cancellable: AnyCancellable?
    private var clickMonitor: Any?
    private var pressMonitor: Any?
    private var isPanelOpen = false
    /// Set true the first time the panel's occlusion becomes `.visible` after an
    /// open. The occlusion-driven dismiss only arms once this is true, so the
    /// initial not-visible→visible transition of opening can't dismiss the panel
    /// it's still bringing on screen.
    private var panelDidAppear = false
    /// The app that owned focus when the panel was opened. A non-activating panel
    /// leaves that app frontmost, and opening over another app's fullscreen Space
    /// makes that app re-post `didActivateApplication` — which must NOT close the
    /// panel. Only activation of a *different* app (a real Cmd-Tab away) does.
    private var frontmostAppAtOpen: pid_t?

    private lazy var panel: NSPanel = {
        // A plain `NSPanel` suffices: every control in the panel is custom-drawn
        // (waveform seek bar, PressButtons), so nothing consults the window's
        // key-appearance state. Historically this was a `KeyAppearancePanel`
        // shadowing private appearance accessors — needed only while the seek
        // control was an AppKit-backed `Slider` that grayed out in a non-key
        // window.
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 268, height: 150),
            styleMask: [.fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        p.isFloatingPanel = true
        p.level = .popUpMenu
        // `.transient`, NOT `.stationary` — they're mutually exclusive flavors of
        // the same window-management group. `.stationary` is desktop-widget
        // semantics: the WindowServer pins such windows to the desktop backdrop
        // and refuses to composite them over another app's fullscreen Space, so
        // the panel "opened" where you couldn't see it (occlusion never became
        // .visible). `.transient` is what native popup menus use, and those render
        // over fullscreen apps just fine. `.fullScreenAuxiliary` additionally
        // admits the panel onto the active fullscreen Space.
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.hasShadow = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false
        p.animationBehavior = .none

        // No content yet — the hosting controller is attached on open and torn
        // down on close (see `togglePanel`/`dismiss`). An ordered-out panel's
        // NSHostingView still processes SwiftUI updates, so a persistent one
        // kept the marquee's per-frame TimelineView and every re-render running
        // while the panel was "closed". Detaching makes a closed panel free.

        // Dismiss when a Spaces swipe / Mission Control gesture hides the panel.
        // During those transitions the WindowServer takes windows like this
        // panel off screen, which flips its occlusion state to not-visible —
        // the earliest signal we get that a space gesture began. Without this,
        // a half-swipe that snaps back would "restore" a panel the user
        // expected gone (native popovers close for good), and a completed
        // swipe only closed it ~1s later via app-activation.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: p, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPanelOpen else { return }
                let visible = self.panel.occlusionState.contains(.visible)
                if visible {
                    // The panel has actually landed on screen — arm the dismiss.
                    self.panelDidAppear = true
                    return
                }
                // Only a visible→not-visible transition (a real Spaces swipe /
                // Mission Control move that hides the panel) closes it. The
                // not-visible state *before* the panel has ever appeared is just
                // the opening transition and must be ignored.
                guard self.panelDidAppear else { return }
                self.dismiss()
            }
        }
        return p
    }()

    init(controller: PlayerController) {
        self.controller = controller
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = Self.icon
            button.imagePosition = .imageLeading
            button.alignment = .left
        }

        // Toggle on mouse-DOWN via a local monitor that swallows the event,
        // instead of a button action (which AppKit sends on mouse-up). A button
        // action lets NSButtonCell run its press-tracking, and on mouse-up AppKit
        // clears the highlight AFTER our code runs — sometimes a runloop
        // iteration later — so a dark frame gets committed and the button blinks.
        // Swallowing the mouse-down means that tracking never starts, so nothing
        // ever competes with our `isHighlighted` state. Opening on press also
        // matches native menu-bar menus. (Cmd-click passes through so the item
        // can still be drag-reordered in the menu bar.)
        //
        // This same monitor also dismisses the panel on clicks elsewhere in our
        // OWN app's windows (e.g. the main player window, including while it's
        // fullscreen) — the global monitor below only sees clicks in *other*
        // apps, so without this a click on our own window never closed the panel.
        pressMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if let button = self.statusItem.button, event.type == .leftMouseDown,
               event.window === button.window, !event.modifierFlags.contains(.command) {
                self.togglePanel(nil)
                return nil
            }
            if self.isPanelOpen, event.window !== self.panel {
                self.dismiss()
            }
            return event
        }

        // Also dismiss when the app resigns active (e.g. Cmd-Tab to another app)
        // — a plain click-away monitor never fires for that since no click occurs.
        //
        // `willResignActive`, not `didResignActive`: "did" only fires once macOS
        // has *finished* animating the app switch (~0.3-0.5s later), so the panel
        // sat on screen through the whole transition before closing. "will" fires
        // right as the switch starts, so the panel is gone before the animation
        // even plays.
        //
        // `MainActor.assumeIsolated`, not `Task { @MainActor in ... }`: `queue:
        // .main` already guarantees this closure runs on the main thread, so
        // hopping through a Task would just defer the dismiss to the next runloop
        // turn — long enough for the panel to visibly flash before closing.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }

        // `willResignActiveNotification` only fires when SONAR ITSELF was the
        // active app — but the panel is a `.nonactivatingPanel`, so opening it
        // from the menu bar never activates Sonar. The common case is: some
        // other app is active, you open the panel, then switch (Cmd-Tab) to a
        // different app — Sonar's active state never changes, so that
        // notification never fires. Watching the workspace-wide "an app became
        // active" notification catches this regardless of whether Sonar was ever
        // active.
        //
        // But we must ignore the app that was already frontmost when the panel
        // opened. Opening a non-activating panel over another app's fullscreen
        // Space makes THAT app re-post `didActivateApplication`, which would
        // otherwise slam the panel shut the instant it appears. Only a switch to
        // a genuinely *different* app is a real move away that should close it.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier
            else { return }
            MainActor.assumeIsolated {
                guard let self, self.isPanelOpen,
                      app.processIdentifier != self.frontmostAppAtOpen
                else { return }
                self.dismiss()
            }
        }

        // NOTE: no `activeSpaceDidChangeNotification` observer. It fired on every
        // switch to a fullscreen app (each is its own Space) — including the
        // Space churn caused by the panel's own appearance — and slammed the
        // panel shut. Real Spaces swipes are handled by the occlusion observer:
        // the WindowServer hides the panel mid-swipe, flipping it visible→
        // not-visible, which is what closes it.

        // Keep the panel's "show main window" button hidden whenever it'd have
        // nothing to do — i.e. whenever the main window is already the frontmost,
        // focused window (including fullscreen: a fullscreen window is still key).
        for name: Notification.Name in [
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
        ] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshWindowVisibility() }
            }
        }
        refreshWindowVisibility()

        cancellable = controller.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refreshButton() }
        refreshButton()
    }

    private func refreshWindowVisibility() {
        let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "player" })
        windowVisibility.isFrontmost = NSApp.isActive && (window.map(Self.isFrontOrdinaryWindow) ?? false)
    }

    /// Whether `window` is the front-most ordinary window on screen — i.e. no
    /// other normal-level Sonar window sits in front of it.
    ///
    /// Uses window *ordering*, NOT `isKeyWindow`, on purpose. Any tracking menu
    /// — including another app's menu-bar-extra menu (e.g. Postgres's) — makes
    /// the current key window momentarily resign key while the menu is open,
    /// then become key again when it closes. Keying "is the main window
    /// frontmost" off that flickered while such a menu opened just before the
    /// panel: the panel appeared with the "show main window" button on (main
    /// window "not frontmost"), then the button vanished a beat later when the
    /// window re-became key. Window ordering never flickers for a menu, so this
    /// stays steady across the whole open. The status panel itself is at
    /// `.popUpMenu` level, so filtering to `.normal` windows excludes it.
    private static func isFrontOrdinaryWindow(_ window: NSWindow) -> Bool {
        guard window.isVisible, !window.isMiniaturized else { return false }
        let ordinary = NSApp.orderedWindows.filter { $0.isVisible && $0.level == .normal }
        return ordinary.first === window
    }

    private static let titleWidth: CGFloat = 160

    private func refreshButton() {
        guard let button = statusItem.button else { return }
        // Icon only. Showing the track title made the item ~160px wide, so on a
        // crowded menu bar (many extras + the notch) macOS couldn't fit it and
        // hid the whole thing — losing even the icon. A plain icon always fits.
        button.image = Self.icon
        statusItem.length = NSStatusItem.variableLength
        button.title = ""

        // TODO: DO NOT DELETE — original title-in-the-menu-bar behavior, kept for
        // when we implement a proper "show title only while it fits" fallback.
        // if let track = controller.currentTrack {
        //     statusItem.length = Self.titleWidth
        //     button.attributedTitle = Self.title(track.displayTitle)
        // } else {
        //     statusItem.length = NSStatusItem.variableLength
        //     button.title = ""
        // }

        // Redrawing the button (icon/title) can drop the highlight, so re-assert
        // the open-state indication every refresh.
        setOpenIndication(isPanelOpen)
    }

    private static func title(_ text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: " " + text, attributes: [
            .paragraphStyle: paragraph,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
        ])
    }

    private static let icon: NSImage? = {
        let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Sonar")
        image?.isTemplate = true
        return image
    }()

    // MARK: Panel

    private func makeHosting() -> NSViewController {
        NSHostingController(
            rootView: MiniPlayerView(controller: controller, clock: controller.engine.clock,
                                      windowVisibility: windowVisibility) { [weak self] in
                // Close the panel first — otherwise the main window becoming key
                // flips `windowVisibility.isFrontmost` while the panel is still
                // showing, and the header re-lays-out (button vanishing, artist
                // label shifting) right before your eyes.
                self?.dismiss()
                Self.showMainWindow()
            }
        )
    }

    private func togglePanel(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if panel.isVisible {
            dismiss()
        } else {
            // Compute the "show main window" button's visibility from the live
            // window state right now, so the panel's first frame is already
            // correct instead of inheriting whatever the last notification left.
            refreshWindowVisibility()
            panel.contentViewController = makeHosting()
            // Size the panel to its SwiftUI content BEFORE positioning. On the
            // first open the content hasn't laid out yet, so the panel still
            // reports its placeholder height — if we position against that, the
            // window then grows upward to fit and its top slides off-screen.
            if let content = panel.contentView {
                content.layoutSubtreeIfNeeded()
                panel.setContentSize(content.fittingSize)
            }
            let buttonRect = button.convert(button.bounds, to: nil)
            let screenRect = button.window?.convertToScreen(buttonRect) ?? .zero
            panel.setFrameOrigin(NSPoint(
                x: screenRect.midX - panel.frame.width / 2,
                y: screenRect.minY - panel.frame.height - 4
            ))
            // Reset the "has appeared" latch and record who owns focus, BEFORE
            // ordering front — opening can synchronously post the occlusion /
            // activation notifications the dismiss logic reads.
            panelDidAppear = false
            frontmostAppAtOpen = NSWorkspace.shared.frontmostApplication?.processIdentifier
            panel.orderFrontRegardless()
            // NOTE: deliberately NOT making the panel key. Becoming key triggers a
            // key-window change that redraws the status button mid-click and blinks
            // its highlight OFF for a frame.
            isPanelOpen = true
            setOpenIndication(true)
            installClickMonitor()
        }
    }

    /// Reflect the panel's open state on the status button, the way native
    /// menu-bar menus stay lit while open.
    ///
    /// Uses `state = .on` + the persistent `isHighlighted` property — NOT the
    /// momentary `highlight(_:)` method, which is the press-tracking API. Since
    /// the mouse-down monitor swallows clicks before NSButtonCell can start
    /// tracking, nothing in AppKit ever clears this state behind our back.
    private func setOpenIndication(_ on: Bool) {
        guard let button = statusItem.button else { return }
        button.state = on ? .on : .off
        button.isHighlighted = on
    }

    private func installClickMonitor() {
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            self?.dismiss()
        }
    }

    private func removeClickMonitor() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }

    private func dismiss() {
        isPanelOpen = false
        panelDidAppear = false
        frontmostAppAtOpen = nil
        panel.orderOut(nil)
        // Drop the SwiftUI content — a hidden panel's hosting view would keep
        // re-rendering (marquee frames, playback ticks) at full cost otherwise.
        panel.contentViewController = nil
        setOpenIndication(false)
        removeClickMonitor()
    }

    private static func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "player" }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
    }
}

/// The compact now-playing panel shown from the menu-bar button.
private struct MiniPlayerView: View {
    @ObservedObject var controller: PlayerController
    /// NOT observed here — the 10 Hz tick would rebuild the whole panel. Only
    /// the leaves that render the position (the waveform bar, the time labels)
    /// observe it, mirroring the main window's isolation.
    let clock: PlaybackClock
    @ObservedObject var windowVisibility: MainWindowVisibility
    let onShowMain: () -> Void

    private var engine: AudioEngine { controller.engine }
    private let accent = Theme.accent
    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0
    @State private var seekHoverX: CGFloat?

    var body: some View {
        VStack(spacing: 10) {
            header
            progress
            transport
        }
        .padding(12)
        .frame(width: 268)
        .modifier(PanelSurface())
        .tint(accent)
    }

    private var header: some View {
        HStack(spacing: 10) {
            artwork
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 0) {
                    // Scrolls when the title overflows, matching the main window's
                    // now-playing title. `.frame(maxWidth: .infinity)` gives the
                    // marquee all the room left after the fixed "show main" button.
                    MiniTitle(clock: clock, track: controller.currentTrack,
                              isScrubbing: isScrubbing, scrubTime: scrubTime)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // Hidden (not just disabled) while the main window is already
                    // frontmost — clicking it then would have nothing to do.
                    if !windowVisibility.isFrontmost {
                        PressButton(action: onShowMain) {
                            Image(systemName: "macwindow")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .padding(6)
                                .contentShape(Rectangle())
                        }
                        .help("Show Sonar")
                    }
                }
                if let artist = controller.currentTrack?.artist, !artist.isEmpty {
                    MarqueeText(text: artist, fontSize: 11, weight: .regular, color: .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var artwork: some View {
        Group {
            if let data = controller.currentTrack?.artworkData, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.black.opacity(0.25)
                    Image(systemName: "music.note").font(.system(size: 16)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var progress: some View {
        VStack(spacing: 3) {
            // The same waveform seek bar as the main window, sized down for the
            // panel. `muted` uses `.primary` (not the main window's white) because
            // the panel's `.menu` material follows the system appearance — white
            // bars would vanish on the light material. Scrubbing, hover preview
            // and scroll-to-seek all come with it.
            WaveformSeekBar(clock: clock, waveforms: controller.waveforms,
                            engine: engine, accent: accent,
                            chapters: controller.currentTrack?.chapters ?? [],
                            isScrubbing: $isScrubbing, scrubTime: $scrubTime,
                            seekHoverX: $seekHoverX,
                            height: 20, muted: .primary.opacity(0.25))
            MiniTimeLabels(clock: clock)
        }
    }

    private var transport: some View {
        HStack(spacing: 24) {
            control("backward.end.fill") { controller.previous() }
            control(engine.isPlaying ? "pause.fill" : "play.fill", size: 20) { controller.togglePlayPause() }
            control("forward.end.fill") { controller.next() }
        }
    }

    private func control(_ symbol: String, size: CGFloat = 15, action: @escaping () -> Void) -> some View {
        PressButton(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
    }

}

/// The panel's title line — the main window's "Mix Title · Current Song" reading,
/// panel-sized. A leaf that observes the clock, so the ~10 Hz chapter updates
/// re-render just this marquee, not the whole panel (see `NowPlayingTitle`).
private struct MiniTitle: View {
    @ObservedObject var clock: PlaybackClock
    let track: Track?
    let isScrubbing: Bool
    let scrubTime: TimeInterval

    /// The "  ·  Current Chapter" suffix, or empty when the track isn't chaptered
    /// or the current section has no title. Follows the scrub position while
    /// scrubbing, matching the main window.
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
        MarqueeText(text: track?.displayTitle ?? "Nothing playing",
                    fontSize: 12, weight: .semibold, color: .primary,
                    suffix: chapterSuffix, suffixColor: Theme.logo)
    }
}

/// The panel's elapsed/total corner labels. A leaf that observes the clock, so
/// the 10 Hz playback tick re-renders just these two Texts — not the panel.
private struct MiniTimeLabels: View {
    @ObservedObject var clock: PlaybackClock

    var body: some View {
        HStack {
            Text(clockTimeString(clock.currentTime, padMinutes: false)).font(.system(size: 9, design: .monospaced))
            Spacer()
            Text(clockTimeString(clock.duration, padMinutes: false)).font(.system(size: 9, design: .monospaced))
        }
        .foregroundStyle(.secondary)
    }
}

/// The panel's translucent background surface.
///
/// On macOS 26+ this is the real Liquid Glass material (`.glassEffect`) — the
/// same surface native menus adopt on Tahoe, so the panel reads as glass with
/// specular edges instead of the flat legacy vibrancy. `NSVisualEffectView`
/// deliberately did NOT become Liquid Glass on Tahoe (Apple kept it as-is for
/// compatibility), so we can't get the new look just by keeping the `.menu`
/// material — glass is a separate opt-in API.
///
/// On earlier macOS the glass API doesn't exist, so we fall back to the
/// behind-window `.menu` vibrancy with a hairline edge to fake the boundary the
/// glass draws for itself.
private struct PanelSurface: ViewModifier {
    private static let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            // `.glassEffect` renders the glass within `shape` and samples the
            // desktop/other apps behind the (transparent) panel window, so it
            // fully replaces the behind-window `NSVisualEffectView`. It also
            // owns its corner + edge treatment, so no clip or stroke is needed.
            content.glassEffect(.regular, in: Self.shape)
        } else {
            content
                .background(VisualEffect(material: .menu))
                .clipShape(Self.shape)
                .overlay(Self.shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        }
    }
}

/// A native visual-effect view (`NSVisualEffectView`) bridged for SwiftUI —
/// the pre-Tahoe fallback background (see `PanelSurface`).
private struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// A button that dims (and dips) while held — the way native controls respond.
///
/// Press state is driven by a `DragGesture`, not `ButtonStyle.isPressed`, because
/// inside an `NSPopover` the button-style press state doesn't update reliably,
/// whereas a drag gesture does (the seek bar uses one and works). The `Button`
/// still owns the action so it only fires on a real click released inside.
private struct PressButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder var label: Label
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            label
                .opacity(pressed ? 0.4 : 1)
                .scaleEffect(pressed ? 0.9 : 1)
                .animation(.easeOut(duration: 0.08), value: pressed)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
    }
}
