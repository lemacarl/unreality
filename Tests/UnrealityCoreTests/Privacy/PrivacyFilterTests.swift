import Foundation
import Testing
import UnrealityCore

@Suite("PrivacyRules")
struct PrivacyRulesTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let rules = PrivacyRules()

    private func app(_ bundleID: String?) -> FrontmostApp {
        FrontmostApp(bundleID: bundleID, name: "Some App", processID: 4242)
    }

    private func sample(_ bundleID: String? = "com.example.editor", title: String? = "notes.txt",
                        trigger: ActivitySample.Trigger = .appActivated) -> ActivitySample {
        ActivitySample(timestamp: start, trigger: trigger, app: app(bundleID), windowTitle: title)
    }

    private func web(_ url: String, app bundleID: String = "com.apple.Safari") -> PrivacyDecision {
        rules.evaluate(sample(bundleID, title: "Page"), until: start + 10, url: url, source: "test")
    }

    private func redacted(_ url: String, _ rules: PrivacyRules? = nil) throws -> String? {
        let event = try #require((rules ?? self.rules).event(
            from: sample("com.apple.Safari"), until: start + 10, url: url, source: "test"
        ))
        #expect(event.kind == .web)
        return event.url
    }

    @Test("an allowed app's sample passes unchanged and its titles may be read")
    func keepsAllowedApp() {
        let raw = sample()
        #expect(rules.filter(raw) == raw)
        #expect(rules.allowsWindowTitle(for: raw.app))
    }

    @Test("an app without a bundle ID is kept app-only: its title is neither allowed nor stored")
    func noBundleID() throws {
        #expect(!rules.allowsWindowTitle(for: app(nil)))
        let kept = try #require(rules.filter(sample(nil, title: "Secret window")))
        #expect(kept.windowTitle == nil)
        #expect(kept.app == app(nil))
        let event = try #require(rules.event(from: sample(nil, title: "Secret window"), until: start + 1,
                                             source: "test"))
        #expect(event.windowTitle == nil)
        #expect(event.appBundleID == nil)
    }

    @Test("excluded apps: titles may not be read and every sample is dropped, also app-only ones",
          arguments: ["com.1password.1password", "COM.APPLE.MOBILESMS", "com.agilebits.onepassword7"])
    func dropsExcludedApp(_ bundleID: String) {
        #expect(!rules.allowsWindowTitle(for: app(bundleID)))
        for trigger in ActivitySample.Trigger.allCases {
            #expect(rules.filter(sample(bundleID, title: nil, trigger: trigger)) == nil)
            #expect(rules.filter(sample(bundleID, title: "Vault", trigger: trigger)) == nil)
        }
        #expect(rules.evaluate(sample(bundleID), until: start + 1, source: "test") == .drop(.excludedApp))
        #expect(web("https://example.com/", app: bundleID) == .drop(.excludedApp))
    }

    @Test("an event keeps the sample's app, title and span and the given source and session; no process ID")
    func eventFields() throws {
        let event = try #require(rules.event(from: sample(), until: start + 10, source: "workspace", sessionID: 7))
        #expect(event.kind == .app)
        #expect(event.appBundleID == "com.example.editor")
        #expect(event.windowTitle == "notes.txt")
        #expect(event.url == nil)
        #expect(event.startedAt == start)
        #expect(event.endedAt == start + 10)
        #expect(event.source == "workspace")
        #expect(event.sessionID == 7)
        #expect(!String(describing: ActivityEvent(event, id: 1)).contains("4242"))
    }

    @Test("excluded sites are dropped, including subdomains", arguments: [
        "https://www.paypal.com/myaccount", "https://my.1password.com/", "http://WEB.WHATSAPP.COM/#chat",
        "https://user:pw@secure.chase.com/login?x=1"
    ])
    func dropsExcludedSite(_ url: String) {
        #expect(web(url) == .drop(.excludedSite))
    }

    @Test("user entries extend the defaults")
    func userBlocklist() {
        let user = Blocklist(bundleIDPatterns: ["com.example.editor"], domains: ["intranet.example"])
        let custom = PrivacyRules(blocklist: .defaults.union(user))
        #expect(custom.filter(sample()) == nil)
        #expect(custom.evaluate(sample("com.apple.Safari"), until: start, url: "https://wiki.intranet.example/p",
                                source: "test") == .drop(.excludedSite))
        #expect(custom.filter(sample("com.bitwarden.desktop")) == nil)
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
        #expect(try redacted(raw) == expected)
    }

    @Test("hostOnly keeps no path")
    func hostOnly() throws {
        #expect(try redacted("https://example.com/a/b?c#d", PrivacyRules(urlRedaction: .hostOnly))
            == "https://example.com/")
    }

    @Test("allowed non-web URLs keep only the scheme", arguments: [
        ("about:blank", "about:"),
        ("ABOUT:newtab", "about:"),
        ("data:text/html,<b>secret</b>", "data:"),
        ("chrome://settings/passwords", "chrome:"),
        ("ftp://example.com/x?y", "ftp:")
    ])
    func nonWebSchemes(_ raw: String, _ expected: String) throws {
        #expect(try redacted(raw) == expected)
    }

    @Test("other schemes with a host are checked against the blocklist", arguments: [
        "ftp://files.paypal.com/statement.pdf", "wss://web.whatsapp.com/ws", "chrome://chase.com/"
    ])
    func nonWebSchemesWithExcludedHost(_ raw: String) {
        #expect(web(raw) == .drop(.excludedSite))
    }

    @Test("a URL that cannot be checked drops the event (fails closed)", arguments: [
        "not a url", "", "https://", "https:///path", "//example.com/no-scheme", "example.com",
        "https:chase.com", "file:///Users/someone/Documents/plan.pdf", "javascript:alert(1)",
        "mailto:someone@example.com", "blob:", "blob:not a url", "view-source:", "blob:file:///x",
        "blob:view-source:blob:https://example.com/1"
    ])
    func uncheckableURL(_ raw: String) {
        #expect(web(raw) == .drop(.uncheckableURL))
    }

    @Test("wrapped URLs are checked by their inner URL", arguments: [
        "blob:https://secure.chase.com/2f1c-uuid", "BLOB:https://www.chase.com/x",
        "view-source:https://www.chase.com/login", "blob:https://web.whatsapp.com/1234-uuid",
        "filesystem:https://my.1password.com/temporary/export.csv", "view-source:blob:https://paypal.com/1"
    ])
    func wrappedExcludedSite(_ raw: String) {
        #expect(web(raw) == .drop(.excludedSite))
    }

    @Test("allowed wrapped URLs keep the wrapper and the redacted inner URL", arguments: [
        ("blob:https://example.com/2f1c-uuid?x=1", "blob:https://example.com/"),
        ("view-source:https://example.com/a/b?token=1#f", "view-source:https://example.com/a/b"),
        ("filesystem:https://example.com/temporary/file.txt", "filesystem:https://example.com/")
    ])
    func wrappedAllowed(_ raw: String, _ expected: String) throws {
        #expect(try redacted(raw) == expected)
    }

    @Test("browser-extension pages are dropped", arguments: [
        "chrome-extension://aeblfdkhhhdcdjpifhhbdiojplfjncoa/home.html#/vault",
        "safari-web-extension://4A1B2C3D-0000-0000-0000-000000000000/popup.html",
        "safari-extension://com.example.ext/page.html", "moz-extension://abc/index.html",
        "blob:chrome-extension://abc/1"
    ])
    func extensionPages(_ raw: String) {
        #expect(web(raw) == .drop(.excludedExtensionPage))
    }

    @Test("internationalised and IPv6 hosts are stored in canonical form", arguments: [
        ("https://BÜCHER.de/x", "https://xn--bcher-kva.de/x"),
        ("https://xn--bcher-kva.de/x", "https://xn--bcher-kva.de/x"),
        ("https://[2001:DB8::1]:8080/p?q", "https://[2001:db8::1]:8080/p")
    ])
    func canonicalHosts(_ raw: String, _ expected: String) throws {
        #expect(try redacted(raw) == expected)
    }

    @Test("IDN blocklist entries match in either form")
    func idnEntries() {
        for entry in ["bücher.de", "xn--bcher-kva.de", "BÜCHER.DE"] {
            let custom = PrivacyRules(blocklist: Blocklist(domains: [entry]))
            for url in ["https://bücher.de/", "https://xn--bcher-kva.de/", "https://shop.BÜCHER.de/"] {
                #expect(custom.evaluate(sample("com.apple.Safari"), until: start, url: url, source: "test")
                    == .drop(.excludedSite), "\(entry) vs \(url)")
            }
        }
    }

    @Test("idle events keep no app, title or URL")
    func idle() {
        let event = rules.idleEvent(from: start, until: start + 60, source: "idle", sessionID: 3)
        #expect(event.kind == .idle)
        #expect(event.appBundleID == nil)
        #expect(event.windowTitle == nil)
        #expect(event.url == nil)
        #expect(event.startedAt == start)
        #expect(event.endedAt == start + 60)
        #expect(event.sessionID == 3)
    }

    @Test("textual representations redact title and URL")
    func redactingDescriptions() throws {
        let secretTitle = "Diagnosis results - private"
        let raw = sample("com.apple.Safari", title: secretTitle)
        let event = try #require(rules.event(from: raw, until: start + 1,
                                             url: "https://example.com/very/private/path", source: "test"))
        let stored = ActivityEvent(event, id: 1)

        for value in [raw as Any, event as Any, stored as Any] {
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

@Suite("PrivacyFilter (ActivitySampleFilter)")
@MainActor
struct PrivacyFilterTests {
    private let excluded = FrontmostApp(bundleID: "com.bitwarden.desktop", name: "Bitwarden", processID: 99)
    private let allowed = FrontmostApp(bundleID: "com.example.editor", name: "Editor", processID: 98)

    @Test("delegates to its rules, which can be replaced at runtime")
    func delegates() {
        let filter = PrivacyFilter()
        let sample = ActivitySample(timestamp: .now, trigger: .snapshot, app: allowed, windowTitle: "t")
        #expect(filter.allowsWindowTitle(for: allowed))
        #expect(!filter.allowsWindowTitle(for: excluded))
        #expect(filter.filter(sample) == sample)

        filter.rules.blocklist = .defaults.union(Blocklist(bundleIDPatterns: ["com.example.*"]))
        #expect(!filter.allowsWindowTitle(for: allowed))
        #expect(filter.filter(sample) == nil)
    }

    @Test("events built through the filter use its current rules, not a stale copy")
    func eventsUseCurrentRules() throws {
        let filter = PrivacyFilter()
        let sample = ActivitySample(timestamp: .now, trigger: .snapshot, app: allowed, windowTitle: "t")
        let url = "https://intranet.example/page"
        #expect(filter.event(from: sample, until: .now, url: url, source: "test") != nil)
        filter.rules.blocklist = .defaults.union(Blocklist(domains: ["intranet.example"]))
        #expect(filter.evaluate(sample, until: .now, url: url, source: "test") == .drop(.excludedSite))
        #expect(filter.event(from: sample, until: .now, url: url, source: "test") == nil)
        #expect(filter.idleEvent(from: .now, until: .now, source: "test").kind == .idle)
    }

    @Test("with the coordinator, excluded apps' titles are never read and their samples never delivered")
    func withCoordinator() {
        let source = FakeActivitySource(frontmost: allowed, title: "allowed title")
        let coordinator = ActivityCoordinator(
            source: source, captureState: CaptureStateStore(),
            trust: FakeAccessibilityTrust(state: .trusted), filter: PrivacyFilter()
        )
        var delivered: [ActivitySample] = []
        coordinator.start { delivered.append($0) }
        source.activate(excluded, title: "Vault: bank login")
        source.setTitle("Vault: other item")
        source.activate(allowed, title: "second")

        #expect(delivered.map(\.app.bundleID) == ["com.example.editor", "com.example.editor"])
        #expect(delivered.map(\.windowTitle) == ["allowed title", "second"])
        #expect(!source.titlePolicyQueries.isEmpty)
        coordinator.stop()
    }
}
