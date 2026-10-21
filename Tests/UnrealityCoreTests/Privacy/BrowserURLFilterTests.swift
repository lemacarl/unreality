import Foundation
import Testing
import UnrealityCore

private let safari = FrontmostApp(bundleID: "com.apple.Safari", name: "Safari", processID: 501)
private let chrome = FrontmostApp(bundleID: "com.google.Chrome", name: "Chrome", processID: 502)
private let firefox = FrontmostApp(bundleID: "org.mozilla.firefox", name: "Firefox", processID: 503)
private let notes = FrontmostApp(bundleID: "com.example.notes", name: "Notes", processID: 504)

@Suite("Known browsers")
struct KnownBrowserTests {
    @Test("bundle IDs match case-insensitively, with the right scripting", arguments: [
        ("com.apple.Safari", KnownBrowser.Scripting.safari),
        ("COM.APPLE.SAFARI", .safari),
        ("com.apple.SafariTechnologyPreview", .safari),
        ("com.google.Chrome", .chromium),
        ("com.google.Chrome.canary", .chromium),
        ("company.thebrowser.Browser", .chromium),
        ("com.brave.Browser", .chromium),
        ("com.microsoft.edgemac", .chromium),
        ("org.chromium.Chromium", .chromium),
        ("org.mozilla.firefox", .unsupported),
        ("org.mozilla.firefoxdeveloperedition", .unsupported),
        ("com.google.Chrome.app.abcdefghijklmnop", .unsupported),
        ("com.apple.Safari.WebApp.1234-ABCD", .unsupported)
    ])
    func matches(_ bundleID: String, _ scripting: KnownBrowser.Scripting) {
        #expect(KnownBrowser.matching(bundleID: bundleID)?.scripting == scripting)
    }

    @Test("other apps are not browsers", arguments: [
        "com.example.notes", "com.apple.finder", "com.google.Chromeish", "com.apple.SafariX", ""
    ])
    func notBrowsers(_ bundleID: String) {
        #expect(KnownBrowser.matching(bundleID: bundleID) == nil)
        #expect(KnownBrowser.matching(bundleID: nil) == nil)
    }
}

