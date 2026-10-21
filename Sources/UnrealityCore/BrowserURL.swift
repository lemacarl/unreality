import Foundation

/// A browser Unreality knows by bundle ID, and how (if at all) the URL of its
/// active tab can be read. Used by capture sources (only known browsers are
/// asked for a URL) and by the privacy filter (a known browser's sample
/// without a readable URL loses its window title).
///
/// The list is in docs/PRIVACY.md, "Browser URLs"; keep both in sync.
public struct KnownBrowser: Sendable, Hashable {
    /// How the active tab's URL is read.
    public enum Scripting: String, Sendable, CaseIterable {
        /// Safari's scripting dictionary: `URL of current tab of front window`.
        case safari
        /// Chrome's scripting dictionary (Chrome and its derivatives):
        /// `URL of active tab of front window`, after checking that the
        /// window's `mode` is not `incognito`.
        case chromium
        /// No supported way to read the URL (for example Firefox, which has
        /// no scripting dictionary for tabs, and web-app shells). Samples
        /// from these browsers never carry a URL, so their titles are dropped.
        case unsupported
    }

    public let name: String
    public let scripting: Scripting
    /// Exact bundle identifiers, lowercased.
    public let bundleIDs: Set<String>
    /// Lowercased bundle identifier prefixes, each ending in `.`.
    public let bundleIDPrefixes: [String]

    public init(name: String, scripting: Scripting, bundleIDs: [String], bundleIDPrefixes: [String] = []) {
        self.name = name
        self.scripting = scripting
        self.bundleIDs = Set(bundleIDs.map { $0.lowercased() })
        self.bundleIDPrefixes = bundleIDPrefixes.map { $0.lowercased() }
    }

    /// The known browser with `bundleID` (case-insensitive), or `nil`.
    public static func matching(bundleID: String?) -> KnownBrowser? {
        guard let bundleID else { return nil }
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.first { $0.bundleIDs.contains(id) || $0.bundleIDPrefixes.contains { id.hasPrefix($0) } }
    }

    /// Whether `app` is a known browser.
    public static func isBrowser(_ app: FrontmostApp) -> Bool { matching(bundleID: app.bundleID) != nil }

    /// Every known browser. Entries marked unverified in docs/PRIVACY.md are
    /// best guesses; an unreadable URL only costs the title, never leaks it.
    public static let all: [KnownBrowser] = [
        KnownBrowser(name: "Safari", scripting: .safari,
                     bundleIDs: ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]),
        KnownBrowser(name: "Google Chrome", scripting: .chromium, bundleIDs: [
            "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary"
        ]),
        KnownBrowser(name: "Chromium", scripting: .chromium, bundleIDs: ["org.chromium.Chromium"]),
        KnownBrowser(name: "Arc", scripting: .chromium, bundleIDs: ["company.thebrowser.Browser"]),
        KnownBrowser(name: "Brave", scripting: .chromium, bundleIDs: [
            "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly"
        ]),
        KnownBrowser(name: "Microsoft Edge", scripting: .chromium, bundleIDs: [
            "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
            "com.microsoft.edgemac.Canary"
        ]),
        KnownBrowser(name: "Firefox", scripting: .unsupported, bundleIDs: [
            "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"
        ]),
        // Not supported yet: no verified scripting support. Their titles
        // are dropped. Bundle IDs other than Firefox's are unverified.
        KnownBrowser(name: "Other browsers", scripting: .unsupported, bundleIDs: [
            "org.torproject.torbrowser", "net.mullvad.mullvadbrowser", "com.duckduckgo.macos.browser",
            "net.waterfox.waterfox", "app.zen-browser.zen", "org.mozilla.librewolf",
            "com.operasoftware.Opera", "com.operasoftware.OperaGX", "com.vivaldi.Vivaldi",
            "company.thebrowser.dia", "com.kagi.kagimacOS"
        ]),
        // Installed web apps show one site in their own window; their URL
        // cannot be read, so their titles are dropped.
        KnownBrowser(name: "Web apps", scripting: .unsupported, bundleIDs: [], bundleIDPrefixes: [
            "com.apple.Safari.WebApp.", "com.google.Chrome.app.", "com.microsoft.edgemac.app.",
            "com.brave.Browser.app.", "org.chromium.Chromium.app."
        ])
    ]
}

/// What a browser reported about its frontmost window's active tab.
public enum BrowserURLReading: Sendable, Equatable {
    /// The URL exactly as the browser reports it. Browsers normalise URLs
    /// (WHATWG URL parsing: `\` in the authority becomes `/`, and so on), so
    /// providers must pass the browser's own string, never a URL parsed out
    /// of a window title or address-bar text. Raw and unredacted until the
    /// privacy filter has seen it.
    case url(String)
    /// The browser is known but its URL could not be read.
    case unreadable(BrowserURLUnavailability)

    /// The URL, if one was read.
    public var url: String? {
        if case let .url(url) = self { return url }
        return nil
    }

    /// Whether a source should treat `new` as no change from `old` when the
    /// window title is also unchanged, so it emits no `.titleChanged`
    /// sample: equal readings, or either one is `.unreadable(.failed)` (an
    /// intermittent failure, such as a timeout, is not a new observation).
    /// The sample already emitted stays in force: an earlier URL was already
    /// checked, and an earlier failure already dropped the title.
    public static func isUnchanged(_ old: BrowserURLReading?, _ new: BrowserURLReading?) -> Bool {
        old == new || old == .unreadable(.failed) || new == .unreadable(.failed)
    }
}

