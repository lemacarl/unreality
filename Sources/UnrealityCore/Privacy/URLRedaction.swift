import Foundation

/// How much of an `http(s)` URL the privacy filter keeps. Every mode drops
/// the query, the fragment, user credentials (`user:password@`) and `;`
/// path parameters (such as `;jsessionid=...`); the host is stored in
/// canonical form (lowercase, punycode).
public enum URLRedaction: Sendable, Equatable {
    /// `scheme://host[:port]/path` (the default). Paths can still contain
    /// secrets (reset tokens, invite codes); see docs/PRIVACY.md.
    case keepPath
    /// `scheme://host[:port]/`, for users who consider paths sensitive.
    case hostOnly
}

/// A browser URL reduced to what may be checked and stored. Built only by
/// the privacy rules.
struct RedactableURL: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Schemes whose remainder is another URL (`blob:https://bank.example/<uuid>`):
    /// the inner URL's site is checked.
    static let wrappingSchemes: Set<String> = ["blob", "view-source", "filesystem"]
    /// Browser-extension pages (for example a password manager's vault in a
    /// tab). Their host is an extension ID, not a site, so they are dropped.
    static let extensionSchemes: Set<String> = [
        "chrome-extension", "safari-web-extension", "safari-extension", "moz-extension",
        "extension", "edge-extension", "opera-extension", "ms-browser-extension"
    ]
    /// Schemes without a host that are kept (as `scheme:` only). Any other
    /// non-`http(s)` URL without a host cannot be checked and is dropped.
    static let hostlessSchemes: Set<String> = ["about", "data"]

    /// Lowercased scheme of the outermost URL, for example `https` or `blob`.
    let scheme: String
    /// Canonical host to check against the blocklist (the inner URL's for a
    /// wrapping scheme); `nil` only for an allowed host-less scheme.
    let host: String?
    private let stored: (URLRedaction) -> String

    /// Parses `raw`, or says why the URL must be dropped:
    /// `.excludedExtensionPage` for extension pages, `.uncheckableURL` when
    /// it cannot be parsed, has no scheme, or has no host to check (other
    /// than an allowed host-less scheme).
    static func parse(_ raw: String) -> Result<RedactableURL, PrivacyDropReason> {
        parse(raw.trimmingCharacters(in: .whitespacesAndNewlines), depth: 0)
    }

    private static func parse(_ raw: String, depth: Int) -> Result<RedactableURL, PrivacyDropReason> {
        guard let colon = raw.firstIndex(of: ":") else { return .failure(.uncheckableURL) }
        let scheme = raw[..<colon].lowercased()
        if wrappingSchemes.contains(scheme) {
            guard depth < 2 else { return .failure(.uncheckableURL) }
            return parse(String(raw[raw.index(after: colon)...]), depth: depth + 1).map { inner in
                let innerMode: URLRedaction? = scheme == "view-source" ? nil : .hostOnly
                return RedactableURL(scheme: scheme, host: inner.host) { mode in
                    scheme + ":" + inner.redacted(innerMode ?? mode)
                }
            }
        }
        if extensionSchemes.contains(scheme) { return .failure(.excludedExtensionPage) }
        guard let components = URLComponents(string: raw), components.scheme?.lowercased() == scheme,
              !scheme.isEmpty
        else { return .failure(.uncheckableURL) }
        let rawHost = components.encodedHost ?? ""
        let host = Blocklist.canonicalHost(rawHost)
        // A host that is present but not valid (bad escapes, forbidden code
        // points) cannot be checked.
        if host == nil, !rawHost.isEmpty { return .failure(.uncheckableURL) }
        guard let host else {
            return hostlessSchemes.contains(scheme)
                ? .success(RedactableURL(scheme: scheme, host: nil) { _ in scheme + ":" })
                : .failure(.uncheckableURL)
        }
        guard scheme == "http" || scheme == "https" else {
            // A site, but the URL's other parts are not http paths: keep the scheme only.
            return .success(RedactableURL(scheme: scheme, host: host) { _ in scheme + ":" })
        }
        return .success(RedactableURL(scheme: scheme, host: host) { mode in
            webURL(components, scheme: scheme, host: host, mode: mode)
        })
    }

    private init(scheme: String, host: String?, stored: @escaping (URLRedaction) -> String) {
        self.scheme = scheme
        self.host = host
        self.stored = stored
    }

    /// The URL to store.
    func redacted(_ mode: URLRedaction) -> String { stored(mode) }

    private static func webURL(_ components: URLComponents, scheme: String, host: String,
                               mode: URLRedaction) -> String {
        var kept = URLComponents()
        kept.scheme = scheme
        kept.encodedHost = host
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

    // Never print the URL or its host.
    var description: String { "RedactableURL(scheme: \(scheme), host: \(host == nil ? "nil" : "<redacted>"))" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}
