import AppKit
import ApplicationServices
import UnrealityCore

/// `ActivitySource` for the frontmost app and its focused window title.
///
/// - App switches come from `NSWorkspace.didActivateApplicationNotification`
///   (no permission needed): bundle ID, localised name and process ID.
/// - Window titles come from the Accessibility API (`AXUIElement`), which
///   needs the Accessibility permission. Only when the window-title policy
///   allows it for the frontmost app does the source read the focused
///   window's title and register an `AXObserver` on that one app for focused
///   window and title changes. Nothing is polled: both paths are notifications.
///   Without permission (or when the policy says no) samples are app-only.
/// - Unreality's own process is always app-only: the policy is not asked
///   and no AX call or observer ever targets our own process.
/// - Browser URLs (#19): only when the policy allowed the title and the app
///   is a ``KnownBrowser``, the source asks its `BrowserURLProvider` (if
///   any) for the active tab's URL: on activation and on every title or
///   focused-window change, so a tab switch reads the new tab's URL.
///
/// Main-actor bound: workspace notifications are delivered on the main queue
/// and the observer's run-loop source is added to the main run loop. Release
/// it on the main thread (its `deinit` removes the observers).
@MainActor
public final class WorkspaceActivitySource: ActivitySource {
    /// The Accessibility observer for the current frontmost app.
    private struct Tracking {
        let app: FrontmostApp
        let element: AXUIElement
        let observer: AXObserver
        var window: AXUIElement?
        /// The app did not answer in time; skip further AX calls until it
        /// sends a notification or is activated again.
        var unresponsive = false
    }

    private static let ownProcessID = ProcessInfo.processInfo.processIdentifier

    public private(set) var isRunning = false

    private let workspace: NSWorkspace
    private let notificationCenter: NotificationCenter
    private let clock: any WallClock
    private let messagingTimeout: Float
    private let browserURLProvider: (any BrowserURLProvider)?
    private var policy: WindowTitlePolicy?
    private var handler: (@MainActor (ActivitySample) -> Void)?
    private var frontmost: FrontmostApp?
    private var lastEmitted: (title: String?, url: BrowserURLReading?)?
    // `nonisolated(unsafe)` only so `deinit` can release them: every other
    // access is main-actor isolated, and deinit has exclusive access.
    nonisolated(unsafe) private var activationObserver: (any NSObjectProtocol)?
    nonisolated(unsafe) private var tracking: Tracking?

    /// - Parameters:
    ///   - messagingTimeout: seconds to wait for an unresponsive app to
    ///     answer an Accessibility request before giving up on its title.
    ///   - browserURLProvider: reads known browsers' URLs; `nil` reads none
    ///     (the privacy filter then drops browser titles).
    public init(
        workspace: NSWorkspace = .shared,
        clock: any WallClock = SystemClock(),
        messagingTimeout: Float = 0.25,
        browserURLProvider: (any BrowserURLProvider)? = nil
    ) {
        self.workspace = workspace
        notificationCenter = workspace.notificationCenter
        self.clock = clock
        self.messagingTimeout = messagingTimeout
        self.browserURLProvider = browserURLProvider
    }

