import Foundation

/// How much of a URL the privacy filter keeps. Every mode drops the query,
/// the fragment, user credentials (`user:password@`) and `;` path
/// parameters (such as `;jsessionid=...`); the host is lowercased.
public enum URLRedaction: Sendable, Equatable {
    /// `scheme://host[:port]/path` (the default).
    case keepPath
    /// `scheme://host[:port]/`, for users who consider paths sensitive.
    case hostOnly
}

/// A browser URL reduced to what may be checked and stored. Built only by
/// the privacy filter.
struct RedactableURL {
    /// Lowercased scheme, for example `https`.
    let scheme: String
    /// Decoded, lowercased host for blocklist matching; `nil` for schemes
    /// without one (`about:`, `data:`).
    let host: String?
    private let components: URLComponents

    /// `nil` when `raw` cannot be parsed, has no scheme, or is an `http(s)`
    /// URL without a host: the filter then cannot check it and drops the event.
    init?(_ raw: String) {
        guard let components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), !scheme.isEmpty
        else { return nil }
        let host = components.host?.lowercased()
        let isWeb = scheme == "http" || scheme == "https"
        if isWeb, host?.isEmpty ?? true { return nil }
        self.scheme = scheme
        self.host = (host?.isEmpty ?? true) ? nil : host
        self.components = components
    }

    /// The URL to store. `http(s)` keeps scheme, host, port and (for
    /// ``URLRedaction/keepPath``) the path; any other scheme keeps only
    /// `scheme:`, since such URLs (`file:`, `data:`, extension pages) carry
    /// local paths or content rather than a site.
    func redacted(_ mode: URLRedaction) -> String {
        guard scheme == "http" || scheme == "https" else { return scheme + ":" }
        var kept = URLComponents()
        kept.scheme = scheme
        kept.percentEncodedHost = components.percentEncodedHost?.lowercased()
        kept.port = components.port
        switch mode {
        case .keepPath:
            let segments = components.percentEncodedPath
                .split(separator: "/", omittingEmptySubsequences: false)
                .map { $0.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? "" }
            let path = segments.joined(separator: "/")
            kept.percentEncodedPath = path.isEmpty ? "/" : path
        case .hostOnly:
            kept.percentEncodedPath = "/"
        }
        return kept.string ?? (scheme + ":")
    }
}
