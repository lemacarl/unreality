import Foundation
import Testing
import UnrealityCore

@Suite("PrivacyFilter")
struct PrivacyFilterTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let filter = PrivacyFilter()

    private func sample(_ kind: ActivityEventKind = .app, app: String? = "com.example.editor",
                        title: String? = "notes.txt", url: String? = nil) -> ActivitySample {
        ActivitySample(kind: kind, appBundleID: app, windowTitle: title, url: url,
                       startedAt: start, endedAt: start + 10, source: "test", sessionID: 7)
    }

    private func web(_ url: String?, app: String = "com.apple.Safari") -> ActivitySample {
        sample(.web, app: app, title: "Page", url: url)
    }

    @Test("an allowed app passes through unchanged")
    func keepsAllowedApp() throws {
        let event = try #require(filter.filter(sample()))
        #expect(event.kind == .app)
        #expect(event.appBundleID == "com.example.editor")
        #expect(event.windowTitle == "notes.txt")
        #expect(event.url == nil)
        #expect(event.startedAt == start)
        #expect(event.endedAt == start + 10)
        #expect(event.source == "test")
        #expect(event.sessionID == 7)
    }

    @Test("excluded apps are dropped", arguments: ["com.1password.1password", "COM.APPLE.MOBILESMS"])
    func dropsExcludedApp(_ bundleID: String) {
        #expect(filter.evaluate(sample(app: bundleID)) == .drop(.excludedApp))
        #expect(filter.evaluate(web("https://example.com/", app: bundleID)) == .drop(.excludedApp))
    }

    @Test("excluded sites are dropped, including subdomains", arguments: [
        "https://www.paypal.com/myaccount", "https://my.1password.com/", "http://WEB.WHATSAPP.COM/#chat",
        "https://user:pw@secure.chase.com/login?x=1"
    ])
    func dropsExcludedSite(_ url: String) {
        #expect(filter.evaluate(web(url)) == .drop(.excludedSite))
    }

    @Test("user entries extend the defaults")
    func userBlocklist() {
        let user = Blocklist(bundleIDPatterns: ["com.example.editor"], domains: ["intranet.example"])
        let custom = PrivacyFilter(blocklist: .defaults.union(user))
        #expect(custom.filter(sample()) == nil)
        #expect(custom.evaluate(web("https://wiki.intranet.example/page")) == .drop(.excludedSite))
        #expect(custom.evaluate(sample(app: "com.bitwarden.desktop")) == .drop(.excludedApp))
    }

    @Test("URLs keep scheme, host, port and path; query, fragment, credentials and ; parameters are dropped",
          arguments: [
            ("https://example.com/a/b?token=secret#frag", "https://example.com/a/b"),
            ("https://user:pass@Example.COM:8443/x?y", "https://example.com:8443/x"),
            ("https://example.com", "https://example.com/"),
            ("https://example.com/?q=1", "https://example.com/"),
            ("https://example.com/#only-fragment", "https://example.com/"),
            ("https://example.com/cart;jsessionid=abc123/items;v=2", "https://example.com/cart/items"),
            ("https://example.com/caf%C3%A9", "https://example.com/caf%C3%A9"),
            ("  https://example.com/trim  ", "https://example.com/trim")
          ])
    func redactsURL(_ raw: String, _ expected: String) throws {
        let event = try #require(filter.filter(web(raw)))
        #expect(event.url == expected)
    }

    @Test("hostOnly keeps no path")
    func hostOnly() throws {
        let event = try #require(PrivacyFilter(urlRedaction: .hostOnly).filter(web("https://example.com/a/b?c#d")))
        #expect(event.url == "https://example.com/")
    }

    @Test("non-web schemes keep only the scheme", arguments: [
        ("file:///Users/someone/Documents/plan.pdf", "file:"),
        ("about:blank", "about:"),
        ("data:text/html,<b>secret</b>", "data:"),
        ("chrome-extension://abcdefgh/popup.html?x", "chrome-extension:")
    ])
    func nonWebSchemes(_ raw: String, _ expected: String) throws {
        let event = try #require(filter.filter(web(raw)))
        #expect(event.url == expected)
    }

    @Test("a URL that cannot be checked drops the event (fails closed)", arguments: [
        "not a url", "", "https://", "https:///path", "//example.com/no-scheme", "example.com"
    ])
    func uncheckableURL(_ raw: String) {
        #expect(filter.evaluate(web(raw)) == .drop(.uncheckableURL))
        #expect(filter.evaluate(sample(url: raw)) == .drop(.uncheckableURL))
    }

    @Test("a web sample without a URL is dropped")
    func webWithoutURL() {
        #expect(filter.evaluate(web(nil)) == .drop(.uncheckableURL))
    }

    @Test("idle samples keep no app, title or URL, even from an excluded app")
    func idle() throws {
        let raw = sample(.idle, app: "com.1password.1password", title: "Vault", url: "https://x.example/?q")
        let event = try #require(filter.filter(raw))
        #expect(event.kind == .idle)
        #expect(event.appBundleID == nil)
        #expect(event.windowTitle == nil)
        #expect(event.url == nil)
    }

    @Test("a batch keeps order and drops excluded samples")
    func batch() {
        let samples = [sample(title: "one"), sample(app: "com.bitwarden.desktop"),
                       web("https://paypal.com/"), sample(title: "two")]
        #expect(filter.filter(samples).map(\.windowTitle) == ["one", "two"])
    }

    @Test("textual representations redact title and URL")
    func redactingDescriptions() throws {
        let secretTitle = "Diagnosis results - private"
        let secretURL = "https://example.com/very/private/path"
        let raw = web(secretURL)
        var withTitle = raw
        withTitle.windowTitle = secretTitle
        let event = try #require(filter.filter(withTitle))
        let stored = ActivityEvent(event, id: 1)

        for value in [withTitle as Any, event as Any, stored as Any] {
            var dumped = ""
            dump(value, to: &dumped)
            for text in [String(describing: value), String(reflecting: value), "\(value)", dumped] {
                #expect(!text.contains(secretTitle))
                #expect(!text.contains("private/path"))
                #expect(!text.contains("example.com"))
            }
        }
        #expect(String(describing: stored).contains("<redacted>"))
        #expect(String(describing: stored).contains("com.apple.Safari"))
    }
}
