import Foundation
import Testing
import UnrealityCore

/// Builds events for storage tests. Storage takes only `FilteredEvent`s,
/// which only the privacy rules create; an empty blocklist keeps everything.
enum TestEvents {
    static let rules = PrivacyRules(blocklist: .empty)

    static func sample(_ bundleID: String? = "com.example.editor", title: String? = nil,
                       at timestamp: Date) -> ActivitySample {
        ActivitySample(timestamp: timestamp, trigger: .appActivated,
                       app: FrontmostApp(bundleID: bundleID, name: nil, processID: 1), windowTitle: title)
    }

    static func event(
        _ kind: ActivityEventKind, title: String? = "notes.txt", url: String = "https://example.com/",
        from start: Date, to end: Date, sessionID: Int64? = nil
    ) throws -> FilteredEvent {
        switch kind {
        case .idle:
            return rules.idleEvent(from: start, until: end, source: "test", sessionID: sessionID)
        case .app, .web:
            return try #require(rules.event(
                from: sample(title: title, at: start), until: end, url: kind == .web ? url : nil,
                source: "test", sessionID: sessionID
            ))
        }
    }
}
