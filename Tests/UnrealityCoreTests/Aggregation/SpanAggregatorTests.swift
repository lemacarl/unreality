import Foundation
import Testing
import UnrealityCore

/// Fixture DSL: times are seconds after `AggregationFixture.day` (2026-03-02
/// 00:00 UTC) and outputs are rendered as short strings, so expectations
/// read like a timeline.
enum AggregationFixture {
    static let day = Date(timeIntervalSince1970: 1_772_409_600)

    static var utc: Calendar { calendar(.gmt) }

    static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    static func time(_ seconds: TimeInterval) -> Date { day + seconds }

    static func sample(
        _ bundleID: String?, _ title: String? = nil, at seconds: TimeInterval,
        trigger: ActivitySample.Trigger = .appActivated, pid: Int32 = 1, name: String? = nil
    ) -> SpanAggregator.Input {
        .sample(ActivitySample(
            timestamp: time(seconds), trigger: trigger,
            app: FrontmostApp(bundleID: bundleID, name: name, processID: pid), windowTitle: title
        ))
    }

    static func boundary(at seconds: TimeInterval) -> SpanAggregator.Input {
        .boundary(ActivityBoundary(timestamp: time(seconds)))
    }

    static func idleStarted(at seconds: TimeInterval) -> SpanAggregator.Input { .idleStarted(time(seconds)) }
    static func idleEnded(at seconds: TimeInterval) -> SpanAggregator.Input { .idleEnded(time(seconds)) }

    static func offset(_ date: Date) -> String {
        let seconds = date.timeIntervalSince(day)
        return seconds == seconds.rounded() ? String(Int(seconds)) : String(seconds)
    }

    /// `+s 0`, `app com.a "doc" 0-10`, `idle 10-20`, `-s 20`.
    static func render(_ output: SpanAggregator.Output) -> String {
        switch output {
        case let .sessionStarted(date):
            return "+s \(offset(date))"
        case let .sessionEnded(date):
            return "-s \(offset(date))"
        case let .idle(interval):
            return "idle \(offset(interval.start))-\(offset(interval.end))"
        case let .activity(sample, end):
            let title = sample.windowTitle.map { " \"\($0)\"" } ?? ""
            return "app \(sample.app.bundleID ?? "nil")\(title) \(offset(sample.timestamp))-\(offset(end))"
        }
    }

    static func run(
        _ inputs: [SpanAggregator.Input], endingAt end: TimeInterval? = nil, calendar: Calendar = utc
    ) -> [String] {
        SpanAggregator.aggregate(inputs, calendar: calendar, endingAt: end.map(time)).map(render)
    }

    /// Spans (activity and idle) in output order.
    static func spans(_ outputs: [SpanAggregator.Output]) -> [DateInterval] {
        outputs.compactMap { output in
            switch output {
            case let .activity(sample, end): DateInterval(start: sample.timestamp, end: end)
            case let .idle(interval): interval
            case .sessionStarted, .sessionEnded: nil
            }
        }
    }
}

@Suite("SpanAggregator")
struct SpanAggregatorTests {
    typealias Fixture = AggregationFixture

