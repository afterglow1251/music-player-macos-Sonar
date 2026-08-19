import Foundation
import Darwin
import SQLite3

/// Thread-safe string accumulator for subprocess output collected off the main thread.
private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""
    func append(_ text: String) { lock.lock(); storage += text; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return storage }
}

/// Downloads audio from a URL (YouTube etc.) by shelling out to `yt-dlp`,
/// keeping the source's native AAC stream as m4a (no re-encode) with embedded
/// artwork and metadata; only sources with no m4a stream get transcoded.
///
/// GUI apps don't inherit the shell's PATH, so we locate the binaries in the
/// usual Homebrew/system locations and pass an explicit PATH to the subprocess.
@MainActor
final class Downloader: ObservableObject {
    @Published var isDownloading = false
    @Published var progress: Double = 0      // 0...1
    @Published var status: String = ""
    /// True during the post-download extract/embed phase (ExtractAudio + thumbnail
    /// and metadata), used to surface a "Processing…" status. Cancelling here is
    /// safe now: the intermediate lives in staging and is discarded on abort.
    @Published private(set) var isConverting = false
    /// Set on a failure so the UI can show a transient error toast.
    @Published var lastError: String?
    /// Set for a transient, non-error info toast (e.g. "Already in library").
    @Published var notice: String?

    private let ytDlpPath: String?
    private let ffmpegPath: String?
    private let toolsDir: String
    private var currentProcess: Process?
    private var cancelled = false
    /// Browsers we can borrow YouTube cookies from, freshest jar first. Computed
    /// once, lazily, so the disk probe never runs for a user who never downloads.
    private lazy var cookieBrowsers = Downloader.availableCookieBrowsers()

    init() {
        // `~/.local/bin` first: a hand-installed yt-dlp (pipx/uv) is nearly always
        // newer than the packaged one, and YouTube breaks yt-dlp often enough that
        // newer wins. ffmpeg is located on its own — it rarely lives beside a
        // pip-installed yt-dlp, so it can't be assumed to share a directory.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let binDirs = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        func locate(_ tool: String) -> String? {
            binDirs.map { "\($0)/\(tool)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
        }
        ytDlpPath = locate("yt-dlp")
        ffmpegPath = locate("ffmpeg")
        toolsDir = ffmpegPath.map { ($0 as NSString).deletingLastPathComponent } ?? "/opt/homebrew/bin"
    }

    /// Both tools are needed: yt-dlp fetches the stream, ffmpeg extracts the audio
    /// and embeds artwork. Missing ffmpeg used to surface only once a download had
    /// already run and failed halfway, so it's checked up front alongside yt-dlp.
    var isAvailable: Bool { missingToolMessage == nil }

    /// The install hint to show when a tool is absent; nil when both are present.
    var missingToolMessage: String? {
        switch (ytDlpPath, ffmpegPath) {
        case (nil, nil): "yt-dlp and ffmpeg not found — run: brew install yt-dlp ffmpeg"
        case (nil, _): "yt-dlp not found — run: brew install yt-dlp"
        case (_, nil): "ffmpeg not found — run: brew install ffmpeg"
        default: nil
        }
    }

    /// Cancel the in-flight download, if any.
    func cancel() {
        cancelled = true
        let process = currentProcess
        process?.terminate()   // SIGTERM
        // Escalate to SIGKILL if it's still alive after a short grace window.
        // Scheduled off the main actor so it never blocks, and gated on the
        // captured instance's `isRunning` so we never signal a bare, recycled PID.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if let process, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    func beginChecking() {
        cancelled = false
        lastError = nil
        isDownloading = true
        progress = 0
        status = "Checking…"
    }

    func finishChecking(message: String) {
        isDownloading = false
        status = message
    }

    /// Fetch the video id (no download) so callers can dedupe against the library.
    func fetchVideoID(_ urlString: String) async -> String? {
        guard ytDlpPath != nil else { return nil }
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isValidURL(trimmed) else { return nil }
        // No cookie escalation here: the id is only used to dedupe, and failing
        // it just means the download proceeds. Not worth a Keychain prompt.
        let result = await runYtDlp(["--print", "%(id)s", "--skip-download", "--no-playlist", "--", trimmed],
                                    allowCookies: false)
        let id = result.output.split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (id?.isEmpty == false) ? id : nil
    }