@Suite("Privacy filter with browser URLs (#19)")
struct BrowserURLFilterTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let rules = PrivacyRules()

    private func sample(_ reading: BrowserURLReading?, app: FrontmostApp = safari,
                        title: String? = "Page title") -> ActivitySample {
        ActivitySample(timestamp: start, trigger: .appActivated, app: app, windowTitle: title, browserURL: reading)
    }

    @Test("filter(_:) drops samples on excluded sites", arguments: [
        "https://www.paypal.com/myaccount?x=1", "https://secure.chase.com/", "https://mail.google.com/mail/u/0/#inbox",
        "blob:https://web.whatsapp.com/1234", "https://ch%61se.com/"
    ])
    func dropsExcludedSite(_ url: String) {
        #expect(rules.filter(sample(.url(url))) == nil)
        #expect(rules.evaluate(sample(.url(url)), until: start + 5, source: "test") == .drop(.excludedSite))
    }

    @Test("filter(_:) redacts the URL and keeps the title on allowed sites")
    func redactsInFilter() throws {
        let filtered = try #require(rules.filter(sample(.url("https://user:pw@docs.example.com/a;s=1/b?token=x#f"))))
        #expect(filtered.url == "https://docs.example.com/a/b")
        #expect(filtered.windowTitle == "Page title")
        let event = try #require(rules.event(from: filtered, until: start + 5, source: "test"))
        #expect(event.kind == .web)
        #expect(event.url == "https://docs.example.com/a/b")
    }

    @Test("filtering again changes nothing, and events from filtered samples match events from raw ones",
          arguments: [
            "https://docs.example.com/a/b?q=1", "https://[2001:DB8::1]:8080/p?q", "https://BÜCHER.de/x",
            "about:blank", "data:text/html,hi", "chrome://settings/appearance", "ftp://example.com/x",
            "blob:https://example.com/2f1c?x", "view-source:https://example.com/a?b", "filesystem:https://example.com/t/f"
          ])
    func idempotent(_ url: String) throws {
        for mode in [URLRedaction.keepPath, .hostOnly] {
            let rules = PrivacyRules(urlRedaction: mode)
            let raw = sample(.url(url))
            let once = try #require(rules.filter(raw), "\(url)")
            #expect(rules.filter(once) == once, "\(url)")
            #expect(rules.event(from: once, until: start + 1, source: "t") ==
                rules.event(from: raw, until: start + 1, source: "t"), "\(url)")
        }
    }

    @Test("a known browser without a readable URL loses its title, whatever the reason",
          arguments: BrowserURLUnavailability.allCases)
    func unreadableDropsTitle(_ reason: BrowserURLUnavailability) throws {
        let filtered = try #require(rules.filter(sample(.unreadable(reason))))
        #expect(filtered.windowTitle == nil)
        #expect(filtered.url == nil)
        let event = try #require(rules.event(from: sample(.unreadable(reason)), until: start + 1, source: "t"))
        #expect(event.kind == .app)
        #expect(event.windowTitle == nil)
        #expect(event.appBundleID == "com.apple.Safari")
    }

    @Test("a known browser with no reading at all (no provider, Firefox) loses its title")
    func noReadingDropsTitle() throws {
        for app in [safari, chrome, firefox] {
            let filtered = try #require(rules.filter(sample(nil, app: app)))
            #expect(filtered.windowTitle == nil)
            #expect(rules.event(from: sample(nil, app: app), until: start + 1, source: "t")?.windowTitle == nil)
        }
    }

    @Test("nil means only 'not a web sample': other apps keep their titles as app events")
    func nonBrowserKeepsTitle() throws {
        let filtered = try #require(rules.filter(sample(nil, app: notes)))
        #expect(filtered.windowTitle == "Page title")
        let event = try #require(rules.event(from: filtered, until: start + 1, source: "t"))
        #expect(event.kind == .app)
        #expect(event.url == nil)
    }

    @Test("about: and data: pop-ups keep the event but drop the title", arguments: [
        "about:blank", "ABOUT:blank", "about:srcdoc", "data:text/html,<b>Statement</b>", "view-source:about:blank"
    ])
    func hostlessDropsTitle(_ url: String) throws {
        let filtered = try #require(rules.filter(sample(.url(url))))
        #expect(filtered.windowTitle == nil)
        let event = try #require(rules.event(from: sample(.url(url)), until: start + 1, source: "t"))
        #expect(event.kind == .web)
        #expect(event.windowTitle == nil)
    }

    @Test("browser-internal password, payment and wallet pages are dropped", arguments: [
        "chrome://password-manager/passwords", "CHROME://Password-Manager/", "edge://wallet/passwords",
        "brave://wallet/crypto", "chrome://settings/passwords", "chrome://settings/payments",
        "chrome://settings/addresses", "chrome://settings/autofill", "edge://settings/profiles/passwords",
        "brave://settings/passkeys", "arc://password-manager", "about:logins", "view-source:chrome://password-manager"
    ])
    func internalPasswordPages(_ url: String) {
        #expect(rules.filter(sample(.url(url), app: chrome)) == nil)
        #expect(rules.evaluate(sample(.url(url), app: chrome), until: start + 1, source: "t") == .drop(.excludedBrowserPage))
    }

    @Test("a backslash before the query fails closed (browser and Foundation disagree on the host)", arguments: [
        "https://chase.com\\@evil.com/", "https://evil.com\\@chase.com/", "https://example.com\\path",
        "blob:https://chase.com\\@evil.com/1"
    ])
    func backslashParserDifferential(_ url: String) {
        #expect(rules.evaluate(sample(.url(url)), until: start + 1, source: "t") == .drop(.uncheckableURL))
        #expect(rules.filter(sample(.url(url))) == nil)
    }

    @Test("a backslash in the query or fragment is harmless (both are dropped)")
    func backslashInQuery() throws {
        #expect(try #require(rules.filter(sample(.url("https://example.com/s?q=a\\b#c\\d")))).url
            == "https://example.com/s")
    }

    @Test("evaluate's url argument overrides the sample's reading")
    func urlArgumentOverrides() {
        let decision = rules.evaluate(sample(.unreadable(.failed)), until: start + 1,
                                      url: "https://www.paypal.com/", source: "t")
        #expect(decision == .drop(.excludedSite))
    }

    @Test("an app without a bundle ID never carries a URL or title")
    func noBundleID() throws {
        let app = FrontmostApp(bundleID: nil, name: nil, processID: 9)
        let filtered = try #require(rules.filter(sample(.url("https://example.com/"), app: app)))
        #expect(filtered.browserURL == nil)
        #expect(filtered.windowTitle == nil)
    }

    @Test("textual representations redact the URL")
    func redactedDescriptions() {
        let secret = "https://docs.example.com/private/plan?token=abc"
        let reading = BrowserURLReading.url(secret)
        for value in [sample(.url(secret)) as Any, reading as Any] {
            var dumped = ""
            dump(value, to: &dumped)
            for text in [String(describing: value), String(reflecting: value), "\(value)", dumped] {
                #expect(!text.contains("example.com"))
                #expect(!text.contains("token"))
            }
        }
        #expect(String(describing: sample(.unreadable(.privateWindow))).contains("unreadable(privateWindow)"))
    }
}

