import Foundation

/// An event that passed the privacy rules: not from an excluded app or site,
/// with its URL redacted. Only ``PrivacyRules`` (the logic behind
/// ``PrivacyFilter``) can create one: the initialiser is private to this
/// file, and the type is deliberately not `Decodable`. Storage accepts
/// nothing else (``ActivityRepository/insert(_:)``), so excluded or
/// unredacted data cannot be stored by construction.
///
/// It never carries a process ID or app display name.
public struct FilteredEvent: Sendable, Equatable {
    public let kind: ActivityEventKind
    public let appBundleID: String?
    public let windowTitle: String?
    /// Redacted URL (see ``URLRedaction``); `nil` when there was none.
    public let url: String?
    public let startedAt: Date
    public let endedAt: Date
    public let source: String
    public let sessionID: Int64?

    fileprivate init(
        kind: ActivityEventKind, appBundleID: String?, windowTitle: String?, url: String?,
        span: (start: Date, end: Date), source: String, sessionID: Int64?
    ) {
        self.kind = kind
        self.appBundleID = appBundleID
        self.windowTitle = windowTitle
        self.url = url
        startedAt = span.start
        endedAt = span.end
        self.source = source
        self.sessionID = sessionID
    }
}

/// Why the privacy rules dropped activity. Carries no captured data.
public enum PrivacyDropReason: Error, Sendable, Equatable, CaseIterable {
    /// The frontmost app is on the blocklist.
    case excludedApp
    /// The URL's host is on the blocklist.
    case excludedSite
    /// A URL was present but could not be parsed, or had no host to check
    /// (other than `about:` and `data:`), so the site could not be checked
    /// (fails closed). Wrapped URLs (`blob:`, `view-source:`,
    /// `filesystem:`) are checked by their inner URL.
    case uncheckableURL
    /// A browser-extension page (`chrome-extension://`,
    /// `safari-web-extension://`, ...), for example a password manager's
    /// vault opened in a tab.
    case excludedExtensionPage
    /// A browser-internal page that shows saved passwords, passkeys,
    /// payment methods, addresses or a wallet (`chrome://password-manager`,
    /// `edge://wallet`, `chrome://settings/payments`, `about:logins`).
    case excludedBrowserPage
}

/// Outcome of ``PrivacyRules/evaluate(_:until:url:source:sessionID:)``.
public enum PrivacyDecision: Sendable, Equatable {
    case keep(FilteredEvent)
    case drop(PrivacyDropReason)
}

/// The privacy filter's pure logic: a value type, usable from any thread
/// (for example where samples are turned into stored events, off the main
/// actor). ``PrivacyFilter`` exposes it to `ActivityCoordinator`.
/// See docs/PRIVACY.md, "Privacy filter".
public struct PrivacyRules: Sendable, Equatable {
    public var blocklist: Blocklist
    public var urlRedaction: URLRedaction

    /// - Parameters:
    ///   - blocklist: defaults to ``Blocklist/defaults``; add user entries
    ///     with `Blocklist.defaults.union(userEntries)`.
    ///   - urlRedaction: defaults to ``URLRedaction/keepPath``.
    public init(blocklist: Blocklist = .defaults, urlRedaction: URLRedaction = .keepPath) {
        self.blocklist = blocklist
        self.urlRedaction = urlRedaction
    }

    /// Whether `app`'s window titles may be read at all: false for excluded
    /// apps and for apps without a bundle ID (no rule could match them).
    /// `ActivityCoordinator` also refuses Unreality's own process.
    public func allowsWindowTitle(for app: FrontmostApp) -> Bool {
        app.bundleID != nil && !isExcluded(app)
    }