    deinit {
        if let activationObserver { notificationCenter.removeObserver(activationObserver) }
        if let tracking {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(tracking.observer), .commonModes)
        }
    }

    public func start(
        windowTitlePolicy: @escaping WindowTitlePolicy,
        handler: @escaping @MainActor (ActivitySample) -> Void
    ) {
        stop()
        policy = windowTitlePolicy
        self.handler = handler
        isRunning = true
        activationObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: workspace,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let snapshot = app.map(Self.describe)
            MainActor.assumeIsolated { self?.activated(snapshot, trigger: .appActivated) }
        }
        activated(workspace.frontmostApplication.map(Self.describe), trigger: .snapshot)
    }

    public func stop() {
        if let activationObserver { notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        stopTracking()
        isRunning = false
        policy = nil
        handler = nil
        frontmost = nil
        lastEmitted = nil
    }

    nonisolated private static func describe(_ app: NSRunningApplication) -> FrontmostApp {
        FrontmostApp(bundleID: app.bundleIdentifier, name: app.localizedName, processID: app.processIdentifier)
    }

    private func activated(_ app: FrontmostApp?, trigger: ActivitySample.Trigger) {
        guard isRunning, let app else { return }
        stopTracking()
        frontmost = app
        var title: String?
        var url: BrowserURLReading?
        // Unreality's own windows are never read: no feedback loop of
        // captured titles, and no AX round trips into our own (main) thread.
        if app.processID != Self.ownProcessID, policy?(app) == true {
            startTracking(app)
            title = focusedWindowTitle()
            url = browserURL(of: app)
        }
        emit(trigger, app: app, title: title, url: url)
    }

    /// Called from the Accessibility observer callback.
    fileprivate func accessibilityChanged(_ notification: String) {
        guard isRunning, let app = frontmost, tracking?.app == app else { return }
        guard policy?(app) == true else {
            // Permission revoked or app newly excluded: stop reading titles.
            stopTracking()
            return
        }
        // A callback means the app answers again.
        tracking?.unresponsive = false
        if notification == kAXFocusedWindowChangedNotification { watchFocusedWindow() }
        let title = focusedWindowTitle()
        let url = browserURL(of: app)
        if let lastEmitted, lastEmitted.title == title, lastEmitted.url == url { return }
        emit(.titleChanged, app: app, title: title, url: url)
    }

    /// Only called after the policy allowed `app`'s title.
    private func browserURL(of app: FrontmostApp) -> BrowserURLReading? {
        guard let browserURLProvider, KnownBrowser.isBrowser(app) else { return nil }
        return browserURLProvider.activeTabURL(of: app)
    }

    private func emit(_ trigger: ActivitySample.Trigger, app: FrontmostApp, title: String?, url: BrowserURLReading?) {
        lastEmitted = (title, url)
        handler?(ActivitySample(timestamp: clock.now(), trigger: trigger, app: app, windowTitle: title,
                                browserURL: url))
    }

    // MARK: Accessibility
    //
    // Every AX call below is a synchronous round trip to the target app on
    // the main thread. `AXUIElementSetMessagingTimeout` applies only to the
    // element it is set on (AXUIElement.h), so it is set on the app element
    // and on every window element we use. The calls stop at the first
    // `kAXErrorCannotComplete` (the app did not answer in time), so an
    // unresponsive app costs at most one timeout per activation.

    private func startTracking(_ app: FrontmostApp) {
        let element = AXUIElementCreateApplication(app.processID)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        var created: AXObserver?
        guard AXObserverCreate(app.processID, accessibilityCallback, &created) == .success,
              let observer = created
        else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // Fails for apps without AX support (no titles then) or when the app
        // does not answer in time (give up until the next activation).
        let added = AXObserverAddNotification(
            observer, element, kAXFocusedWindowChangedNotification as CFString, refcon
        )
        guard added != .cannotComplete else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        tracking = Tracking(app: app, element: element, observer: observer)
        watchFocusedWindow()
    }

    private func stopTracking() {
        guard let tracking else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(tracking.observer), .commonModes)
        self.tracking = nil
    }

    /// Moves the title-change subscription to the currently focused window.
    private func watchFocusedWindow() {
        guard var current = tracking, !current.unresponsive else { return }
        if let window = current.window {
            AXObserverRemoveNotification(current.observer, window, kAXTitleChangedNotification as CFString)
        }
        current.window = nil
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(current.element, kAXFocusedWindowAttribute as CFString, &value)
        if result == .cannotComplete {
            current.unresponsive = true
        } else if result == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            let window = unsafeDowncast(value, to: AXUIElement.self)
            AXUIElementSetMessagingTimeout(window, messagingTimeout)
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            let added = AXObserverAddNotification(
                current.observer, window, kAXTitleChangedNotification as CFString, refcon
            )
            current.unresponsive = added == .cannotComplete
            current.window = window
        }
        tracking = current
    }

    /// Title of the window `watchFocusedWindow` found (no second lookup).
    private func focusedWindowTitle() -> String? {
        guard let current = tracking, !current.unresponsive, let window = current.window else { return nil }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value)
        if result == .cannotComplete { tracking?.unresponsive = true }
        guard result == .success, let title = value as? String, !title.isEmpty else { return nil }
        return title
    }
}

/// C callback for `AXObserver`; `refcon` is the source, unretained. The
/// observer's run-loop source is on the main run loop and is removed before
/// the source is released, so the pointer is valid whenever this runs.
private func accessibilityCallback(
    _: AXObserver,
    _: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let source = Unmanaged<WorkspaceActivitySource>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    MainActor.assumeIsolated { source.accessibilityChanged(name) }
}