@MainActor
@Suite("Browser URLs through the coordinator (#19)")
struct BrowserURLCoordinatorTests {
    @MainActor
    private struct Rig {
        let source: FakeActivitySource
        let provider: FakeBrowserURLProvider
        let trust: FakeAccessibilityTrust
        let captureState: CaptureStateStore
        let filter: PrivacyFilter
        let coordinator: ActivityCoordinator

        init(frontmost: FrontmostApp = notes, readings: [String: BrowserURLReading] = [:]) {
            provider = FakeBrowserURLProvider(readings: readings)
            source = FakeActivitySource(frontmost: frontmost, title: "first", urlProvider: provider)
            trust = FakeAccessibilityTrust(state: .trusted)
            captureState = CaptureStateStore()
            filter = PrivacyFilter()
            coordinator = ActivityCoordinator(source: source, captureState: captureState, trust: trust,
                                              filter: filter)
        }
    }

    @Test("only known browsers are asked, and URLs arrive redacted")
    func asksOnlyBrowsers() {
        let rig = Rig(readings: ["com.apple.Safari": .url("https://docs.example.com/p?token=1")])
        var delivered: [ActivitySample] = []
        rig.coordinator.start { delivered.append($0) }
        rig.source.activate(safari, title: "Docs")
        rig.source.activate(notes, title: "n")
        #expect(rig.provider.urlQueries == [safari])
        #expect(delivered.map(\.url) == [nil, "https://docs.example.com/p", nil])
        #expect(delivered.map(\.windowTitle) == ["first", "Docs", "n"])
    }

    @Test("excluded sites never leave the coordinator; switching tabs re-reads the URL")
    func excludedSite() {
        let rig = Rig(readings: ["com.google.Chrome": .url("https://docs.example.com/")])
        var delivered: [ActivitySample] = []
        rig.coordinator.start { delivered.append($0) }
        rig.source.activate(chrome, title: "Docs")
        rig.provider.readings["com.google.Chrome"] = .url("https://secure.chase.com/accounts?id=1")
        rig.source.setTitle("Chase - Accounts")
        rig.provider.readings["com.google.Chrome"] = .url("https://docs.example.com/2")
        rig.source.setTitle("Docs 2")
        #expect(delivered.map(\.windowTitle) == ["first", "Docs", "Docs 2"])
        #expect(!delivered.contains { ($0.url ?? "").contains("chase") })
        #expect(rig.provider.urlQueries.count == 3)
    }