    /// `sample` as it may be passed on, or `nil` when it must be dropped:
    ///
    /// - From an excluded app (including app-only samples without a title):
    ///   dropped.
    /// - From an app without a bundle ID: kept without title or URL (fails
    ///   closed on an unknown app).
    /// - With a browser URL (#19): dropped when the site is excluded, the
    ///   page is a browser-extension or browser-internal password, payment
    ///   or wallet page, or the URL cannot be checked. Otherwise the URL is
    ///   replaced by its redacted form (query, fragment, credentials and `;`
    ///   parameters dropped), and the title is dropped for `about:` and
    ///   `data:` pages, whose title may come from the page that opened them.
    /// - From a ``KnownBrowser`` without a readable URL (`.unreadable`, or
    ///   no reading at all): kept without its title, since the site behind
    ///   the title could not be checked.
    ///
    /// Filtering a filtered sample again gives the same sample.
    public func filter(_ sample: ActivitySample) -> ActivitySample? {
        if case let .success(filtered) = screen(sample) { return filtered }
        return nil
    }

    /// The event to store for the activity `sample` started, lasting until
    /// `end`, or why it must be dropped. Applies ``filter(_:)`` again, so an
    /// unfiltered sample cannot slip through. The event is a `.web` event
    /// when the filtered sample has a URL, otherwise `.app`.
    /// - Parameters:
    ///   - url: overrides the sample's `browserURL` with this URL as the
    ///     browser reported it (unredacted); `nil` uses the sample's own.
    ///   - source: the capture source, for example `workspace`.
    public func evaluate(
        _ sample: ActivitySample, until end: Date, url: String? = nil, source: String, sessionID: Int64? = nil
    ) -> PrivacyDecision {
        var sample = sample
        if let url { sample.browserURL = .url(url) }
        switch screen(sample) {
        case let .failure(reason):
            return .drop(reason)
        case let .success(sample):
            return .keep(FilteredEvent(
                kind: sample.url == nil ? .app : .web,
                appBundleID: sample.app.bundleID,
                windowTitle: sample.windowTitle,
                url: sample.url,
                span: (sample.timestamp, end),
                source: source,
                sessionID: sessionID
            ))
        }
    }

    private func screen(_ sample: ActivitySample) -> Result<ActivitySample, PrivacyDropReason> {
        if isExcluded(sample.app) { return .failure(.excludedApp) }
        var sample = sample
        guard sample.app.bundleID != nil else {
            sample.windowTitle = nil
            sample.browserURL = nil
            return .success(sample)
        }
        switch sample.browserURL {
        case let .url(raw)?:
            switch RedactableURL.parse(raw) {
            case let .failure(reason):
                return .failure(reason)
            case let .success(parsed):
                if let host = parsed.host, blocklist.excludes(host: host) { return .failure(.excludedSite) }
                sample.browserURL = .url(parsed.redacted(urlRedaction))
                if !parsed.keepsTitle { sample.windowTitle = nil }
            }
        case .unreadable?:
            sample.windowTitle = nil
        case nil:
            if KnownBrowser.isBrowser(sample.app) { sample.windowTitle = nil }
        }
        return .success(sample)
    }

    /// Like ``evaluate(_:until:url:source:sessionID:)``, returning `nil`
    /// when the activity must be dropped.
    public func event(
        from sample: ActivitySample, until end: Date, url: String? = nil, source: String, sessionID: Int64? = nil
    ) -> FilteredEvent? {
        if case let .keep(event) = evaluate(sample, until: end, url: url, source: source, sessionID: sessionID) {
            return event
        }
        return nil
    }

    /// An idle span: no app, title or URL, so there is nothing to exclude.
    public func idleEvent(from start: Date, until end: Date, source: String, sessionID: Int64? = nil) -> FilteredEvent {
        FilteredEvent(kind: .idle, appBundleID: nil, windowTitle: nil, url: nil,
                      span: (start, end), source: source, sessionID: sessionID)
    }

    private func isExcluded(_ app: FrontmostApp) -> Bool {
        guard let bundleID = app.bundleID else { return false }
        return blocklist.excludes(bundleID: bundleID)
    }
}

/// The real `ActivitySampleFilter` for `ActivityCoordinator`: asked before
/// any window title is read, and run on every sample. Excluded apps' titles
/// are never read and their samples (also app-only ones) are dropped.
///
/// The app keeps one instance as the single source of truth for the user's
/// rules: update ``rules`` to apply a changed blocklist (settings UI, M6),
/// and build stored events through ``event(from:until:url:source:sessionID:)``
/// on this instance, then hand the `Sendable` `FilteredEvent` to storage,
/// rather than keeping a copy of the rules that could go stale.
@MainActor
public final class PrivacyFilter: ActivitySampleFilter {
    public var rules: PrivacyRules