/// Why a known browser's URL could not be read. Carries no captured data.
public enum BrowserURLUnavailability: String, Sendable, CaseIterable {
    /// The user denied Unreality's Automation permission for this browser.
    case automationDenied
    /// Automation permission for this browser has not been decided yet.
    /// Providers never prompt while reading; the user grants it explicitly.
    case automationNotDetermined
    /// The browser offers no supported way to read the URL (Firefox, web apps).
    case unsupportedBrowser
    /// The front window is a private (incognito) window.
    case privateWindow
    /// No window or tab to read (or the front window is not a browser
    /// window, such as Safari's Settings window).
    case noWindow
    /// The browser's front window is not provably the focused window whose
    /// title was read (its name differs, or there was no title), so the
    /// title and URL could belong to different windows.
    case windowMismatch
    /// The read failed (timeout, unexpected reply, the browser quit).
    case failed
}

/// Automation (Apple Events) permission for one browser, as macOS reports
/// it in System Settings > Privacy & Security > Automation.
public enum BrowserAutomationPermission: String, Sendable, CaseIterable {
    case granted
    case denied
    /// Not decided yet: reading would show a system prompt, so providers do
    /// not read until the user grants it explicitly.
    case notDetermined
    /// The browser is not running, so macOS cannot report the state.
    case notRunning
    /// Not a browser whose URL can be read (unknown app, Firefox, web apps).
    case notApplicable
    /// macOS returned an unexpected status.
    case unknown
}

/// Reads the active tab URL of a known browser's frontmost window.
///
/// Contract:
/// - Only called for known browsers (``KnownBrowser``), after the
///   window-title policy allowed reading that app's title: excluded apps are
///   never asked, and paused capture asks nothing.
/// - Reading never prompts. Without Automation permission it returns
///   `.unreadable(.automationNotDetermined)` or `.unreadable(.automationDenied)`.
/// - Private windows return `.unreadable(.privateWindow)` where the browser
///   says so (Chrome family); a URL is never read from them.
/// - A URL is returned only from the window whose name equals
///   `focusedWindowTitle` (the focused window's Accessibility title);
///   otherwise `.unreadable(.windowMismatch)`.
/// - The URL returned is the browser's own, normalised string.
/// - Sources call ``resetCachedState()`` on every app activation and on
///   stop, so per-process caches (a granted permission, an unresponsive
///   browser) last at most until the frontmost app changes.
@MainActor
public protocol BrowserURLProvider: AnyObject {
    /// The active tab URL of `app`'s front window, if that window's name is
    /// `focusedWindowTitle`. Synchronous, with short timeouts; never prompts.
    func activeTabURL(of app: FrontmostApp, focusedWindowTitle: String?) -> BrowserURLReading

    /// Forgets per-process state (cached permission, unresponsive marks).
    func resetCachedState()

    /// The Automation permission state for `app`, without prompting.
    func automationPermission(for app: FrontmostApp) -> BrowserAutomationPermission

    /// Asks macOS for Automation permission for `app`, showing the system
    /// prompt if the user has not decided yet. Explicit user action only
    /// (an onboarding or settings button), never at launch or while capturing.
    func requestAutomationPermission(for app: FrontmostApp) async -> BrowserAutomationPermission
}

/// Test double for `BrowserURLProvider`: returns configured readings per
/// bundle ID and records every query.
@MainActor
public final class FakeBrowserURLProvider: BrowserURLProvider {
    /// Readings by bundle ID; apps without an entry read as `defaultReading`.
    public var readings: [String: BrowserURLReading]
    public var defaultReading: BrowserURLReading
    /// Permission states by bundle ID; others are `.notApplicable`.
    public var permissions: [String: BrowserAutomationPermission]
    /// What `requestAutomationPermission` turns a `.notDetermined` state into.
    public var userAnswer: BrowserAutomationPermission
    /// Apps whose URL was read, in order.
    public private(set) var urlQueries: [FrontmostApp] = []
    /// The focused-window titles passed with those reads, in order.
    public private(set) var urlQueryTitles: [String?] = []
    /// Apps for which permission was requested (a prompt), in order.
    public private(set) var permissionRequests: [FrontmostApp] = []
    /// How many times `resetCachedState()` was called.
    public private(set) var resetCount = 0

    public init(
        readings: [String: BrowserURLReading] = [:],
        defaultReading: BrowserURLReading = .unreadable(.failed),
        permissions: [String: BrowserAutomationPermission] = [:],
        userAnswer: BrowserAutomationPermission = .granted
    ) {
        self.readings = readings
        self.defaultReading = defaultReading
        self.permissions = permissions
        self.userAnswer = userAnswer
    }

    public func activeTabURL(of app: FrontmostApp, focusedWindowTitle: String?) -> BrowserURLReading {
        urlQueries.append(app)
        urlQueryTitles.append(focusedWindowTitle)
        return app.bundleID.flatMap { readings[$0] } ?? defaultReading
    }

    public func resetCachedState() {
        resetCount += 1
    }

    public func automationPermission(for app: FrontmostApp) -> BrowserAutomationPermission {
        app.bundleID.flatMap { permissions[$0] } ?? .notApplicable
    }

    public func requestAutomationPermission(for app: FrontmostApp) async -> BrowserAutomationPermission {
        permissionRequests.append(app)
        let state = automationPermission(for: app)
        guard state == .notDetermined, let bundleID = app.bundleID else { return state }
        permissions[bundleID] = userAnswer
        return userAnswer
    }
}