    @Test("excluded apps, untrusted Accessibility and pause never ask for a URL")
    func neverAsksWhenTitlesAreRefused() {
        let rig = Rig()
        rig.filter.rules.blocklist = .defaults.union(Blocklist(bundleIDPatterns: ["com.apple.Safari"]))
        var delivered: [ActivitySample] = []
        rig.coordinator.start { delivered.append($0) }
        rig.source.activate(safari, title: "Bank")
        #expect(rig.provider.urlQueries.isEmpty)

        rig.trust.state = .notTrusted
        rig.source.activate(chrome, title: "Bank")
        #expect(rig.provider.urlQueries.isEmpty)
        #expect(delivered.last?.app == chrome)
        #expect(delivered.last?.windowTitle == nil)
        #expect(delivered.last?.browserURL == nil)

        rig.trust.state = .trusted
        rig.captureState.pause()
        rig.source.activate(chrome, title: "Bank")
        #expect(rig.provider.urlQueries.isEmpty)
    }

    @Test("an unreadable URL (permission denied, private window) gives an app-only sample")
    func unreadable() {
        let rig = Rig(readings: [
            "com.apple.Safari": .unreadable(.automationDenied), "com.google.Chrome": .unreadable(.privateWindow)
        ])
        var delivered: [ActivitySample] = []
        rig.coordinator.start { delivered.append($0) }
        rig.source.activate(safari, title: "Secret")
        rig.source.activate(chrome, title: "Incognito page")
        #expect(delivered.map(\.windowTitle) == ["first", nil, nil])
        #expect(delivered.map(\.browserURL) == [nil, .unreadable(.automationDenied), .unreadable(.privateWindow)])
    }

    @Test("nothing from excluded sites reaches the database; stored URLs are redacted")
    func endToEndStorage() throws {
        let sentinel = "unreality-excluded-\(UUID().uuidString)"
        let rig = Rig(readings: ["com.apple.Safari": .url("https://docs.example.com/a?session=\(sentinel)")])
        let repository = try DatabaseManager.inMemory().activityRepository()
        var pending: ActivitySample?
        var failure: (any Error)?
        rig.coordinator.start { sample in
            if let previous = pending, let event = rig.filter.event(from: previous, until: sample.timestamp,
                                                                     source: "test") {
                do { try repository.insert(event) } catch { failure = error }
            }
            pending = sample
        }
        rig.source.activate(safari, title: "allowed-docs")
        for url in ["https://www.paypal.com/?\(sentinel)", "chrome-extension://abc/vault.html", "about:logins",
                    "https://chase.com\\@evil.com/\(sentinel)"] {
            rig.provider.readings["com.apple.Safari"] = .url(url)
            rig.source.setTitle("\(sentinel) title")
        }
        rig.provider.readings["com.apple.Safari"] = .url("about:blank")
        rig.source.setTitle("\(sentinel) popup")
        rig.provider.readings["com.apple.Safari"] = .unreadable(.privateWindow)
        rig.source.setTitle("\(sentinel) private")
        rig.source.activate(notes, title: "end")
        rig.coordinator.stop()
        #expect(failure == nil)

        let stored = try repository.events(overlapping: DateInterval(start: .distantPast, end: .distantFuture))
        #expect(stored.map(\.windowTitle) == ["first", "allowed-docs", nil, nil])
        #expect(stored.map(\.url) == [nil, "https://docs.example.com/a", "about:", nil])
        #expect(stored.map(\.kind) == [.app, .web, .web, .app])
        for event in stored {
            #expect(!(event.windowTitle ?? "").contains(sentinel))
            #expect(!(event.url ?? "").contains(sentinel))
        }
    }
}

@MainActor
@Suite("FakeBrowserURLProvider")
struct FakeBrowserURLProviderTests {
    @Test("reading never changes permission; only an explicit request does")
    func permissionRequest() async {
        let provider = FakeBrowserURLProvider(permissions: ["com.apple.Safari": .notDetermined], userAnswer: .denied)
        #expect(provider.activeTabURL(of: safari) == .unreadable(.failed))
        #expect(provider.automationPermission(for: safari) == .notDetermined)
        #expect(provider.permissionRequests.isEmpty)
        #expect(await provider.requestAutomationPermission(for: safari) == .denied)
        #expect(provider.automationPermission(for: safari) == .denied)
        #expect(await provider.requestAutomationPermission(for: notes) == .notApplicable)
        #expect(provider.permissionRequests == [safari, notes])
    }
}
