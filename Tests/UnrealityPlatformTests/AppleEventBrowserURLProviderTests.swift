import AppKit
import ApplicationServices
import Foundation
import Testing
import UnrealityCore
@testable import UnrealityPlatform

/// Scripted Apple Event Manager: answers per path, records what was sent.
@MainActor
private final class FakeAppleEventClient: AppleEventClient {
    var status: OSStatus = noErr
    var requestAnswer: OSStatus = noErr
    var answers: [AppleEventPath: Result<AppleEventValue?, AppleEventError>] = [:]
    private(set) var sent: [AppleEventPath] = []
    private(set) var permissionChecks = 0
    private(set) var permissionRequests = 0

    func permissionStatus(processID: Int32) -> OSStatus {
        permissionChecks += 1
        return status
    }

    func requestPermission(processID: Int32) async -> OSStatus {
        permissionRequests += 1
        return requestAnswer
    }

    func value(at path: AppleEventPath, processID: Int32,
               timeout: TimeInterval) -> Result<AppleEventValue?, AppleEventError> {
        sent.append(path)
        return answers[path] ?? .failure(AppleEventError(status: AppleEventStatus.noSuchObject))
    }
}

private let safari = FrontmostApp(bundleID: "com.apple.Safari", name: "Safari", processID: 601)
private let chrome = FrontmostApp(bundleID: "com.google.Chrome", name: "Chrome", processID: 602)
private let firefox = FrontmostApp(bundleID: "org.mozilla.firefox", name: "Firefox", processID: 603)
private let notes = FrontmostApp(bundleID: "com.example.notes", name: "Notes", processID: 604)

private let title = "Example Domain"
private let frontID = AppleEventPath(.window(1), .property("ID  "))
private let safariWindow = AppleEventPath.Step.windowID(.integer(42))
private let chromeWindow = AppleEventPath.Step.windowID(.text("1234"))
private let safariName = AppleEventPath(safariWindow, .property("pnam"))
private let safariURL = AppleEventPath(safariWindow, .property("cTab"), .property("pURL"))
private let chromeMode = AppleEventPath(chromeWindow, .property("mode"))
private let chromeName = AppleEventPath(chromeWindow, .property("pnam"))
private let chromeURL = AppleEventPath(chromeWindow, .property("acTa"), .property("URL "))

@MainActor
@Suite("AppleEventBrowserURLProvider")
struct AppleEventBrowserURLProviderTests {
    private func provider(_ configure: (FakeAppleEventClient) -> Void = { _ in })
        -> (AppleEventBrowserURLProvider, FakeAppleEventClient) {
        let client = FakeAppleEventClient()
        configure(client)
        return (AppleEventBrowserURLProvider(client: client), client)
    }

    private func safariAnswers(_ client: FakeAppleEventClient, url: String = "https://example.com/a?b") {
        client.answers[frontID] = .success(.integer(42))
        client.answers[safariName] = .success(.text(title))
        client.answers[safariURL] = .success(.text(url))
    }

    private func chromeAnswers(_ client: FakeAppleEventClient, mode: String = "normal") {
        client.answers[frontID] = .success(.text("1234"))
        client.answers[chromeMode] = .success(.text(mode))
        client.answers[chromeName] = .success(.text(title))
        client.answers[chromeURL] = .success(.text("https://example.com/"))
    }

    @Test("Safari: the front window's ID, then its name and current tab's URL, all by that ID")
    func readsSafari() {
        let (provider, client) = provider { safariAnswers($0) }
        #expect(provider.activeTabURL(of: safari, focusedWindowTitle: title) == .url("https://example.com/a?b"))
        #expect(client.sent == [frontID, safariName, safariURL])
    }

    @Test("Chrome family: the mode of the same window (by ID) is checked before anything else")
    func chromeNormal() {
        let (provider, client) = provider { chromeAnswers($0) }
        #expect(provider.activeTabURL(of: chrome, focusedWindowTitle: title) == .url("https://example.com/"))
        #expect(client.sent == [frontID, chromeMode, chromeName, chromeURL])
    }