    public init(rules: PrivacyRules = PrivacyRules()) {
        self.rules = rules
    }

    public func allowsWindowTitle(for app: FrontmostApp) -> Bool {
        rules.allowsWindowTitle(for: app)
    }

    public func filter(_ sample: ActivitySample) -> ActivitySample? {
        rules.filter(sample)
    }

    /// ``PrivacyRules/evaluate(_:until:url:source:sessionID:)`` with the current rules.
    public func evaluate(
        _ sample: ActivitySample, until end: Date, url: String? = nil, source: String, sessionID: Int64? = nil
    ) -> PrivacyDecision {
        rules.evaluate(sample, until: end, url: url, source: source, sessionID: sessionID)
    }

    /// ``PrivacyRules/event(from:until:url:source:sessionID:)`` with the current rules.
    public func event(
        from sample: ActivitySample, until end: Date, url: String? = nil, source: String, sessionID: Int64? = nil
    ) -> FilteredEvent? {
        rules.event(from: sample, until: end, url: url, source: source, sessionID: sessionID)
    }

    /// ``PrivacyRules/idleEvent(from:until:source:sessionID:)``.
    public func idleEvent(from start: Date, until end: Date, source: String, sessionID: Int64? = nil) -> FilteredEvent {
        rules.idleEvent(from: start, until: end, source: source, sessionID: sessionID)
    }
}

// MARK: - Redacting descriptions

/// Window titles and URLs never appear in `print`, string interpolation,
/// `dump` or debugger summaries of activity types, so passing one to a
/// logger by mistake does not leak them.
enum ActivityRedaction {
    static func redacted(_ value: String?) -> String { value == nil ? "nil" : "<redacted>" }
}

protocol RedactedActivityDescription {
    var kind: ActivityEventKind { get }
    var appBundleID: String? { get }
    var windowTitle: String? { get }
    var url: String? { get }
    var startedAt: Date { get }
    var endedAt: Date { get }
    var source: String { get }
}

extension RedactedActivityDescription {
    /// `Type(id: …, kind: …, app: …, title: <redacted>, url: <redacted>, from: …, to: …, source: …)`;
    /// a title or URL that is absent shows as `nil`.
    func redactedDescription(id: Int64? = nil) -> String {
        var fields: [String] = []
        if let id { fields.append("id: \(id)") }
        fields.append("kind: \(kind.rawValue)")
        fields.append("app: \(appBundleID ?? "nil")")
        fields.append("title: \(ActivityRedaction.redacted(windowTitle))")
        fields.append("url: \(ActivityRedaction.redacted(url))")
        fields.append("from: \(startedAt.timeIntervalSince1970)")
        fields.append("to: \(endedAt.timeIntervalSince1970)")
        fields.append("source: \(source)")
        return "\(Self.self)(\(fields.joined(separator: ", ")))"
    }
}

extension FilteredEvent: RedactedActivityDescription, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    public var description: String { redactedDescription() }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

extension ActivityEvent: RedactedActivityDescription, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    public var description: String { redactedDescription(id: id) }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

extension ActivitySample: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        let app = app.bundleID ?? "nil"
        let browserURL: String
        switch self.browserURL {
        case nil: browserURL = "nil"
        case .url?: browserURL = "<redacted>"
        case let .unreadable(reason)?: browserURL = "unreadable(\(reason.rawValue))"
        }
        return "ActivitySample(trigger: \(trigger.rawValue), app: \(app), "
            + "title: \(ActivityRedaction.redacted(windowTitle)), url: \(browserURL), "
            + "at: \(timestamp.timeIntervalSince1970))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

extension BrowserURLReading: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        switch self {
        case .url: "BrowserURLReading.url(<redacted>)"
        case let .unreadable(reason): "BrowserURLReading.unreadable(\(reason.rawValue))"
        }
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .enum) }
}
