import Foundation

/// Apps and sites whose activity must never be stored.
///
/// - **Bundle ID patterns** match a frontmost app's bundle identifier
///   case-insensitively: exactly, or, when the pattern ends in `.*`, the
///   prefix itself and every identifier under it (`com.example.*` matches
///   `com.example` and `com.example.app`, not `com.examples`). Any other `*`
///   (including a bare `*`) makes the pattern invalid, and it is ignored.
/// - **Domains** match a URL's host and every subdomain of it (`example.com`
///   matches `example.com` and `www.example.com`, not `notexample.com`).
///   A leading `*.` or `.`, a scheme, user info, a port and a path are
///   ignored, so `https://www.example.com/login` is the entry
///   `www.example.com`. Entries and hosts are compared in one canonical
///   form: percent escapes decoded, lowercase ASCII (internationalised
///   names as punycode, so `bücher.de` and `xn--bcher-kva.de` are the same
///   entry) without a trailing dot, and IPv6 addresses in brackets
///   (`[::1]`). An entry with a `*` other than a leading `*.`, or with a
///   single label (`com`, `localhost`, also from `*.com`), is invalid.
///   IP-literal entries are not normalised further (`[0:0:0:0:0:0:0:1]`
///   does not match `[::1]`).
///
/// Empty or invalid entries are ignored. The defaults (``defaults``, listed
/// in docs/PRIVACY.md) are extended with the user's own entries via
/// ``union(_:)``; the settings UI that collects them comes later (M6).
public struct Blocklist: Sendable, Equatable {
    /// Exact bundle identifiers, lowercased.
    public let bundleIDs: Set<String>
    /// Bundle identifier prefixes from `.*` patterns, lowercased, without the `.*`.
    public let bundleIDPrefixes: Set<String>
    /// Domains in canonical form (see the type's documentation).
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
                if !prefix.isEmpty, !prefix.contains("*") { prefixes.insert(prefix) }
            } else if !normalised.isEmpty, !normalised.contains("*") {
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

    /// Whether activity on `host` must be dropped. `host` is a URL's host
    /// without a port (Unicode, punycode or percent-encoded). A non-empty
    /// host that is not a valid host (for example one with a port) is
    /// treated as excluded: fail closed.
    public func excludes(host: String) -> Bool {
        if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        guard let host = Self.canonicalHost(host) else { return true }
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private init(bundleIDs: Set<String>, bundleIDPrefixes: Set<String>, domains: Set<String>) {
        self.bundleIDs = bundleIDs
        self.bundleIDPrefixes = bundleIDPrefixes
        self.domains = domains
    }

    /// Code points that can never appear in a decoded host (the WHATWG
    /// forbidden host code points, plus `*`); `:` is handled separately.
    private static let forbiddenHostCharacters = CharacterSet(charactersIn: "\u{0}#%/<>?@[\\]^|*")
        .union(.whitespacesAndNewlines)
        .union(.controlCharacters)
        .union(.illegalCharacters)

    private static let ipv6Characters = CharacterSet(charactersIn: "0123456789abcdefABCDEF:.")

    /// Lowercase ASCII (punycode) host without trailing dots, IPv6 in
    /// brackets; `nil` when `host` is empty or not a valid host.
    ///
    /// Percent escapes are decoded first (as browsers do: `ch%61se.com` is
    /// `chase.com`); a host whose escapes do not decode, or that decodes to
    /// a forbidden code point or a `:` (a port, say), is not valid. A
    /// bracketed IPv6 literal is not decoded, so zone IDs (`%25en0`) stay
    /// as they are.
    static func canonicalHost(_ host: String) -> String? {
        var host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("[") {
            guard host.hasSuffix("]") else { return nil }
        } else {
            guard let decoded = host.removingPercentEncoding,
                  decoded.unicodeScalars.allSatisfy({ !forbiddenHostCharacters.contains($0) })
            else { return nil }
            host = decoded
            if host.contains(":") {
                // A bare IPv6 address; anything else with a `:` (a port) is invalid.
                guard host.unicodeScalars.allSatisfy(ipv6Characters.contains) else { return nil }
                host = "[\(host)]"
            }
        }
        host = host.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, let encoded = URLComponents(string: "https://\(host)/")?.encodedHost,
              !encoded.isEmpty, !encoded.contains("%") || host.hasPrefix("[")
        else { return nil }
        return encoded.lowercased()
    }

    private static func normaliseDomain(_ entry: String) -> String? {
        var domain = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = domain.range(of: "://") { domain = String(domain[range.upperBound...]) }
        if let end = domain.firstIndex(where: { "/?#".contains($0) }) { domain = String(domain[..<end]) }
        if let atSign = domain.lastIndex(of: "@") { domain = String(domain[domain.index(after: atSign)...]) }
        if domain.hasPrefix("[") {
            // IPv6 literal, possibly followed by a port: keep through `]`.
            guard let close = domain.firstIndex(of: "]") else { return nil }
            domain = String(domain[...close])
        } else if domain.filter({ $0 == ":" }).count == 1, let colon = domain.firstIndex(of: ":") {
            domain = String(domain[..<colon]) // host:port
        }
        if domain.hasPrefix("*.") { domain.removeFirst(2) }
        while domain.hasPrefix(".") { domain.removeFirst() }
        // Any other `*` is invalid (`*`, `com.*`, `a.*.b`), and so is a
        // single label (`com`, `localhost`), which would exclude a whole
        // top-level domain; IPv6 literals are the exception.
        guard !domain.contains("*"), let canonical = canonicalHost(domain),
              canonical.hasPrefix("[") || canonical.contains(".")
        else { return nil }
        return canonical
    }
}

extension Blocklist {
    /// Built-in exclusions, applied unless the user removes them (M6).
    /// Keep in sync with docs/PRIVACY.md, "Default exclusions" (a test
    /// compares them).
    public static let defaults = Blocklist(
        bundleIDPatterns: DefaultExclusions.allBundleIDPatterns,
        domains: DefaultExclusions.allDomains
    )
}

/// The default exclusion lists by category. Best effort: bundle IDs change
/// between app versions, and banking is mostly done on the web, so banking
/// is covered by domains (some large banks and payment services); users add
/// their own bank's app and site.
public enum DefaultExclusions {
    public static let passwordManagerApps = [
        "com.1password.*", // 1Password 8
        "com.agilebits.*", // 1Password 7 and earlier
        "com.bitwarden.*",
        "com.lastpass.*",
        "org.keepassxc.*",
        "in.sinew.*", // Enpass
        "me.proton.pass.*", // Proton Pass
        "com.nordsec.nordpass.*", // NordPass (unverified)
        "com.keepersecurity.*", // Keeper (unverified)
        "com.dashlane.*",
        "com.markmcguill.strongbox.*", // Strongbox (unverified)
        "com.hicknhacksoftware.MacPass",
        "com.apple.keychainaccess",
        "com.apple.Passwords" // macOS 15 Passwords app
    ]

    public static let messagingApps = [
        "com.apple.MobileSMS", // Messages
        "com.apple.FaceTime",
        "net.whatsapp.*",
        "desktop.WhatsApp", // older Electron WhatsApp
        "org.whispersystems.*", // Signal, including beta builds
        "ru.keepcoder.Telegram", // Telegram for macOS
        "com.tdesktop.Telegram", // Telegram Desktop
        "com.facebook.archon.*", // Messenger
        "com.hnc.Discord",
        "com.hnc.DiscordPTB",
        "com.hnc.DiscordCanary",
        "im.riot.app", // Element
        "com.wearezeta.zclient.mac", // Wire
        "ch.threema.*", // Threema (unverified)
        "com.viber.osx",
        "com.tencent.xinWeChat", // WeChat
        "jp.naver.line.mac", // LINE
        "com.automattic.beeper.*", // Beeper (unverified)
        "com.beeper.*" // Beeper (unverified)
    ]

    /// Window titles of mail apps are email subjects and senders.
    public static let mailApps = [
        "com.apple.mail",
        "com.microsoft.Outlook"
    ]

    /// Webmail hosts (titles are subjects and senders, as in mail apps).
    /// iCloud Mail is a path (`icloud.com/mail`) and cannot be matched.
    public static let mailSites = [
        "mail.google.com",
        "outlook.live.com",
        "outlook.office.com",
        "outlook.office365.com",
        "mail.yahoo.com",
        "mail.proton.me",
        "app.fastmail.com"
    ]

    public static let passwordManagerSites = [
        "1password.com", "1password.eu", "1password.ca",
        "bitwarden.com", "bitwarden.eu",
        "lastpass.com",
        "dashlane.com",
        "keepersecurity.com",
        "nordpass.com",
        "pass.proton.me",
        "passwords.google.com"
    ]

    public static let messagingSites = [
        "web.whatsapp.com",
        "web.telegram.org",
        "messenger.com",
        "messages.google.com",
        "discord.com",
        "app.element.io"
    ]

    public static let bankingSites = [
        "paypal.com", "venmo.com", "cash.app", "wise.com", "revolut.com", "monzo.com", "n26.com",
        "coinbase.com", "dashboard.stripe.com",
        "chase.com", "bankofamerica.com", "wellsfargo.com", "citi.com", "citibank.com", "capitalone.com",
        "usbank.com", "americanexpress.com", "schwab.com", "fidelity.com",
        "hsbc.com", "hsbc.co.uk", "hsbc.com.hk", "barclays.co.uk", "lloydsbank.com", "natwest.com"
    ]

    public static var allBundleIDPatterns: [String] { passwordManagerApps + messagingApps + mailApps }
    public static var allDomains: [String] { passwordManagerSites + messagingSites + mailSites + bankingSites }
}
