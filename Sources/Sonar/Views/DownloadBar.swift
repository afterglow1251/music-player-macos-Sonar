import SwiftUI
import AppKit

/// The download feature's presentation: the URL field with its progress-filling
/// capsule, the staged/queued chips strip below it, and the local URL-staging
/// logic (chip completion, dedup feedback, enqueue).
///
/// State stays on `PlayerWindow` and flows in via bindings — the bar renders in
/// two mutually-exclusive branches (normal vs fullscreen), so child-owned `@State`
/// would give each branch its own identity and wipe staged chips on a fullscreen
/// swap. `urlFieldFocused` likewise stays on the parent, where it gates the global
/// keyboard shortcuts; the bar only forwards it into the field.
struct DownloadBar: View {
    @ObservedObject var controller: PlayerController
    /// Observed directly — download progress/status aren't forwarded through
    /// `controller`, so their high-frequency ticks re-render only this bar.
    @ObservedObject var downloader: Downloader
    /// Links queued via the ＋ button. Owned by `PlayerWindow` so they survive the
    /// fullscreen branch swap; passed in as a binding.
    @Binding var urlChips: [String]
    /// Chip to shake when a dupe is re-added. Parent-owned for the same reason.
    @Binding var shakingChipURL: String?
    /// The URL field's focus, owned by `PlayerWindow` where it gates the global
    /// shortcuts. Forwarded into `SteadyTextField`.
    var urlFieldFocused: FocusState<Bool>.Binding

    /// Accent — the signature green, used sparingly.
    private let accent = Theme.accent

    // MARK: Download bar (YouTube URL → m4a)

