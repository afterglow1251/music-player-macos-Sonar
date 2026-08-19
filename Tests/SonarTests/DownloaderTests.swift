import Testing
import Foundation
import SQLite3
@testable import Sonar

/// Covers the two pieces of the downloader that decide what the user sees and
/// which browser we borrow cookies from when YouTube demands a signed-in session.
struct DownloaderTests {

    /// Verbatim yt-dlp output for the bot wall, typographic apostrophe and all —
    /// the exact bytes matter here, since matching them is what's under test.
    private let botWall = """
        WARNING: [youtube] dQw4w9WgXcQ: Unable to download webpage: HTTP Error 429: Too Many Requests
        ERROR: [youtube] dQw4w9WgXcQ: Sign in to confirm you\u{2019}re not a bot. \
        Use --cookies-from-browser or --cookies for the authentication.
        """

    // MARK: Error messages

    @Test func botWallGetsFriendlyMessage() {
        let message = Downloader.errorMessage(for: botWall)
        #expect(message == "YouTube blocked this download — sign in to YouTube in your browser, then retry")
    }

    /// The raw wall of text ends in a GitHub link; leaking it into the toast is
    /// the bug that a straight `'` needle caused.
    @Test func botWallMessageIsNotTheRawOutput() {
        #expect(!Downloader.errorMessage(for: botWall).contains("github.com"))
    }

    /// An unreadable cookie jar is the actionable cause, so it outranks YouTube's
    /// downstream complaint about not being signed in.
    @Test func keychainFailureOutranksSignInComplaint() {
        let output = """
            WARNING: find-generic-password failed
            WARNING: cannot decrypt v10 cookies: no key found
            \(botWall)
            """
        #expect(Downloader.errorMessage(for: output).contains("Keychain"))
    }

    @Test func unrecognizedFailureFallsBackToLastLine() {
        #expect(Downloader.errorMessage(for: "ERROR: something odd\n\n") == "ERROR: something odd")
    }

    @Test func emptyOutputStillProducesAMessage() {
        #expect(!Downloader.errorMessage(for: "").isEmpty)
    }

    // MARK: Cookie escalation

    @Test func signInWallTriggersCookies() {
        #expect(Downloader.needsSignIn(botWall))
    }

    @Test func ageGateTriggersCookies() {
        #expect(Downloader.needsSignIn("ERROR: Sign in to confirm your age"))
    }

    /// A dead network is nobody's cookie problem — escalating there would only
    /// put a pointless Keychain prompt in the user's way.
    @Test func networkFailureDoesNotTriggerCookies() {
        #expect(!Downloader.needsSignIn("ERROR: Could not resolve host: www.youtube.com"))
    }

    // MARK: Browser detection

    /// Which browser engine's cookie schema a fixture jar should imitate.
    private enum Engine {
        case chromium, firefox

        var table: String { self == .chromium ? "cookies" : "moz_cookies" }
        var hostColumn: String { self == .chromium ? "host_key" : "host" }
    }

    /// Write a cookie jar the probe will actually open: real SQLite, real schema,
    /// and either a signed-in session or the anonymous cookies YouTube hands out
    /// to a logged-out visitor.
    @discardableResult
    private func makeJar(_ home: URL, _ path: String, modified: Date,
                         engine: Engine = .chromium, signedIn: Bool = true) throws -> URL {
        let jar = home.appendingPathComponent("Library/Application Support").appendingPathComponent(path)
        try FileManager.default.createDirectory(at: jar.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        var database: OpaquePointer?
        #expect(sqlite3_open_v2(jar.path, &database,
                                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
        let name = signedIn ? "__Secure-3PSID" : "VISITOR_INFO1_LIVE"
        let statements = """
            CREATE TABLE \(engine.table) (\(engine.hostColumn) TEXT, name TEXT);
            INSERT INTO \(engine.table) VALUES ('.youtube.com', '\(name)');
            """
        #expect(sqlite3_exec(database, statements, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)

        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: jar.path)
        return jar
    }

