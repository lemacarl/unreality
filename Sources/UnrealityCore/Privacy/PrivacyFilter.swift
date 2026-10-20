import Foundation

/// Activity as reported by a capture source, before privacy filtering.
///
/// Nothing stores a sample: pass it through ``PrivacyFilter`` to get a
/// ``FilteredEvent``, the only type ``ActivityRepository/insert(_:)``
/// accepts. Its textual representations redact the window title and URL.
public struct ActivitySample: Sendable, Equatable {
    public var kind: ActivityEventKind
    public var appBundleID: String?
    public var windowTitle: String?
    /// The browser's URL as reported, unredacted.
    public var url: String?
    public var startedAt: Date
    public var endedAt: Date
    public var source: String
    public var sessionID: Int64?

    public init(
        kind: ActivityEventKind,
        appBundleID: String? = nil,
        windowTitle: String? = nil,
        url: String? = nil,
        startedAt: Date,
        endedAt: Date,
        source: String,
        sessionID: Int64? = nil
    ) {
        self.kind = kind
        self.appBundleID = appBundleID
        self.windowTitle = windowTitle
        self.url = url
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.source = source
        self.sessionID = sessionID
    }
}

/// An event that passed the privacy filter: not from an excluded app or
/// site, with its URL redacted. Only ``PrivacyFilter`` can create one (the
/// initialiser is private to this file), and it is deliberately not
/// `Decodable`, so storage cannot be handed unfiltered data.
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

    fileprivate init(_ sample: ActivitySample, url: String?) {
        kind = sample.kind
        let isIdle = sample.kind == .idle
        appBundleID = isIdle ? nil : sample.appBundleID
        windowTitle = isIdle ? nil : sample.windowTitle
        self.url = isIdle ? nil : url
        startedAt = sample.startedAt
        endedAt = sample.endedAt
        source = sample.source
        sessionID = sample.sessionID
    }
}

/// Why the privacy filter dropped a sample. Carries no captured data.
public enum PrivacyDropReason: Sendable, Equatable, CaseIterable {
    /// The frontmost app is on the blocklist.
    case excludedApp
    /// The URL's host is on the blocklist.
    case excludedSite
    /// A URL was present but could not be parsed, or a web sample had no
    /// URL, so the site could not be checked (fails closed).
    case uncheckableURL
}

/// Outcome of ``PrivacyFilter/evaluate(_:)``.
public enum PrivacyDecision: Sendable, Equatable {
    case keep(FilteredEvent)
    case drop(PrivacyDropReason)
}

/// Pure function layer between capture and storage: drops activity in
/// excluded apps and sites and redacts URLs. See docs/PRIVACY.md.
public struct PrivacyFilter: Sendable, Equatable {
    public let blocklist: Blocklist
    public let urlRedaction: URLRedaction

    /// - Parameters:
    ///   - blocklist: defaults to ``Blocklist/defaults``; add user entries
    ///     with `Blocklist.defaults.union(userEntries)`.
    ///   - urlRedaction: defaults to ``URLRedaction/keepPath``.
    public init(blocklist: Blocklist = .defaults, urlRedaction: URLRedaction = .keepPath) {
        self.blocklist = blocklist
        self.urlRedaction = urlRedaction
    }

    /// The event to store, or `nil` when the sample must be dropped.
    public func filter(_ sample: ActivitySample) -> FilteredEvent? {
        if case let .keep(event) = evaluate(sample) { return event }
        return nil
    }

    /// Filters a batch, keeping order and dropping excluded samples.
    public func filter(_ samples: some Sequence<ActivitySample>) -> [FilteredEvent] {
        samples.compactMap(filter)
    }

    /// Decides whether `sample` may be stored, and how.
    public func evaluate(_ sample: ActivitySample) -> PrivacyDecision {
        if sample.kind == .idle {
            return .keep(FilteredEvent(sample, url: nil))
        }
        if let bundleID = sample.appBundleID, blocklist.excludes(bundleID: bundleID) {
            return .drop(.excludedApp)
        }
        guard let raw = sample.url else {
            return sample.kind == .web ? .drop(.uncheckableURL) : .keep(FilteredEvent(sample, url: nil))
        }
        guard let url = RedactableURL(raw) else { return .drop(.uncheckableURL) }
        if let host = url.host, blocklist.excludes(host: host) {
            return .drop(.excludedSite)
        }
        return .keep(FilteredEvent(sample, url: url.redacted(urlRedaction)))
    }
}

// MARK: - Redacting descriptions

/// Window titles and URLs never appear in `print`, string interpolation,
/// `dump` or debugger summaries of activity types, so passing one to a
/// logger by mistake does not leak them.
enum ActivityRedaction {
    static func describe(
        _ type: String, id: Int64? = nil, kind: ActivityEventKind, appBundleID: String?,
        windowTitle: String?, url: String?, startedAt: Date, endedAt: Date, source: String
    ) -> String {
        var fields: [String] = []
        if let id { fields.append("id: \(id)") }
        fields.append("kind: \(kind.rawValue)")
        fields.append("app: \(appBundleID ?? "nil")")
        fields.append("title: \(windowTitle == nil ? "nil" : "<redacted>")")
        fields.append("url: \(url == nil ? "nil" : "<redacted>")")
        fields.append("from: \(startedAt.timeIntervalSince1970)")
        fields.append("to: \(endedAt.timeIntervalSince1970)")
        fields.append("source: \(source)")
        return "\(type)(\(fields.joined(separator: ", ")))"
    }
}

extension ActivitySample: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        ActivityRedaction.describe(
            "ActivitySample", kind: kind, appBundleID: appBundleID, windowTitle: windowTitle,
            url: url, startedAt: startedAt, endedAt: endedAt, source: source
        )
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

extension FilteredEvent: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        ActivityRedaction.describe(
            "FilteredEvent", kind: kind, appBundleID: appBundleID, windowTitle: windowTitle,
            url: url, startedAt: startedAt, endedAt: endedAt, source: source
        )
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

extension ActivityEvent: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        ActivityRedaction.describe(
            "ActivityEvent", id: id, kind: kind, appBundleID: appBundleID, windowTitle: windowTitle,
            url: url, startedAt: startedAt, endedAt: endedAt, source: source
        )
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}