    /// Download `urlString` into `stagingDir` (a fresh, hidden dir the library
    /// hands us). Returns the new m4a's URL on success; the caller adopts it into
    /// the library and discards the staging dir on every exit path.
    func download(_ urlString: String, into stagingDir: URL) async -> URL? {
        if let message = missingToolMessage {
            lastError = message
            status = message
            return nil
        }
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard isValidURL(trimmed) else {
            let message = "Download failed — invalid URL"
            lastError = message
            status = message
            return nil
        }

        // Don't reset `cancelled` here — it's cleared once per item in
        // beginChecking(). If the user hit cancel during the checking phase, bail
        // now instead of starting the download.
        if cancelled { status = "Cancelled"; isDownloading = false; return nil }

        lastError = nil
        isDownloading = true
        progress = 0
        status = "Preparing…"
        isConverting = false
        defer { isDownloading = false; isConverting = false }

        // Prefer the native AAC (m4a) stream so the audio is stored bit-exact —
        // no lossy re-encode, no conversion wait. `--audio-format m4a` only
        // transcodes when the fallback (`bestaudio`, e.g. Opus) was the sole
        // option, keeping every download in a container AVFoundation can play.
        let args = ["-f", "bestaudio[ext=m4a]/bestaudio",
                    "-x", "--audio-format", "m4a", "--audio-quality", "0",
                    "--no-playlist", "--embed-thumbnail", "--add-metadata",
                    // Carry over the video's chapters (YouTube builds them from the
                    // description's timestamps) so a long mix stays navigable
                    // section-by-section. No-op when the source has none.
                    "--embed-chapters",
                    // Fill the artist tag from the channel when the video has no
                    // artist of its own (keeps a real artist tag where present).
                    "--parse-metadata", "%(artist,uploader)s:%(artist)s",
                    "--newline",
                    "--ffmpeg-location", toolsDir,
                    "-o", stagingDir.appendingPathComponent("%(title)s [%(id)s].%(ext)s").path,
                    "--", trimmed]

        let attempt = await runYtDlp(args)
        if cancelled {
            status = "Cancelled"
            return nil
        }
        guard attempt.code == 0 else {
            lastError = Downloader.errorMessage(for: attempt.output)
            status = "Failed"
            return nil
        }

        // The staging dir was freshly created for this one download, so the m4a
        // yt-dlp just wrote is the only one in it.
        let produced = (try? FileManager.default.contentsOfDirectory(
            at: stagingDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let result = produced.first { $0.pathExtension.lowercased() == "m4a" }

        status = result != nil ? "Done" : "File not found"
        progress = 1
        return result
    }

    // MARK: Subprocess

    /// Run yt-dlp, escalating to browser cookies when YouTube answers with its
    /// "confirm you're not a bot" wall (or an age gate) instead of the video.
    ///
    /// The first attempt stays anonymous, so the common case costs nothing: cookies
    /// are only reached for once YouTube actually demands them. Reading a Chromium
    /// browser's jar needs its Keychain key, which puts a system prompt in front of
    /// the user — hence at most two browsers, freshest first, rather than a march
    /// through every one installed.
    private func runYtDlp(_ arguments: [String],
                          allowCookies: Bool = true) async -> (code: Int32, output: String) {
        guard let ytDlpPath else { return (-1, "") }
        let browsers = allowCookies ? Array(cookieBrowsers.prefix(2)) : []
        var code: Int32 = -1
        var output = ""

        for attempt in 0...browsers.count {
            let cookieArgs = attempt == 0
                ? []
                : ["--cookies-from-browser", browsers[attempt - 1].name]
            let box = OutputBox()
            code = await run(executable: ytDlpPath, arguments: cookieArgs + arguments,
                             collect: { box.append($0) })
            output = box.value

            if code == 0 || cancelled { break }
            // `attempt` indexes the browser we just used; the next one is at the
            // same index in `browsers`, so this both bounds-checks and names it.
            guard Downloader.needsSignIn(output), attempt < browsers.count else { break }
            status = "Retrying with \(browsers[attempt].display)…"
            progress = 0
        }
        return (code, output)
    }

    private func run(executable: String, arguments: [String],
                     collect: (@Sendable (String) -> Void)? = nil) async -> Int32 {
        // Already cancelled before we even started — don't launch the process.
        if cancelled { return -1 }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "\(toolsDir):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            process.environment = env

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            let handle = pipe.fileHandleForReading
            handle.readabilityHandler = { [weak self] fh in
                let data = fh.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                if let collect { collect(text) }
                let percent = Downloader.parsePercent(text)
                let converting = text.contains("[ExtractAudio]") || text.contains("Destination")
                Task { @MainActor in
                    guard let self else { return }
                    if let percent {
                        self.progress = percent / 100
                        self.status = "Downloading \(Int(percent))%"
                        self.isConverting = false
                    } else if converting {
                        self.status = "Processing…"
                        self.isConverting = true
                    }
                }
            }

            process.terminationHandler = { proc in
                handle.readabilityHandler = nil
                continuation.resume(returning: proc.terminationStatus)
            }

            currentProcess = process
            do {
                try process.run()
            } catch {
                handle.readabilityHandler = nil
                continuation.resume(returning: -1)
            }
        }
    }

    // MARK: Cookies

    /// A browser yt-dlp can lift YouTube cookies out of.
    struct CookieBrowser: Hashable {
        /// The token `--cookies-from-browser` expects.
        let name: String
        /// Human-facing name, for the retry status line.
        let display: String
    }

    /// Browsers holding a signed-in YouTube session, most recently used first.
    ///
    /// Two filters, in order. A jar only qualifies if it actually contains session
    /// cookies — a browser that's merely installed, or that visited YouTube while
    /// logged out, can't get us past the bot wall, and offering it would spend the
    /// user's one Keychain prompt on a guaranteed failure. Qualifying jars are then
    /// ranked by mtime, the cheapest signal for which browser the user lives in.
    nonisolated static func availableCookieBrowsers(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [CookieBrowser] {
        let library = home.appendingPathComponent("Library")
        let support = library.appendingPathComponent("Application Support")

        // Chromium keeps cookies at <profile>/Cookies, moved under <profile>/Network
        // in Chrome 96; Opera drops the per-profile level entirely. Probe both.
        let chromium = [
            (CookieBrowser(name: "chrome", display: "Chrome"), "Google/Chrome/Default"),
            (CookieBrowser(name: "edge", display: "Edge"), "Microsoft Edge/Default"),
            (CookieBrowser(name: "brave", display: "Brave"), "BraveSoftware/Brave-Browser/Default"),
            (CookieBrowser(name: "vivaldi", display: "Vivaldi"), "Vivaldi/Default"),
            (CookieBrowser(name: "chromium", display: "Chromium"), "Chromium/Default"),
            (CookieBrowser(name: "opera", display: "Opera"), "com.operasoftware.Opera"),
        ]
        var jars: [(browser: CookieBrowser, path: URL)] = chromium.flatMap { browser, profile in
            let dir = support.appendingPathComponent(profile)
            return [dir.appendingPathComponent("Cookies"),
                    dir.appendingPathComponent("Network/Cookies")].map { (browser, $0) }
        }

        // Firefox hides its jar behind a generated profile directory name.
        let firefoxProfiles = support.appendingPathComponent("Firefox/Profiles")
        let profiles = (try? FileManager.default.contentsOfDirectory(
            at: firefoxProfiles, includingPropertiesForKeys: nil)) ?? []
        jars += profiles.map {
            (CookieBrowser(name: "firefox", display: "Firefox"),
             $0.appendingPathComponent("cookies.sqlite"))
        }

        // Keep each browser once, dated by its freshest jar that holds a session.
        var newest: [CookieBrowser: Date] = [:]
        for (browser, path) in jars {
            guard FileManager.default.isReadableFile(atPath: path.path),
                  let modified = try? FileManager.default.attributesOfItem(
                    atPath: path.path)[.modificationDate] as? Date,
                  modified > (newest[browser] ?? .distantPast),
                  hasYouTubeSession(jar: path)
            else { continue }
            newest[browser] = modified
        }
        var ranked = newest.sorted { $0.value > $1.value }.map(\.key)

        // Safari keeps its cookies in a binary format we can't inspect, so it can't
        // be ranked or vetted — it goes last, as an untested fallback. In practice
        // it drops out anyway: the jar sits behind Full Disk Access, and
        // `isReadableFile` reports that faithfully.
        let safariJar = library.appendingPathComponent(
            "Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies")
        if FileManager.default.isReadableFile(atPath: safariJar.path) {
            ranked.append(CookieBrowser(name: "safari", display: "Safari"))
        }
        return ranked
    }

    /// Cookie names YouTube sets only for a signed-in session — the thing that
    /// actually gets a download past the bot wall. A jar full of anonymous cookies
    /// (`VISITOR_INFO1_LIVE` and friends) is no better than sending none.
    private nonisolated static let sessionCookieNames =
        ["SID", "__Secure-1PSID", "__Secure-3PSID", "SAPISID", "LOGIN_INFO"]

    /// True when `jar` holds a signed-in YouTube session.
    ///
    /// Only cookie *values* are encrypted — names and hosts sit in plain columns,
    /// so this answers the question without touching the Keychain, which is the
    /// whole point: the check must stay cheaper than the prompt it prevents.
    nonisolated static func hasYouTubeSession(jar: URL) -> Bool {
        // The browser holds the jar locked, with its most recent writes still in a
        // -wal sidecar, so probe a private copy of both rather than the live files.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonar-cookies-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let copy = scratch.appendingPathComponent(jar.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: jar, to: copy)
        } catch {
            return false
        }
        for sidecar in ["-wal", "-shm"] {
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: jar.path + sidecar),
                                              to: URL(fileURLWithPath: copy.path + sidecar))
        }