    var body: some View {
        let downloading = controller.downloadsLeft > 0
        return VStack(spacing: 6) {
            HStack(spacing: 8) {
                // Spinner while downloading, link icon otherwise.
                Group {
                    if downloading {
                        ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14)
                    } else {
                        Image(systemName: "link").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    }
                }
                .frame(width: 16)

                // The field is always available — you can queue more links even while
                // a download is in flight. While downloading, its placeholder shows
                // the current status instead of the "paste a URL" hint, so nothing
                // shifts and the input never disappears.
                SteadyTextField(placeholder: (downloading || !urlChips.isEmpty)
                                    ? "Add another…"
                                    : "Paste a YouTube URL…",
                                text: $controller.urlInput,
                                onSubmit: { startDownload() },
                                focus: urlFieldFocused)
                    // A space finalises the URL before it: chip it right away (also
                    // handles pasting several space-separated links at once).
                    .onChange(of: controller.urlInput) { _, _ in chipCompletedURLs() }
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Status (Preparing… / Downloading X% / Processing…) lives here
                // now, so the field's placeholder can invite adding to the queue.
                if downloading {
                    AnimatedStatusText(status: downloader.status)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .fixedSize()
                }
                // How many are still queued behind the current download.
                if downloading && controller.downloadsLeft > 1 {
                    Text("\(controller.downloadsLeft)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .frame(minWidth: 16, minHeight: 16)
                        .padding(.horizontal, 3)
                        .background(Capsule().fill(accent))
                        .help("\(controller.downloadsLeft) downloads left")
                }
                // ＋ stages the current URL as a chip so you can line up several.
                if controller.urlInput.contains("http") {
                    Button { addURLChip() } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .help("Add another link")
                }
                // Download / enqueue — appends to the queue even mid-download.
                if !downloading || canDownload {
                    Button { startDownload() } label: {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(canDownload ? accent : .white.opacity(0.3))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .disabled(!canDownload)
                    .help(downloading ? "Add to queue"
                          : (urlChips.isEmpty ? "Download" : "Download \(pendingURLCount)"))
                }
                // Cancel everything while downloading — stays live through the
                // extract/embed phase too: with staging, cancelling then just
                // discards the half-written file instead of leaving a stray track.
                if downloading {
                    Button { controller.cancelDownload() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .help("Cancel all")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    // The capsule fills with accent as the download progresses.
                    if downloading {
                        GeometryReader { geo in
                            Capsule()
                                .fill(accent.opacity(0.22))
                                .frame(width: max(0, geo.size.width * downloader.progress))
                                .animation(.easeOut(duration: 0.3), value: downloader.progress)
                        }
                    }
                }
                .clipShape(Capsule())
            )

            // Chips sit in a reserved slot BELOW the field. The slot keeps a
            // fixed height in BOTH states (input and downloading) so nothing —
            // not the field above nor anything below — ever shifts. Queued
            // chips stay put through their own download and disappear only
            // once that item finishes, so the slot is only empty when there's
            // truly nothing staged or in flight.
            chipsStrip
                .frame(height: 24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)

            if !downloading, let missing = downloader.missingToolMessage {
                Text(missing)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: downloading)
    }

    private var chipsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                // Queued/downloading first (left): submitted, stays until its own
                // download finishes. The active one can't be removed individually —
                // use the cancel-all button next to the field for that.
                ForEach(controller.downloadQueue) { item in
                    let isActive = item.id == controller.currentDownloadID
                    urlChip(label: shortURL(item.url), active: isActive, shaking: shakingChipURL == item.url) {
                        controller.removeFromQueue(item.id)
                    }
                }
                // Staged (right): typed via ＋, not yet submitted — always removable.
                // Kept AFTER the queue so a staged chip promoting to a queued one
                // appears in place instead of sliding the row leftward (which read
                // as a right-to-left animation).
                ForEach(Array(urlChips.enumerated()), id: \.offset) { index, url in
                    urlChip(label: shortURL(url), active: false, shaking: shakingChipURL == url) {
                        urlChips = urlChips.enumerated().filter { $0.offset != index }.map(\.element)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One chip. `active` chips (currently downloading) show a spinner instead
    /// of the link icon and drop their remove button.
    private func urlChip(label: String, active: Bool, shaking: Bool = false,
                         onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            if active {
                ProgressView().controlSize(.mini).scaleEffect(0.55).frame(width: 8, height: 8)
            } else {
                Image(systemName: "link").font(.system(size: 8, weight: .bold)).foregroundStyle(accent)
            }
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
            if !active {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { onRemove() }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        // Flash a stronger accent while shaking, so the eye lands on the dupe.
        .background(Capsule().fill(accent.opacity(shaking ? 0.30 : 0.14)))
        .overlay(Capsule().stroke(accent.opacity(shaking ? 0.7 : 0.25)))
        .modifier(Shake(animatableData: shaking ? 1 : 0))
        .animation(.linear(duration: 0.4), value: shaking)
        // Fade in (no centre-anchored scale, which made the capsule pop and the
        // label appear to slide into place); keep the tidy scale-out on removal.
        .transition(.asymmetric(insertion: .opacity,
                                removal: .scale.combined(with: .opacity)))
    }

    private var canDownload: Bool {
        downloader.isAvailable && (!urlChips.isEmpty || controller.urlInput.contains("http"))
    }

    private var pendingURLCount: Int {
        urlChips.count + (controller.urlInput.contains("http") ? 1 : 0)
    }

    /// The single dedup membership test: is this URL already staged (a not-yet-
    /// submitted chip we own) or already in the download queue (the controller's
    /// to answer)? Keeps the "shake the existing chip" rule in one place; library
    /// membership is a separate check via `controller.isAlreadyDownloaded`.
    private func isStagedOrQueued(_ url: String) -> Bool {
        urlChips.contains(url) || controller.isQueued(url)
    }

    /// Called as the field changes: any token the user has "finished" with a
    /// space (typed or pasted) becomes a chip immediately, if it's a valid URL.
    /// Whatever is still being typed after the last space stays in the field.
    private func chipCompletedURLs() {
        guard controller.urlInput.contains(" ") else { return }
        while let space = controller.urlInput.firstIndex(of: " ") {
            let head = String(controller.urlInput[..<space]).trimmingCharacters(in: .whitespaces)
            let tail = String(controller.urlInput[controller.urlInput.index(after: space)...])
            if head.isEmpty { controller.urlInput = tail; continue }  // stray/leading space
            // Stop at the first non-URL token so we never eat plain text.
            guard head.contains("http") else { break }
            if controller.isAlreadyDownloaded(head) {   // instant, no yt-dlp
                downloader.notice = "Already in library"
                controller.urlInput = tail
                continue
            }
            if !isStagedOrQueued(head) {
                withAnimation(.easeInOut(duration: 0.2)) { urlChips.append(head) }
            } else {
                flagDuplicate(head)   // already staged/queued — shake it, don't silently drop
            }
            controller.urlInput = tail
        }
    }

    /// Turn the current field into a chip so another link can be added.
    /// Skips URLs already staged or already queued/downloading.
    private func addURLChip() {
        let url = controller.urlInput.trimmingCharacters(in: .whitespaces)
        guard url.contains("http") else { return }
        if controller.isAlreadyDownloaded(url) {         // instant, no yt-dlp
            downloader.notice = "Already in library"
            controller.urlInput = ""
            urlFieldFocused.wrappedValue = true
            return
        }
        guard !isStagedOrQueued(url) else {
            flagDuplicate(url)          // it's already staged/queued — shake that chip
            controller.urlInput = ""
            urlFieldFocused.wrappedValue = true
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) { urlChips.append(url) }
        controller.urlInput = ""
        urlFieldFocused.wrappedValue = true
    }

    /// Shake the existing chip for `url` so re-adding a duplicate reads as a
    /// deliberate "already here" instead of nothing happening. Reset to nil first
    /// so the false→true transition re-fires even on a rapid repeat.
    private func flagDuplicate(_ url: String) {
        shakingChipURL = nil                       // re-arm so a rapid repeat re-fires
        DispatchQueue.main.async {
            shakingChipURL = url                   // the chip animates the shake off this
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
                if shakingChipURL == url { shakingChipURL = nil }
            }
        }
    }

    /// Enqueue every staged chip plus the field's URL. A field URL that's already
    /// staged/queued gets the same feedback as ＋ — shake the existing chip instead
    /// of being silently dropped — and one already in the library shows the notice.
    private func startDownload() {
        let field = controller.urlInput.trimmingCharacters(in: .whitespaces)
        if field.contains("http") {
            if controller.isAlreadyDownloaded(field) {
                downloader.notice = "Already in library"
                controller.urlInput = ""
            } else if isStagedOrQueued(field) {
                flagDuplicate(field)          // already staged/queued — shake that chip
                controller.urlInput = ""
            }
        }

        let all = (urlChips + [controller.urlInput])
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !all.isEmpty else { return }
        controller.download(all.joined(separator: "\n"))   // clears urlInput
        withAnimation(.easeInOut(duration: 0.2)) { urlChips = [] }
        urlFieldFocused.wrappedValue = false
    }

    /// A compact label for a chip: the YouTube id if present, else the host.
    private func shortURL(_ url: String) -> String {
        if let match = url.firstMatch(of: /(?:v=|youtu\.be\/|shorts\/)([A-Za-z0-9_-]{11})/) {
            return "▶ \(match.1)"
        }
        return URL(string: url)?.host ?? String(url.prefix(22))
    }
}
