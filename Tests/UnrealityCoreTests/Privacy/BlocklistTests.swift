import Foundation
import Testing
import UnrealityCore

@Suite("Blocklist")
struct BlocklistTests {
    @Test("bundle IDs match exactly and case-insensitively")
    func exactBundleIDs() {
        let list = Blocklist(bundleIDPatterns: ["com.Example.Vault"])
        #expect(list.excludes(bundleID: "com.example.vault"))
        #expect(list.excludes(bundleID: "COM.EXAMPLE.VAULT"))
        #expect(!list.excludes(bundleID: "com.example.vault2"))
        #expect(!list.excludes(bundleID: "com.example"))
    }

    @Test("a .* pattern matches the prefix and identifiers under it only")
    func prefixBundleIDs() {
        let list = Blocklist(bundleIDPatterns: ["com.example.*"])
        #expect(list.excludes(bundleID: "com.example"))
        #expect(list.excludes(bundleID: "com.example.app"))
        #expect(list.excludes(bundleID: "com.example.app.helper"))
        #expect(!list.excludes(bundleID: "com.examples.app"))
        #expect(!list.excludes(bundleID: "org.example.app"))
    }

    @Test("domains match the host and its subdomains only")
    func domains() {
        let list = Blocklist(domains: ["example.com"])
        #expect(list.excludes(host: "example.com"))
        #expect(list.excludes(host: "www.example.com"))
        #expect(list.excludes(host: "a.b.EXAMPLE.com."))
        #expect(!list.excludes(host: "notexample.com"))
        #expect(!list.excludes(host: "example.com.evil.test"))
        #expect(!list.excludes(host: ""))
    }

    @Test("domain entries are normalised", arguments: [
        "Example.com", " example.com ", "*.example.com", ".example.com", "example.com.",
        "https://example.com/login?x=1", "example.com:8443", "user@example.com"
    ])
    func domainNormalisation(_ entry: String) {
        #expect(Blocklist(domains: [entry]).domains == ["example.com"])
    }

    @Test("empty, whitespace and invalid entries are ignored")
    func emptyEntries() {
        let list = Blocklist(bundleIDPatterns: ["", "  ", ".*", "*", "com.*.app", "*.example", "com.ex*.*"],
                             domains: ["", " ", "*.", "https://", "exa mple.com", "[::1"])
        #expect(list == .empty)
        #expect(!list.excludes(bundleID: ""))
        #expect(!list.excludes(bundleID: "*"))
        #expect(!list.excludes(bundleID: "com.example.app"))
    }

    @Test("IPv6 entries keep the whole address", arguments: ["[::1]", "::1", "[::1]:8080", "http://[::1]:80/x"])
    func ipv6Entries(_ entry: String) {
        let list = Blocklist(domains: [entry])
        #expect(list.domains == ["[::1]"])
        #expect(list.excludes(host: "[::1]"))
        #expect(list.excludes(host: "::1"))
        #expect(!list.excludes(host: "[::2]"))
    }

    @Test("IDN entries and hosts compare in punycode form")
    func idn() {
        #expect(Blocklist(domains: ["bücher.de"]).domains == ["xn--bcher-kva.de"])
        #expect(Blocklist(domains: ["XN--BCHER-KVA.DE"]).domains == ["xn--bcher-kva.de"])
        let list = Blocklist(domains: ["xn--bcher-kva.de"])
        #expect(list.excludes(host: "bücher.de"))
        #expect(list.excludes(host: "www.BÜCHER.de"))
        #expect(list.excludes(host: "xn--bcher-kva.de"))
        #expect(!list.excludes(host: "bucher.de"))
    }

    @Test("union adds user entries to the defaults")
    func union() {
        let user = Blocklist(bundleIDPatterns: ["com.example.bank"], domains: ["bank.example"])
        let merged = Blocklist.defaults.union(user)
        #expect(merged.excludes(bundleID: "com.example.bank"))
        #expect(merged.excludes(host: "online.bank.example"))
        #expect(merged.excludes(bundleID: "com.1password.1password"))
        #expect(merged.excludes(host: "web.whatsapp.com"))
        #expect(!Blocklist.defaults.excludes(bundleID: "com.example.bank"))
    }

    @Test("defaults cover password managers, messaging and banking")
    func defaults() {
        let list = Blocklist.defaults
        for id in ["com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
                   "com.apple.keychainaccess", "com.apple.Passwords", "com.apple.MobileSMS",
                   "net.whatsapp.WhatsApp", "org.whispersystems.signal-desktop"] {
            #expect(list.excludes(bundleID: id), "\(id)")
        }
        for host in ["my.1password.com", "vault.bitwarden.com", "www.paypal.com", "secure.chase.com",
                     "web.telegram.org", "www.messenger.com"] {
            #expect(list.excludes(host: host), "\(host)")
        }
        for id in ["com.apple.Safari", "com.apple.dt.Xcode", "com.example.editor"] {
            #expect(!list.excludes(bundleID: id), "\(id)")
        }
        #expect(!list.excludes(host: "example.com"))
    }

    @Test("every default entry is listed in its category")
    func defaultsMatchCategories() {
        let expected = Blocklist(
            bundleIDPatterns: DefaultExclusions.passwordManagerApps + DefaultExclusions.messagingApps
                + DefaultExclusions.mailApps,
            domains: DefaultExclusions.passwordManagerSites + DefaultExclusions.messagingSites
                + DefaultExclusions.bankingSites
        )
        #expect(Blocklist.defaults == expected)
        #expect(!DefaultExclusions.bankingSites.isEmpty)
        // Every default entry is valid (none silently ignored).
        let all = DefaultExclusions.allBundleIDPatterns
        #expect(Blocklist.defaults.bundleIDs.count + Blocklist.defaults.bundleIDPrefixes.count == Set(all).count)
        #expect(Blocklist.defaults.domains.count == Set(DefaultExclusions.allDomains).count)
    }

    @Test("docs/PRIVACY.md lists exactly the default exclusions")
    func defaultsMatchPrivacyDoc() throws {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let doc = try String(contentsOf: root.appending(path: "docs/PRIVACY.md"), encoding: .utf8)
        let start = try #require(doc.range(of: "### Default exclusions\n"))
        let section = doc[start.upperBound...]
        let end = section.range(of: "\n#")?.lowerBound ?? section.endIndex
        let rows = section[..<end].split(separator: "\n").filter { $0.hasPrefix("|") && !$0.hasPrefix("|---") }
        var listed: [String] = []
        for row in rows.dropFirst() { // header row
            listed += row.matches(of: /`([^`]+)`/).map { String($0.output.1) }
        }
        let expected = DefaultExclusions.allBundleIDPatterns + DefaultExclusions.allDomains
        #expect(Set(listed) == Set(expected))
        #expect(listed.count == expected.count, "no entry listed twice")
    }

    @Test("mail apps are excluded by default")
    func mailDefaults() {
        #expect(Blocklist.defaults.excludes(bundleID: "com.apple.mail"))
        #expect(Blocklist.defaults.excludes(bundleID: "com.microsoft.Outlook"))
    }
}