        var database: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return false
        }
        defer { sqlite3_close(database) }

        // Chromium and Firefox disagree on both table and column names; whichever
        // statement prepares is the schema we're looking at.
        let names = sessionCookieNames.map { "'\($0)'" }.joined(separator: ",")
        let queries = [
            "SELECT 1 FROM cookies WHERE host_key LIKE '%youtube.com' AND name IN (\(names)) LIMIT 1",
            "SELECT 1 FROM moz_cookies WHERE host LIKE '%youtube.com' AND name IN (\(names)) LIMIT 1",
        ]
        for query in queries {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { continue }
            if sqlite3_step(statement) == SQLITE_ROW { return true }
        }
        return false
    }

    /// True when yt-dlp's output says the video needs a signed-in session — the
    /// bot check, an age gate, or its blanket "pass cookies" advice.
    nonisolated static func needsSignIn(_ output: String) -> Bool {
        let text = normalize(output)
        return ["not a bot", "confirm your age", "sign in to", "--cookies"]
            .contains { text.contains($0) }
    }

    // MARK: Helpers

    /// Lowercase, with typographic apostrophes folded to ASCII — yt-dlp writes
    /// "you're" with U+2019, which no plain `'` in a needle would ever match.
    private nonisolated static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{02BC}", with: "'")
    }

    /// Pull the last "NN.N%" progress figure out of a chunk of yt-dlp output.
    nonisolated static func parsePercent(_ text: String) -> Double? {
        var found: Double?
        var scanner = Substring(text)
        while let range = scanner.range(of: #"[0-9]{1,3}(\.[0-9]+)?%"#, options: .regularExpression) {
            let token = scanner[range].dropLast() // drop '%'
            if let value = Double(token) { found = value }
            scanner = scanner[range.upperBound...]
        }
        return found
    }

    /// Map yt-dlp's raw output to a specific, user-facing failure message.
    /// Falls back to the trimmed last non-empty line, or a generic message,
    /// when nothing recognizable is found. Never returns blank.
    nonisolated static func errorMessage(for output: String) -> String {
        let lower = normalize(output)
        let signatures: [(needle: String, message: String)] = [
            // Cookie failures come first: when the jar couldn't be opened, that's
            // the actionable cause, and YouTube's sign-in complaint is downstream.
            ("find-generic-password failed", "Couldn't unlock browser cookies — allow Keychain access and retry"),
            ("cannot decrypt", "Couldn't unlock browser cookies — allow Keychain access and retry"),
            ("could not find cookies", "Couldn't read browser cookies — sign in to YouTube in your browser"),
            ("private video", "This video is private"),
            ("video unavailable", "Video unavailable — it may have been removed"),
            ("has been removed", "Video unavailable — it may have been removed"),
            ("account associated with this video has been terminated", "Video unavailable — the uploader's account was terminated"),
            ("not available in your country", "This video is region-locked and unavailable in your country"),
            ("blocked it in your country", "This video is region-locked and unavailable in your country"),
            ("sign in to confirm your age", "This video is age-restricted and requires sign-in"),
            ("age-restricted", "This video is age-restricted and requires sign-in"),
            ("not a bot", "YouTube blocked this download — sign in to YouTube in your browser, then retry"),
            ("too many requests", "YouTube is rate-limiting this network — wait a while and retry"),
            ("temporary failure in name resolution", "Network error — check your internet connection"),
            ("could not resolve host", "Network error — check your internet connection"),
            ("network is unreachable", "Network error — check your internet connection"),
            ("no space left on device", "Download failed — disk is full"),
        ]
        for (needle, message) in signatures where lower.contains(needle) {
            return message
        }
        let lastLine = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        if let lastLine, !lastLine.isEmpty {
            return lastLine
        }
        return "Download failed — check the URL or run: brew upgrade yt-dlp"
    }

    /// Only accept http/https — rejects empty schemes, `file:`, and anything
    /// else that could otherwise be mistaken for a yt-dlp flag (e.g. `-o...`).
    private func isValidURL(_ string: String) -> Bool {
        guard let scheme = URL(string: string)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}
