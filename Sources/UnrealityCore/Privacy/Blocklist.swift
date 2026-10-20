import Foundation

/// Apps and sites whose activity must never be stored.
///
/// Entries are matched case-insensitively:
/// - **Bundle ID patterns** match a frontmost app's bundle identifier
///   exactly, or, when the pattern ends in `.*`, the prefix itself and every
///   identifier under it (`com.example.*` matches `com.example` and
///   `com.example.app`, not `com.examples`).
/// - **Domains** match a URL's host and every subdomain of it (`example.com`
///   matches `example.com` and `www.example.com`, not `notexample.com`).
///   A leading `*.` or `.`, a scheme, a port and a path are ignored, so
///   `https://www.example.com/login` is the entry `www.example.com`.
///
/// Empty entries are ignored. The defaults (``defaults``, listed in
/// docs/PRIVACY.md) are extended with the user's own entries via
/// ``union(_:)``; the settings UI that collects them comes later (M6).
public struct Blocklist: Sendable, Equatable {
    /// Exact bundle identifiers, lowercased.
    public let bundleIDs: Set<String>
    /// Bundle identifier prefixes from `.*` patterns, lowercased, without the `.*`.
    public let bundleIDPrefixes: Set<String>
    /// Domains, lowercased and normalised.
    public let domains: Set<String>

    /// An empty blocklist.
    public static let empty = Blocklist()

    public init(bundleIDPatterns: some Sequence<String> = [String](), domains: some Sequence<String> = [String]()) {
        var exact = Set<String>()
        var prefixes = Set<String>()
        for pattern in bundleIDPatterns {
            let normalised = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalised.hasSuffix(".*") {
                let prefix = String(normalised.dropLast(2))
                if !prefix.isEmpty { prefixes.insert(prefix) }
            } else if !normalised.isEmpty {
                exact.insert(normalised)
            }
        }
        bundleIDs = exact
        bundleIDPrefixes = prefixes
        self.domains = Set(domains.compactMap(Self.normaliseDomain))
    }

    /// Entries of both lists.
    public func union(_ other: Blocklist) -> Blocklist {
        Blocklist(
            bundleIDs: bundleIDs.union(other.bundleIDs),
            bundleIDPrefixes: bundleIDPrefixes.union(other.bundleIDPrefixes),
            domains: domains.union(other.domains)
        )
    }

    /// Whether activity in the app with `bundleID` must be dropped.
    public func excludes(bundleID: String) -> Bool {
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if bundleIDs.contains(id) { return true }
        return bundleIDPrefixes.contains { id == $0 || id.hasPrefix($0 + ".") }
    }

    /// Whether activity on `host` (a URL's host) must be dropped.
    public func excludes(host: String) -> Bool {
        guard let host = Self.normaliseHost(host) else { return false }
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private init(bundleIDs: Set<String>, bundleIDPrefixes: Set<String>, domains: Set<String>) {
        self.bundleIDs = bundleIDs
        self.bundleIDPrefixes = bundleIDPrefixes
        self.domains = domains
    }

    private static func normaliseHost(_ host: String) -> String? {
        var host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }

    private static func normaliseDomain(_ entry: String) -> String? {
        var domain = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = domain.range(of: "://") { domain = String(domain[range.upperBound...]) }
        if let end = domain.firstIndex(where: { "/?#".contains($0) }) { domain = String(domain[..<end]) }
        if let atSign = domain.lastIndex(of: "@") { domain = String(domain[domain.index(after: atSign)...]) }
        if let colon = domain.lastIndex(of: ":") { domain = String(domain[..<colon]) }
        if domain.hasPrefix("*.") { domain.removeFirst(2) }
        while domain.hasPrefix(".") { domain.removeFirst() }
        return normaliseHost(domain)
    }
}

extension Blocklist {
    /// Built-in exclusions, applied unless the user removes them (M6).
    /// Keep in sync with docs/PRIVACY.md, "Default exclusions".
    public static let defaults = Blocklist(
        bundleIDPatterns: DefaultExclusions.passwordManagerApps + DefaultExclusions.messagingApps,
        domains: DefaultExclusions.passwordManagerSites + DefaultExclusions.messagingSites
            + DefaultExclusions.bankingSites
    )
}

/// The default exclusion lists by category. Best effort: bundle IDs change
/// between app versions, and banking is mostly done on the web, so banking
/// is covered by domains (a few large banks and payment services); users add
/// their own bank's app and site.
public enum DefaultExclusions {
    public static let passwordManagerApps = [
        "com.1password.*", // 1Password 8
        "com.agilebits.*", // 1Password 7 and earlier
        "com.bitwarden.*",
        "com.lastpass.*",
        "org.keepassxc.*",
        "in.sinew.*", // Enpass
        "com.apple.keychainaccess",
        "com.apple.Passwords" // macOS 15 Passwords app
    ]

    public static let messagingApps = [
        "com.apple.MobileSMS", // Messages
        "com.apple.FaceTime",
        "net.whatsapp.*",
        "org.whispersystems.signal-desktop",
        "ru.keepcoder.Telegram", // Telegram for macOS
        "com.tdesktop.Telegram", // Telegram Desktop
        "com.facebook.archon.*", // Messenger
        "com.hnc.Discord"
    ]

    public static let passwordManagerSites = [
        "1password.com", "1password.eu", "1password.ca",
        "bitwarden.com", "bitwarden.eu",
        "lastpass.com",
        "passwords.google.com"
    ]

    public static let messagingSites = [
        "web.whatsapp.com",
        "web.telegram.org",
        "messenger.com",
        "messages.google.com",
        "discord.com"
    ]

    public static let bankingSites = [
        "paypal.com",
        "wise.com",
        "revolut.com",
        "chase.com",
        "bankofamerica.com",
        "wellsfargo.com",
        "citi.com",
        "capitalone.com",
        "hsbc.com",
        "barclays.co.uk"
    ]
}