    @Test("an incognito window's name and URL are never read")
    func incognito() {
        let (provider, client) = provider { chromeAnswers($0, mode: "incognito") }
        #expect(provider.activeTabURL(of: chrome, focusedWindowTitle: title) == .unreadable(.privateWindow))
        #expect(client.sent == [frontID, chromeMode])
    }

    @Test("an unknown or unreadable mode fails closed without reading the URL",
          arguments: [Result<AppleEventValue?, AppleEventError>.success(nil), .success(.text("guest")),
                      .success(.integer(1)), .failure(AppleEventError(status: -609))])
    func unknownMode(_ answer: Result<AppleEventValue?, AppleEventError>) {
        let (provider, client) = provider {
            chromeAnswers($0)
            $0.answers[chromeMode] = answer
        }
        #expect(provider.activeTabURL(of: chrome, focusedWindowTitle: title) == .unreadable(.failed))
        #expect(client.sent == [frontID, chromeMode])
    }

    @Test("a front window whose name is not the focused window's title is not read (title and URL dropped)",
          arguments: [Result<AppleEventValue?, AppleEventError>.success(.text("DevTools - example.com/")),
                      .success(nil), .success(.text(""))])
    func windowMismatch(_ name: Result<AppleEventValue?, AppleEventError>) {
        let (provider, client) = provider {
            safariAnswers($0)
            $0.answers[safariName] = name
        }
        #expect(provider.activeTabURL(of: safari, focusedWindowTitle: title) == .unreadable(.windowMismatch))
        #expect(client.sent == [frontID, safariName])
    }

    @Test("without a focused-window title nothing is sent")
    func noTitle() {
        let (provider, client) = provider { safariAnswers($0) }
        for missing in [nil, ""] as [String?] {
            #expect(provider.activeTabURL(of: safari, focusedWindowTitle: missing) == .unreadable(.windowMismatch))
        }
        #expect(client.sent.isEmpty)
        #expect(client.permissionChecks == 0)
    }

    @Test("without granted permission nothing is sent and nothing prompts", arguments: [
        (AppleEventStatus.wouldRequireConsent, BrowserURLUnavailability.automationNotDetermined),
        (AppleEventStatus.notPermitted, .automationDenied),
        (AppleEventStatus.processNotFound, .failed),
        (OSStatus(-50), .failed)
    ])
    func noPermission(_ status: OSStatus, _ expected: BrowserURLUnavailability) {
        let (provider, client) = provider { $0.status = status }
        #expect(provider.activeTabURL(of: safari, focusedWindowTitle: title) == .unreadable(expected))
        #expect(provider.activeTabURL(of: chrome, focusedWindowTitle: title) == .unreadable(expected))
        #expect(client.sent.isEmpty)
        #expect(client.permissionRequests == 0)
    }

    @Test("a granted permission is checked once per process until reset or a permission error")
    func permissionCache() {
        let (provider, client) = provider { safariAnswers($0) }
        for _ in 0..<3 { _ = provider.activeTabURL(of: safari, focusedWindowTitle: title) }
        #expect(client.permissionChecks == 1)
        provider.resetCachedState()
        _ = provider.activeTabURL(of: safari, focusedWindowTitle: title)
        #expect(client.permissionChecks == 2)
        // Revoked in System Settings: the event fails, and the next read checks again.
        client.answers[safariURL] = .failure(AppleEventError(status: AppleEventStatus.notPermitted))
        #expect(provider.activeTabURL(of: safari, focusedWindowTitle: title) == .unreadable(.automationDenied))
        client.status = AppleEventStatus.notPermitted
        let before = client.sent.count
        #expect(provider.activeTabURL(of: safari, focusedWindowTitle: title) == .unreadable(.automationDenied))
        #expect(client.permissionChecks == 3)
        #expect(client.sent.count == before)
    }

    @Test("after a timeout the process is sent nothing until the next reset")
    func unresponsive() {
        let (provider, client) = provider {
            safariAnswers($0)
            $0.answers[safariName] = .failure(AppleEventError(status: AppleEventStatus.timeout))
        }
        #expect(provider.activeTabURL(of: safari, focusedWindowTitle: title) == .unreadable(.failed))
        let sent = client.sent.count
        #expect(provider.activeTabURL(of: safari, focusedWindowTitle: title) == .unreadable(.failed))
        #expect(client.sent.count == sent)
        provider.resetCachedState()
        client.answers[safariName] = .success(.text(title))
        #expect(provider.activeTabURL(of: safari, focusedWindowTitle: title) == .url("https://example.com/a?b"))
    }