    private func scratchHome() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    // MARK: Session probe

    @Test func signedInJarIsRecognized() throws {
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let jar = try makeJar(home, "Google/Chrome/Default/Cookies", modified: .now)
        #expect(Downloader.hasYouTubeSession(jar: jar))
    }

    /// Visiting YouTube while logged out still fills the jar — with cookies that
    /// get us nowhere past the bot wall.
    @Test func anonymousJarIsNotASession() throws {
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let jar = try makeJar(home, "Google/Chrome/Default/Cookies", modified: .now, signedIn: false)
        #expect(!Downloader.hasYouTubeSession(jar: jar))
    }

    @Test func firefoxSchemaIsUnderstood() throws {
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let jar = try makeJar(home, "Firefox/Profiles/abc.default/cookies.sqlite",
                              modified: .now, engine: .firefox)
        #expect(Downloader.hasYouTubeSession(jar: jar))
    }

    @Test func garbageJarIsRejectedRatherThanCrashing() throws {
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let jar = home.appendingPathComponent("junk")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("not a database".utf8).write(to: jar)
        #expect(!Downloader.hasYouTubeSession(jar: jar))
    }

    /// Among browsers that can actually help, the one whose jar was written most
    /// recently is the one the user lives in — so it's tried first.
    @Test func browsersAreRankedByJarFreshness() throws {
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try makeJar(home, "Google/Chrome/Default/Cookies", modified: Date(timeIntervalSince1970: 1_000))
        try makeJar(home, "Microsoft Edge/Default/Cookies", modified: Date(timeIntervalSince1970: 9_000))
        try makeJar(home, "BraveSoftware/Brave-Browser/Default/Network/Cookies",
                    modified: Date(timeIntervalSince1970: 5_000))

        let browsers = Downloader.availableCookieBrowsers(home: home)
        #expect(browsers.map(\.name) == ["edge", "brave", "chrome"])
    }

    /// The freshly-installed-Firefox trap: newest jar of the lot, but nobody has
    /// signed into YouTube in it yet. Ranking on mtime alone would put it first
    /// and burn the attempt.
    @Test func aFreshBrowserWithoutASessionLosesToAnOlderSignedInOne() throws {
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try makeJar(home, "Firefox/Profiles/abc.default/cookies.sqlite",
                    modified: Date(timeIntervalSince1970: 9_000), engine: .firefox, signedIn: false)
        try makeJar(home, "Microsoft Edge/Default/Cookies", modified: Date(timeIntervalSince1970: 1_000))

        #expect(Downloader.availableCookieBrowsers(home: home).map(\.name) == ["edge"])
    }

    /// An installed-but-unused browser leaves no jar behind, and offering it would
    /// spend a Keychain prompt on cookies that can't be there.
    @Test func browsersWithoutAJarAreSkipped() throws {
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try makeJar(home, "Vivaldi/Default/Cookies", modified: Date(timeIntervalSince1970: 1_000))
        #expect(Downloader.availableCookieBrowsers(home: home).map(\.name) == ["vivaldi"])
    }

    /// Chromium moved the jar under `Network/` in Chrome 96; both spellings are
    /// still in the wild, and a browser must be offered once, not twice.
    @Test func bothChromiumJarLocationsCollapseToOneBrowser() throws {
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try makeJar(home, "Google/Chrome/Default/Cookies", modified: Date(timeIntervalSince1970: 1_000))
        try makeJar(home, "Google/Chrome/Default/Network/Cookies", modified: Date(timeIntervalSince1970: 9_000))

        #expect(Downloader.availableCookieBrowsers(home: home).map(\.name) == ["chrome"])
    }

    @Test func noBrowsersMeansNoEscalation() {
        #expect(Downloader.availableCookieBrowsers(home: scratchHome()).isEmpty)
    }
}