    @Test("rapid switching keeps every non-empty span, in order, without overlaps")
    func rapidSwitching() {
        let inputs = [
            Fixture.sample("com.a", at: 0), Fixture.sample("com.b", at: 0.25), Fixture.sample("com.c", at: 0.5),
            Fixture.sample("com.a", at: 0.75), Fixture.sample("com.b", at: 0.75), // same instant: A is empty
            Fixture.sample("com.a", at: 1), Fixture.sample("com.a", at: 1.5) // repeat: continues
        ]
        #expect(Fixture.run(inputs, endingAt: 2) == [
            "+s 0", "app com.a 0-0.25", "app com.b 0.25-0.5", "app com.c 0.5-0.75",
            "app com.b 0.75-1", "app com.a 1-2", "-s 2"
        ])
        let spans = Fixture.spans(SpanAggregator.aggregate(inputs, calendar: Fixture.utc, endingAt: Fixture.time(2)))
        #expect(spans.allSatisfy { $0.duration > 0 })
        #expect(zip(spans, spans.dropFirst()).allSatisfy { $0.end <= $1.start })
        #expect(spans.map(\.duration).reduce(0, +) == 2)
    }

    @Test("a title change splits the span; the same app and title continues it")
    func titleChanges() {
        let inputs = [
            Fixture.sample("com.a", "one", at: 0), Fixture.sample("com.a", "one", at: 5, trigger: .titleChanged),
            Fixture.sample("com.a", "two", at: 10, trigger: .titleChanged), Fixture.sample("com.a", nil, at: 15)
        ]
        #expect(Fixture.run(inputs, endingAt: 20) == [
            "+s 0", "app com.a \"one\" 0-10", "app com.a \"two\" 10-15", "app com.a 15-20", "-s 20"
        ])
    }

    @Test("a second snapshot for the same app (#67) is tolerated")
    func duplicateSnapshot() {
        // Restart with nothing changed: the span continues.
        #expect(Fixture.run([
            Fixture.sample("com.a", "doc", at: 0, trigger: .snapshot),
            Fixture.sample("com.a", "doc", at: 5, trigger: .snapshot)
        ], endingAt: 10) == ["+s 0", "app com.a \"doc\" 0-10", "-s 10"])
        // Restart after a trust grant: the title becomes known, like a title change.
        #expect(Fixture.run([
            Fixture.sample("com.a", nil, at: 0, trigger: .snapshot),
            Fixture.sample("com.a", "doc", at: 5, trigger: .snapshot)
        ], endingAt: 10) == ["+s 0", "app com.a 0-5", "app com.a \"doc\" 5-10", "-s 10"])
        // Process ID and display name are never stored, so they do not split.
        #expect(Fixture.run([
            Fixture.sample("com.a", "doc", at: 0, pid: 10, name: "A"),
            Fixture.sample("com.a", "doc", at: 5, trigger: .snapshot, pid: 11, name: "A (2)")
        ], endingAt: 10) == ["+s 0", "app com.a \"doc\" 0-10", "-s 10"])
    }

    @Test("idle placeholders: idle ends the session; the frontmost app resumes in a new one")
    func idle() {
        let inputs = [
            Fixture.sample("com.a", "doc", at: 0), Fixture.idleStarted(at: 60),
            Fixture.idleStarted(at: 90), // repeated: ignored
            Fixture.idleEnded(at: 360), Fixture.idleEnded(at: 370), // not idle: ignored
            Fixture.sample("com.b", at: 400)
        ]
        #expect(Fixture.run(inputs, endingAt: 460) == [
            "+s 0", "app com.a \"doc\" 0-60", "-s 60", "idle 60-360",
            "+s 360", "app com.a \"doc\" 360-400", "app com.b 400-460", "-s 460"
        ])
    }

    @Test("a sample while idle ends the idle span")
    func sampleWhileIdle() {
        #expect(Fixture.run([
            Fixture.sample("com.a", at: 0), Fixture.idleStarted(at: 10), Fixture.sample("com.b", at: 30),
            Fixture.idleEnded(at: 40) // already ended by the sample: ignored
        ], endingAt: 50) == [
            "+s 0", "app com.a 0-10", "-s 10", "idle 10-30", "+s 30", "app com.b 30-50", "-s 50"
        ])
        // Idle before any tracked activity is ignored: nothing is stored.
        #expect(Fixture.run([Fixture.idleStarted(at: 0), Fixture.idleEnded(at: 30)], endingAt: 40).isEmpty)
    }

    @Test("switching to an excluded app ends the span at the boundary; switching back starts a new one")
    func excludedApp() {
        #expect(Fixture.run([
            Fixture.sample("com.a", "doc", at: 0), Fixture.boundary(at: 10), // excluded app frontmost
            Fixture.boundary(at: 15), // another excluded sample
            Fixture.sample("com.a", "doc", at: 40) // back from the excluded app
        ], endingAt: 50) == [
            "+s 0", "app com.a \"doc\" 0-10", "-s 10", "+s 40", "app com.a \"doc\" 40-50", "-s 50"
        ])
        // Starting in an excluded app: nothing until the first allowed sample.
        #expect(Fixture.run([Fixture.boundary(at: 0), Fixture.sample("com.b", at: 20)], endingAt: 30) == [
            "+s 20", "app com.b 20-30", "-s 30"
        ])
    }

    @Test("idle after a boundary (excluded app, pause, stop) is ignored, and nothing is resumed")
    func idleAfterBoundary() {
        #expect(Fixture.run([
            Fixture.sample("com.a", at: 0), Fixture.boundary(at: 10),
            Fixture.idleStarted(at: 20), Fixture.idleEnded(at: 50)
        ], endingAt: 60) == ["+s 0", "app com.a 0-10", "-s 10"])
        // A boundary during idle (an excluded app activated, a pause) ends the idle span too.
        #expect(Fixture.run([
            Fixture.sample("com.a", at: 0), Fixture.idleStarted(at: 10), Fixture.boundary(at: 30),
            Fixture.idleEnded(at: 50)
        ], endingAt: 60) == ["+s 0", "app com.a 0-10", "-s 10", "idle 10-30"])
    }

    @Test("pause and resume: the paused time is attributed to nothing")
    func pauseResume() {
        #expect(Fixture.run([
            Fixture.sample("com.a", "doc", at: 0), Fixture.boundary(at: 10), // pause
            Fixture.sample("com.a", "doc", at: 40, trigger: .snapshot) // resume snapshot
        ], endingAt: 45) == [
            "+s 0", "app com.a \"doc\" 0-10", "-s 10", "+s 40", "app com.a \"doc\" 40-45", "-s 45"
        ])
    }

    @Test("spans and idle are split at local midnight; the session is not")
    func midnightRollover() {
        let lateEvening: TimeInterval = 86_400 - 600 // 23:50 on day one
        #expect(Fixture.run([
            Fixture.sample("com.a", at: lateEvening), Fixture.idleStarted(at: 86_400 + 600),
            Fixture.idleEnded(at: 86_400 * 3 + 60) // idle over two more midnights
        ], endingAt: 86_400 * 3 + 120) == [
            "+s 85800", "app com.a 85800-86400", "app com.a 86400-87000", "-s 87000",
            "idle 87000-172800", "idle 172800-259200", "idle 259200-259260",
            "+s 259260", "app com.a 259260-259320", "-s 259320"
        ])
        // A span ending exactly at midnight is not split.
        #expect(Fixture.run([Fixture.sample("com.a", at: lateEvening)], endingAt: 86_400) == [
            "+s 85800", "app com.a 85800-86400", "-s 86400"
        ])
    }

    /// A 48-hour span in `zone` from `start`, which must give exactly `spans` pieces.
    struct ZoneCase: Sendable, CustomTestStringConvertible {
        let zone: String
        let start: TimeInterval // seconds since 1970
        let hours: Double
        let spans: Int
        var testDescription: String { zone }
    }

    static let zoneCases = [
        // 2026-03-07 00:00 UTC for 72 h, over the US daylight-saving change (8 March).
        ZoneCase(zone: "America/New_York", start: 1_772_841_600, hours: 72, spans: 4),
        ZoneCase(zone: "Europe/Berlin", start: 1_772_841_600, hours: 72, spans: 4),
        ZoneCase(zone: "Asia/Kolkata", start: 1_772_841_600, hours: 72, spans: 4),
        ZoneCase(zone: "Pacific/Chatham", start: 1_772_841_600, hours: 72, spans: 4),
        ZoneCase(zone: "UTC", start: 1_772_841_600, hours: 72, spans: 3), // starts at midnight
        // Daylight saving starts at midnight (the day begins at 01:00): local noon the day before, for 48 h.
        ZoneCase(zone: "America/Santiago", start: 1_725_724_800, hours: 48, spans: 3), // 2024-09-08
        ZoneCase(zone: "America/Havana", start: 1_710_003_600, hours: 48, spans: 3), // 2024-03-10
        ZoneCase(zone: "Asia/Beirut", start: 1_774_692_000, hours: 48, spans: 3), // 2026-03-29
        ZoneCase(zone: "Africa/Cairo", start: 1_776_938_400, hours: 48, spans: 3) // 2026-04-24
    ]

    @Test("midnight follows the calendar's time zone, including daylight-saving days", arguments: zoneCases)
    func midnightInTimeZone(_ zoneCase: ZoneCase) throws {
        let calendar = Fixture.calendar(try #require(TimeZone(identifier: zoneCase.zone)))
        let start = Date(timeIntervalSince1970: zoneCase.start)
        let end = start.addingTimeInterval(zoneCase.hours * 3_600)
        let outputs = SpanAggregator.aggregate([
            .sample(ActivitySample(timestamp: start, trigger: .snapshot,
                                   app: FrontmostApp(bundleID: "com.a", name: nil, processID: 1), windowTitle: nil))
        ], calendar: calendar, endingAt: end)
        let spans = Fixture.spans(outputs)
        #expect(spans.count == zoneCase.spans)
        #expect(spans.first?.start == start)
        #expect(spans.last?.end == end)
        #expect(zip(spans, spans.dropFirst()).allSatisfy { $0.end == $1.start })
        for span in spans {
            #expect(calendar.isDate(span.start, inSameDayAs: span.end.addingTimeInterval(-0.001)))
            #expect(span.duration > 0)
        }
        #expect(spans.dropFirst().allSatisfy { calendar.startOfDay(for: $0.start) == $0.start })
    }

    @Test("an input earlier than the previous one is treated as happening at the previous one")
    func outOfOrder() {
        #expect(Fixture.run([
            Fixture.sample("com.a", at: 10), Fixture.sample("com.b", at: 5), Fixture.boundary(at: 2),
            Fixture.sample("com.c", at: 20)
        ], endingAt: 30) == ["+s 20", "app com.c 20-30", "-s 30"])
    }

    @Test("aggregation is deterministic and the same incrementally as in one batch")
    func deterministic() {
        let inputs = [
            Fixture.sample("com.a", "x", at: 0), Fixture.sample("com.b", at: 3), Fixture.boundary(at: 7),
            Fixture.sample("com.a", "x", at: 9, trigger: .snapshot), Fixture.idleStarted(at: 86_000),
            Fixture.idleEnded(at: 87_000), Fixture.sample("com.c", "y", at: 87_500)
        ]
        let end = Fixture.time(90_000)
        let first = SpanAggregator.aggregate(inputs, calendar: Fixture.utc, endingAt: end)
        #expect(first == SpanAggregator.aggregate(inputs, calendar: Fixture.utc, endingAt: end))
        var aggregator = SpanAggregator(calendar: Fixture.utc)
        var incremental: [SpanAggregator.Output] = []
        for input in inputs {
            incremental += aggregator.consume(input)
        }
        #expect(aggregator.isOpen)
        incremental += aggregator.consume(.boundary(ActivityBoundary(timestamp: end)))
        #expect(!aggregator.isOpen)
        #expect(incremental == first)
    }

    @Test("a boundary carries only a timestamp")
    func boundaryIsAnonymous() {
        let boundary = ActivityBoundary(timestamp: Fixture.day)
        #expect(Mirror(reflecting: boundary).children.map(\.label) == ["timestamp"])
    }
}