    @Test("Firefox and other apps are unsupported: nothing is sent")
    func unsupported() {
        let (provider, client) = provider()
        for app in [firefox, notes, FrontmostApp(bundleID: "com.google.Chrome.app.abc", name: nil, processID: 1),
                    FrontmostApp(bundleID: "org.torproject.torbrowser", name: nil, processID: 2)] {
            #expect(provider.activeTabURL(of: app, focusedWindowTitle: title) == .unreadable(.unsupportedBrowser))
            #expect(provider.automationPermission(for: app) == .notApplicable)
        }
        #expect(client.sent.isEmpty)
    }

    @Test("empty or missing URLs and missing windows read as no window; other errors as failed", arguments: [
        (Result<AppleEventValue?, AppleEventError>.success(.text("")), BrowserURLUnavailability.noWindow),
        (.success(nil), .noWindow),
        (.failure(AppleEventError(status: AppleEventStatus.noSuchObject)), .noWindow),
        (.failure(AppleEventError(status: AppleEventStatus.illegalIndex)), .noWindow),
        (.failure(AppleEventError(status: AppleEventStatus.notPermitted)), .automationDenied),
        (.failure(AppleEventError(status: AppleEventStatus.wouldRequireConsent)), .automationNotDetermined),
        (.failure(AppleEventError(status: AppleEventStatus.timeout)), .failed),
        (.failure(AppleEventError(status: AppleEventStatus.specifierUnavailable)), .failed),
        (.failure(AppleEventError(status: -609)), .failed)
    ])
    func replies(_ answer: Result<AppleEventValue?, AppleEventError>, _ expected: BrowserURLUnavailability) {
        let (provider, _) = provider {
            safariAnswers($0)
            $0.answers[safariURL] = answer
        }
        #expect(provider.activeTabURL(of: safari, focusedWindowTitle: title) == .unreadable(expected))
    }

    @Test("a front window without an ID (Settings, Downloads, no window) reads as no window, nothing else is sent")
    func noFrontWindow() {
        let (provider, client) = provider {
            safariAnswers($0)
            $0.answers[frontID] = .success(nil)
        }
        #expect(provider.activeTabURL(of: safari, focusedWindowTitle: title) == .unreadable(.noWindow))
        #expect(client.sent == [frontID])
    }

    @Test("permission states map from the Apple Event Manager's status")
    func permissionStates() async {
        let cases: [(OSStatus, BrowserAutomationPermission)] = [
            (noErr, .granted), (AppleEventStatus.notPermitted, .denied),
            (AppleEventStatus.wouldRequireConsent, .notDetermined), (AppleEventStatus.processNotFound, .notRunning),
            (-50, .unknown)
        ]
        for (status, expected) in cases {
            let (provider, client) = provider { $0.status = status }
            #expect(provider.automationPermission(for: safari) == expected)
            #expect(client.permissionRequests == 0)
        }
        let (provider, client) = provider {
            $0.status = AppleEventStatus.wouldRequireConsent
            $0.requestAnswer = AppleEventStatus.notPermitted
        }
        #expect(await provider.requestAutomationPermission(for: chrome) == .denied)
        #expect(await provider.requestAutomationPermission(for: firefox) == .notApplicable)
        #expect(client.permissionRequests == 1)
    }

    @Test("object specifiers nest innermost first: property of property of window id")
    func specifierNesting() throws {
        let spec = try #require(safariURL.specifier())
        let want = fourCharCode("want"), form = fourCharCode("form")
        let seld = fourCharCode("seld"), from = fourCharCode("from")
        #expect(spec.descriptorType == fourCharCode("obj "))
        #expect(spec.forKeyword(seld)?.typeCodeValue == fourCharCode("pURL"))
        let tab = try #require(spec.forKeyword(from))
        #expect(tab.forKeyword(seld)?.typeCodeValue == fourCharCode("cTab"))
        let window = try #require(tab.forKeyword(from))
        #expect(window.forKeyword(want)?.typeCodeValue == fourCharCode("cwin"))
        #expect(window.forKeyword(form)?.enumCodeValue == fourCharCode("ID  "))
        #expect(window.forKeyword(seld)?.int32Value == 42)
        #expect(window.forKeyword(from)?.descriptorType == fourCharCode("null"))

        let byIndex = try #require(frontID.specifier()?.forKeyword(from))
        #expect(byIndex.forKeyword(form)?.enumCodeValue == fourCharCode("indx"))
        #expect(byIndex.forKeyword(seld)?.int32Value == 1)
        let chromeSpec = try #require(chromeMode.specifier()?.forKeyword(from))
        #expect(chromeSpec.forKeyword(seld)?.stringValue == "1234")
    }

