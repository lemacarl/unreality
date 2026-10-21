import AppKit
import Foundation
import Testing
import UnrealityCore
@testable import UnrealityPlatform

/// Scripted Apple Event Manager: answers per path, records what was sent.
@MainActor
private final class FakeAppleEventClient: AppleEventClient {
    var status: OSStatus = noErr
    var requestAnswer: OSStatus = noErr
    var answers: [AppleEventPath: Result<String?, AppleEventError>] = [:]
    private(set) var sent: [AppleEventPath] = []
    private(set) var permissionRequests = 0

    func permissionStatus(processID: Int32) -> OSStatus { status }

    func requestPermission(processID: Int32) async -> OSStatus {
        permissionRequests += 1
        return requestAnswer
    }

    func string(at path: AppleEventPath, processID: Int32, timeout: TimeInterval) -> Result<String?, AppleEventError> {
        sent.append(path)
        return answers[path] ?? .failure(AppleEventError(status: -1712))
    }
}

private let safari = FrontmostApp(bundleID: "com.apple.Safari", name: "Safari", processID: 601)
private let chrome = FrontmostApp(bundleID: "com.google.Chrome", name: "Chrome", processID: 602)
private let firefox = FrontmostApp(bundleID: "org.mozilla.firefox", name: "Firefox", processID: 603)
private let notes = FrontmostApp(bundleID: "com.example.notes", name: "Notes", processID: 604)

private let safariURL = AppleEventPath(.window(1), .property("cTab"), .property("pURL"))
private let chromeURL = AppleEventPath(.window(1), .property("acTa"), .property("URL "))
private let chromeMode = AppleEventPath(.window(1), .property("mode"))

@MainActor
@Suite("AppleEventBrowserURLProvider")
struct AppleEventBrowserURLProviderTests {
    private func provider(_ configure: (FakeAppleEventClient) -> Void = { _ in })
        -> (AppleEventBrowserURLProvider, FakeAppleEventClient) {
        let client = FakeAppleEventClient()
        configure(client)
        return (AppleEventBrowserURLProvider(client: client), client)
    }

    @Test("Safari: one event for the current tab's URL")
    func readsSafari() {
        let (provider, client) = provider { $0.answers[safariURL] = .success("https://example.com/a?b") }
        #expect(provider.activeTabURL(of: safari) == .url("https://example.com/a?b"))
        #expect(client.sent == [safariURL])
    }

    @Test("Chrome family: the mode is checked before the URL is read")
    func chromeNormal() {
        let (provider, client) = provider {
            $0.answers[chromeMode] = .success("normal")
            $0.answers[chromeURL] = .success("https://example.com/")
        }
        #expect(provider.activeTabURL(of: chrome) == .url("https://example.com/"))
        #expect(client.sent == [chromeMode, chromeURL])
    }

    @Test("an incognito window's URL is never read")
    func incognito() {
        let (provider, client) = provider {
            $0.answers[chromeMode] = .success("incognito")
            $0.answers[chromeURL] = .success("https://secret.example/")
        }
        #expect(provider.activeTabURL(of: chrome) == .unreadable(.privateWindow))
        #expect(client.sent == [chromeMode])
    }

    @Test("an unknown or unreadable mode fails closed without reading the URL",
          arguments: [Result<String?, AppleEventError>.success(nil), .success("guest"),
                      .failure(AppleEventError(status: -1712))])
    func unknownMode(_ answer: Result<String?, AppleEventError>) {
        let (provider, client) = provider {
            $0.answers[chromeMode] = answer
            $0.answers[chromeURL] = .success("https://example.com/")
        }
        #expect(provider.activeTabURL(of: chrome) == .unreadable(.failed))
        #expect(client.sent == [chromeMode])
    }

    @Test("without granted permission nothing is sent and nothing prompts", arguments: [
        (AppleEventStatus.wouldRequireConsent, BrowserURLUnavailability.automationNotDetermined),
        (AppleEventStatus.notPermitted, .automationDenied),
        (AppleEventStatus.processNotFound, .failed),
        (OSStatus(-50), .failed)
    ])
    func noPermission(_ status: OSStatus, _ expected: BrowserURLUnavailability) {
        let (provider, client) = provider { $0.status = status }
        #expect(provider.activeTabURL(of: safari) == .unreadable(expected))
        #expect(provider.activeTabURL(of: chrome) == .unreadable(expected))
        #expect(client.sent.isEmpty)
        #expect(client.permissionRequests == 0)
    }

    @Test("Firefox and other apps are unsupported: nothing is sent")
    func unsupported() {
        let (provider, client) = provider()
        for app in [firefox, notes, FrontmostApp(bundleID: "com.google.Chrome.app.abc", name: nil, processID: 1)] {
            #expect(provider.activeTabURL(of: app) == .unreadable(.unsupportedBrowser))
            #expect(provider.automationPermission(for: app) == .notApplicable)
        }
        #expect(client.sent.isEmpty)
    }

    @Test("empty or missing URLs and missing windows read as no window; other errors as failed", arguments: [
        (Result<String?, AppleEventError>.success(""), BrowserURLUnavailability.noWindow),
        (.success(nil), .noWindow),
        (.failure(AppleEventError(status: AppleEventStatus.noSuchObject)), .noWindow),
        (.failure(AppleEventError(status: AppleEventStatus.illegalIndex)), .noWindow),
        (.failure(AppleEventError(status: AppleEventStatus.notPermitted)), .automationDenied),
        (.failure(AppleEventError(status: AppleEventStatus.wouldRequireConsent)), .automationNotDetermined),
        (.failure(AppleEventError(status: -1712)), .failed),
        (.failure(AppleEventError(status: -609)), .failed)
    ])
    func replies(_ answer: Result<String?, AppleEventError>, _ expected: BrowserURLUnavailability) {
        let (provider, _) = provider { $0.answers[safariURL] = answer }
        #expect(provider.activeTabURL(of: safari) == .unreadable(expected))
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

    @Test("object specifiers nest innermost first: property of property of window 1")
    func specifierNesting() throws {
        let spec = try #require(safariURL.specifier())
        let want = fourCharCode("want"), seld = fourCharCode("seld"), from = fourCharCode("from")
        #expect(spec.descriptorType == fourCharCode("obj "))
        #expect(spec.forKeyword(seld)?.typeCodeValue == fourCharCode("pURL"))
        let tab = try #require(spec.forKeyword(from))
        #expect(tab.forKeyword(seld)?.typeCodeValue == fourCharCode("cTab"))
        let window = try #require(tab.forKeyword(from))
        #expect(window.forKeyword(want)?.typeCodeValue == fourCharCode("cwin"))
        #expect(window.forKeyword(seld)?.int32Value == 1)
        #expect(window.forKeyword(from)?.descriptorType == fourCharCode("null"))
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
/// and, where granted, its front window's URL. With
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
            let reading = provider.activeTabURL(of: app)
            let kind = reading.url == nil ? String(describing: reading) : "url (not shown)"
            print("\(name): permission \(permission.rawValue); reading \(kind)")
            if permission != .granted { #expect(reading.url == nil) }
        }
    }
}
