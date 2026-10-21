import Foundation

/// The frontmost application, as reported by the system.
public struct FrontmostApp: Sendable, Hashable {
    /// Bundle identifier, for example `com.apple.finder`; `nil` for the rare
    /// process without a bundle.
    public var bundleID: String?
    /// Localised display name, for example "Finder".
    public var name: String?
    /// Process identifier. Tells two instances of one bundle apart; not
    /// stable across launches, so it is never meant to be stored.
    public var processID: Int32

    public init(bundleID: String?, name: String?, processID: Int32) {
        self.bundleID = bundleID
        self.name = name
        self.processID = processID
    }
}

/// One observation from an `ActivitySource`: which app is frontmost and,
/// when allowed, the title of its focused window and, for a known browser,
/// what its active tab's URL reading was.
///
/// Raw and unfiltered. Window titles and URLs can contain sensitive text
/// (document names, email subjects, chat partners, query strings), so a
/// sample must pass the privacy filter (#20) before it is stored or shown.
public struct ActivitySample: Sendable, Equatable {
    /// Why the source emitted the sample.
    public enum Trigger: String, Sendable, CaseIterable {
        /// The state at the moment the source started (or resumed).
        case snapshot
        /// Another app became frontmost.
        case appActivated
        /// The frontmost app's focused window, or that window's title, changed.
        case titleChanged
    }

    public var timestamp: Date
    public var trigger: Trigger
    public var app: FrontmostApp
    /// Focused window title. `nil` when titles are not allowed (no
    /// Accessibility permission, or the window-title policy said no), when
    /// the app has no focused window, or when the title could not be read.
    public var windowTitle: String?
    /// The browser URL reading (#19). `nil` means only "not a web sample":
    /// the app is not a known browser, or its title was not allowed (the
    /// URL is never read then). A known browser whose URL could not be read
    /// reports `.unreadable`; the privacy filter drops such a sample's title.
    /// Raw until filtered; after ``PrivacyFilter/filter(_:)`` it is redacted.
    public var browserURL: BrowserURLReading?

    /// The URL, if one was read (`browserURL` is `.url`).
    public var url: String? { browserURL?.url }

    public init(
        timestamp: Date, trigger: Trigger, app: FrontmostApp, windowTitle: String?,
        browserURL: BrowserURLReading? = nil
    ) {
        self.timestamp = timestamp
        self.trigger = trigger
        self.app = app
        self.windowTitle = windowTitle
        self.browserURL = browserURL
    }
}

/// Decides, per app, whether a source may read the focused window title.
/// Asked before the title is read, so a "no" means the title is never read.
public typealias WindowTitlePolicy = @MainActor (FrontmostApp) -> Bool

/// Reports the frontmost app, its focused window title and, for known
/// browsers, the active tab's URL. Event driven: implementations react to
/// system notifications rather than polling.
///
/// Contract:
/// - `start` emits a `.snapshot` sample for the current frontmost app (if
///   any), then `.appActivated` on every app switch and `.titleChanged` when
///   the focused window or its title changes.
/// - Before reading a title the source asks `windowTitlePolicy`; when it
///   returns false the sample's `windowTitle` is `nil`, no title is read and
///   no `.titleChanged` samples are emitted for that app.
/// - The source never reads titles of its own process (Unreality's own
///   windows): those samples are app-only and the policy is not asked.
/// - A browser URL (#19) is read only when the policy allowed the title and
///   the app is a ``KnownBrowser``, through the source's
///   ``BrowserURLProvider``; otherwise `browserURL` is `nil`. A source
///   without a provider never reads URLs.
/// - `.titleChanged` is emitted only when the title, or the browser URL
///   reading, differs from the last one emitted.
/// - After `stop` nothing is emitted. Calling `start` while started replaces
///   the handler and policy and emits a fresh snapshot.
@MainActor
public protocol ActivitySource: AnyObject {
    var isRunning: Bool { get }

    func start(
        windowTitlePolicy: @escaping WindowTitlePolicy,
        handler: @escaping @MainActor (ActivitySample) -> Void
    )

    func stop()
}

/// Test double for `ActivitySource`. Drive it with `activate(_:title:)` and
/// `setTitle(_:)`; it honours the contract above, including the policy and
/// asking its `BrowserURLProvider` (if any) only for allowed known browsers.
@MainActor
public final class FakeActivitySource: ActivitySource {
    public private(set) var isRunning = false
    /// How many times `start` was called.
    public private(set) var startCount = 0
    /// The simulated frontmost app and its (unfiltered) window title.
    public private(set) var frontmost: FrontmostApp?
    public private(set) var currentTitle: String?
    /// Apps whose title the policy was asked about, in order.
    public private(set) var titlePolicyQueries: [FrontmostApp] = []

    private let clock: any WallClock
    private let urlProvider: (any BrowserURLProvider)?
    private var policy: WindowTitlePolicy?
    private var handler: (@MainActor (ActivitySample) -> Void)?
    private var lastEmitted: (title: String?, url: BrowserURLReading?)?

    public init(
        clock: any WallClock = FakeTime(), frontmost: FrontmostApp? = nil, title: String? = nil,
        urlProvider: (any BrowserURLProvider)? = nil
    ) {
        self.clock = clock
        self.frontmost = frontmost
        currentTitle = title
        self.urlProvider = urlProvider
    }

    public func start(
        windowTitlePolicy: @escaping WindowTitlePolicy,
        handler: @escaping @MainActor (ActivitySample) -> Void
    ) {
        startCount += 1
        isRunning = true
        policy = windowTitlePolicy
        self.handler = handler
        emit(.snapshot)
    }

    public func stop() {
        isRunning = false
        policy = nil
        handler = nil
        lastEmitted = nil
    }

    /// Makes `app` frontmost with focused window `title`.
    public func activate(_ app: FrontmostApp, title: String? = nil) {
        frontmost = app
        currentTitle = title
        emit(.appActivated)
    }

    /// Changes the frontmost app's focused window title (for a browser, the
    /// URL is read again, as on a tab switch).
    public func setTitle(_ title: String?) {
        currentTitle = title
        guard isRunning, let app = frontmost, allowsTitle(for: app) else { return }
        let url = browserURL(for: app)
        if let lastEmitted, lastEmitted.title == title, lastEmitted.url == url { return }
        send(.titleChanged, app: app, title: title, url: url)
    }

    private func allowsTitle(for app: FrontmostApp) -> Bool {
        guard let policy, app.processID != ProcessInfo.processInfo.processIdentifier else { return false }
        titlePolicyQueries.append(app)
        return policy(app)
    }

    private func browserURL(for app: FrontmostApp) -> BrowserURLReading? {
        guard let urlProvider, KnownBrowser.isBrowser(app) else { return nil }
        return urlProvider.activeTabURL(of: app)
    }

    private func emit(_ trigger: ActivitySample.Trigger) {
        guard isRunning, let app = frontmost else { return }
        if allowsTitle(for: app) {
            send(trigger, app: app, title: currentTitle, url: browserURL(for: app))
        } else {
            send(trigger, app: app, title: nil, url: nil)
        }
    }

    private func send(_ trigger: ActivitySample.Trigger, app: FrontmostApp, title: String?, url: BrowserURLReading?) {
        lastEmitted = (title, url)
        handler?(ActivitySample(timestamp: clock.now(), trigger: trigger, app: app, windowTitle: title,
                                browserURL: url))
    }
}