    @Test("the real permission check answers for a process that does not exist, without prompting")
    func realPermissionCheck() {
        let status = SystemAppleEventClient().permissionStatus(processID: Int32.max)
        #expect(status != noErr)
    }
}

@MainActor
@Suite("WorkspaceActivitySource browser URLs")
struct WorkspaceActivitySourceBrowserURLTests {
    @Test("with titles refused, the URL provider is never asked")
    func neverAskedWhenRefused() {
        let provider = FakeBrowserURLProvider(defaultReading: .url("https://example.com/"))
        let source = WorkspaceActivitySource(browserURLProvider: provider)
        var samples: [ActivitySample] = []
        source.start(windowTitlePolicy: { _ in false }, handler: { samples.append($0) })
        source.stop()
        #expect(provider.urlQueries.isEmpty)
        #expect(samples.allSatisfy { $0.browserURL == nil })
    }
}

/// Real browsers, run on demand only (CONTRIBUTING.md, "Manual checks").
/// Reads each running known browser's permission state without prompting
/// and, where granted, its front window's URL (matched to the focused
/// window's Accessibility title, so the test runner needs Accessibility
/// for a URL to be read). With
/// `UNREALITY_BROWSER_TESTS=prompt` it first asks for permission for each
/// undecided browser (system prompts, answered by a human). Prints states
/// and reading kinds only, never URLs.
@MainActor
@Suite(
    "AppleEventBrowserURLProvider integration",
    .enabled(if: ["1", "prompt"].contains(ProcessInfo.processInfo.environment["UNREALITY_BROWSER_TESTS"]))
)
struct BrowserURLProviderIntegrationTests {
    @Test("running browsers report a permission state and a matching reading", .timeLimit(.minutes(2)))
    func runningBrowsers() async {
        let provider = AppleEventBrowserURLProvider()
        let prompt = ProcessInfo.processInfo.environment["UNREALITY_BROWSER_TESTS"] == "prompt"
        let browsers = NSWorkspace.shared.runningApplications.compactMap { running -> FrontmostApp? in
            let app = FrontmostApp(bundleID: running.bundleIdentifier, name: nil,
                                   processID: running.processIdentifier)
            return KnownBrowser.isBrowser(app) ? app : nil
        }
        print("Known browsers running: \(browsers.count)")
        for app in browsers {
            let name = KnownBrowser.matching(bundleID: app.bundleID)?.name ?? "?"
            if prompt, provider.automationPermission(for: app) == .notDetermined {
                print("\(name): asked, answer \(await provider.requestAutomationPermission(for: app).rawValue)")
            }
            let permission = provider.automationPermission(for: app)
            // The source passes the focused window's Accessibility title;
            // here it is read the same way when the test runner is trusted.
            let axTitle = Self.focusedWindowTitle(of: app.processID)
            let reading = provider.activeTabURL(of: app, focusedWindowTitle: axTitle)
            let kind = reading.url == nil ? String(describing: reading) : "url (not shown)"
            print("\(name): permission \(permission.rawValue); AX title read: \(axTitle != nil); reading \(kind)")
            if permission != .granted { #expect(reading.url == nil) }
            if axTitle == nil { #expect(reading.url == nil) }
        }
    }

    /// The focused window's title via Accessibility (`nil` without trust).
    private static func focusedWindowTitle(of processID: Int32) -> String? {
        let app = AXUIElementCreateApplication(processID)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        var title: CFTypeRef?
        let element = unsafeDowncast(window, to: AXUIElement.self)
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title) == .success else {
            return nil
        }
        return title as? String
    }
}
