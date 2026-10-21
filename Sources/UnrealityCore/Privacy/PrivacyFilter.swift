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

extension FilteredEvent {
    /// This event assigned to session `id` (`nil`: no session); every other
    /// field is unchanged, so nothing the rules decided can be altered. For
    /// writers that learn the session's row id only after the event was
    /// built (``RepositoryRecordWriter``).
    public func inSession(_ id: Int64?) -> FilteredEvent {
        FilteredEvent(kind: kind, appBundleID: appBundleID, windowTitle: windowTitle, url: url,
                      span: (startedAt, endedAt), source: source, sessionID: id)
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

    /// `sample`, or `nil` when it comes from an excluded app (including
    /// app-only samples without a title). A sample from an app without a
    /// bundle ID is kept without its title (fails closed on an unknown app).
    public func filter(_ sample: ActivitySample) -> ActivitySample? {
        if isExcluded(sample.app) { return nil }
        guard sample.app.bundleID == nil, sample.windowTitle != nil else { return sample }
        var appOnly = sample
        appOnly.windowTitle = nil
        return appOnly
    }

    /// The event to store for the activity `sample` started, lasting until
    /// `end`, or why it must be dropped. Applies ``filter(_:)`` again, so an
    /// unfiltered sample cannot slip through.
    /// - Parameters:
    ///   - url: the browser URL for the span, as reported (unredacted);
    ///     given a URL, the event is a `.web` event, otherwise `.app`.
    ///   - source: the capture source, for example `workspace`.
    public func evaluate(
        _ sample: ActivitySample, until end: Date, url: String? = nil, source: String, sessionID: Int64? = nil
    ) -> PrivacyDecision {
        guard let sample = filter(sample) else { return .drop(.excludedApp) }
        var redactedURL: String?
        if let url {
            switch RedactableURL.parse(url) {
            case let .failure(reason):
                return .drop(reason)
            case let .success(parsed):
                if let host = parsed.host, blocklist.excludes(host: host) { return .drop(.excludedSite) }
                redactedURL = parsed.redacted(urlRedaction)
            }
        }
        return .keep(FilteredEvent(
            kind: redactedURL == nil ? .app : .web,
            appBundleID: sample.app.bundleID,
            windowTitle: sample.windowTitle,
            url: redactedURL,
            span: (sample.timestamp, end),
            source: source,
            sessionID: sessionID
        ))
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
        return "ActivitySample(trigger: \(trigger.rawValue), app: \(app), "
            + "title: \(ActivityRedaction.redacted(windowTitle)), at: \(timestamp.timeIntervalSince1970))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}
