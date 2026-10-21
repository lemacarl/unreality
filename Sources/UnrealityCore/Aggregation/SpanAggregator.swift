import Foundation

/// Turns a stream of filtered samples, anonymous boundaries and idle
/// transitions into non-overlapping spans and sessions (#21).
///
/// Pure and deterministic: no clock, no I/O, no privacy rules. The same
/// inputs (and calendar) always give the same outputs. Feed it the samples
/// that left `ActivityCoordinator` (already filtered); ``ActivityPipeline``
/// turns its spans into `FilteredEvent`s through the live `PrivacyFilter`.
///
/// Rules:
/// - A span lasts from its sample until the next input that changes what
///   is in use. A sample whose stored content (bundle ID, window title, and
///   any field added to `ActivitySample` later) equals the open span's
///   continues it, whatever its trigger, so a repeated `.snapshot` for the
///   same app (for example after a trust-grant restart, #67) adds nothing.
///   The process ID and display name are not stored and do not split spans.
/// - A boundary ends the open span (activity or idle) and the session, and
///   forgets the frontmost app: nothing is attributed until the next sample.
/// - `idleStarted` ends the open activity span and the session and opens an
///   idle span. `idleEnded` ends it and, if an app was frontmost when idle
///   began, resumes that app in a new session. A sample while idle ends the
///   idle span (the user is evidently back).
/// - Spans are split at local midnight (per `calendar`), so every emitted
///   span lies within one calendar day. Sessions are not split.
/// - Zero-length spans are never emitted. An input timestamped earlier than
///   the previous one is treated as happening at the previous one, so
///   output never goes backwards or overlaps.
/// - Activity spans are emitted inside a session (`sessionStarted` before,
///   `sessionEnded` after); idle spans are emitted outside any session. A
///   session is emitted only once its first non-empty span completes, so
///   there are no empty sessions.
public struct SpanAggregator: Sendable {
    public enum Input: Sendable, Equatable {
        case sample(ActivitySample)
        case boundary(ActivityBoundary)
        case idleStarted(Date)
        case idleEnded(Date)
    }

    public enum Output: Sendable, Equatable {
        case sessionStarted(Date)
        /// `sample` (with `timestamp` set to the span's start) was in use
        /// until `end`.
        case activity(ActivitySample, until: Date)
        case idle(DateInterval)
        case sessionEnded(Date)
    }

    private enum OpenSpan: Sendable {
        case activity(ActivitySample)
        case idle(since: Date)
    }

    private let calendar: Calendar
    private var open: OpenSpan?
    /// The app frontmost when idle began, resumed when idle ends.
    private var frontmost: ActivitySample?
    /// Start of the current session, if one is open.
    private var sessionStart: Date?
    /// Whether `sessionStarted` was emitted for the current session.
    private var sessionEmitted = false
    private var lastTime: Date?

    public init(calendar: Calendar) {
        self.calendar = calendar
    }

    /// Aggregates `inputs` from a fresh state and, if `end` is given, ends
    /// whatever is still open at `end` (as a boundary would).
    public static func aggregate(_ inputs: [Input], calendar: Calendar, endingAt end: Date? = nil) -> [Output] {
        var aggregator = SpanAggregator(calendar: calendar)
        var outputs = inputs.flatMap { aggregator.consume($0) }
        if let end { outputs += aggregator.consume(.boundary(ActivityBoundary(timestamp: end))) }
        return outputs
    }

    /// Whether a span or session is open (output still pending).
    public var isOpen: Bool { open != nil || sessionStart != nil }

    /// Applies `input` and returns what it completed, in order.
    public mutating func consume(_ input: Input) -> [Output] {
        var outputs: [Output] = []
        switch input {
        case let .sample(sample):
            var sample = sample
            sample.timestamp = advance(to: sample.timestamp)
            receive(sample, into: &outputs)
        case let .boundary(boundary):
            let time = advance(to: boundary.timestamp)
            closeOpenSpan(at: time, into: &outputs)
            endSession(at: time, into: &outputs)
            frontmost = nil
        case let .idleStarted(date):
            let time = advance(to: date)
            if case .idle = open { break }
            closeOpenSpan(at: time, into: &outputs)
            endSession(at: time, into: &outputs)
            open = .idle(since: time)
        case let .idleEnded(date):
            let time = advance(to: date)
            guard case .idle = open else { break }
            closeOpenSpan(at: time, into: &outputs)
            if var resumed = frontmost {
                resumed.timestamp = time
                startActivity(resumed, into: &outputs)
            }
        }
        return outputs
    }

    private mutating func receive(_ sample: ActivitySample, into outputs: inout [Output]) {
        if case let .activity(current) = open, Self.sameContent(current, sample) {
            frontmost = current
            return
        }
        closeOpenSpan(at: sample.timestamp, into: &outputs)
        startActivity(sample, into: &outputs)
    }

    private mutating func startActivity(_ sample: ActivitySample, into outputs: inout [Output]) {
        if sessionStart == nil {
            sessionStart = sample.timestamp
            sessionEmitted = false
        }
        open = .activity(sample)
        frontmost = sample
    }

    private mutating func closeOpenSpan(at end: Date, into outputs: inout [Output]) {
        switch open {
        case let .activity(sample):
            let pieces = splitAtMidnight(from: sample.timestamp, to: end)
            if let start = sessionStart, !sessionEmitted, !pieces.isEmpty {
                sessionEmitted = true
                outputs.append(.sessionStarted(start))
            }
            for piece in pieces {
                var part = sample
                part.timestamp = piece.start
                outputs.append(.activity(part, until: piece.end))
            }
        case let .idle(since):
            outputs += splitAtMidnight(from: since, to: end).map { .idle($0) }
        case nil:
            break
        }
        open = nil
    }

    private mutating func endSession(at time: Date, into outputs: inout [Output]) {
        guard sessionStart != nil else { return }
        if sessionEmitted { outputs.append(.sessionEnded(time)) }
        sessionStart = nil
        sessionEmitted = false
    }

    /// Clamps `date` so time never goes backwards.
    private mutating func advance(to date: Date) -> Date {
        let time = max(date, lastTime ?? date)
        lastTime = time
        return time
    }

    /// `start..<end` cut at each local midnight; empty pieces are dropped.
    private func splitAtMidnight(from start: Date, to end: Date) -> [DateInterval] {
        guard end > start else { return [] }
        var pieces: [DateInterval] = []
        var pieceStart = start
        while let midnight = nextMidnight(after: pieceStart), midnight < end {
            pieces.append(DateInterval(start: pieceStart, end: midnight))
            pieceStart = midnight
        }
        pieces.append(DateInterval(start: pieceStart, end: end))
        return pieces
    }

    private func nextMidnight(after date: Date) -> Date? {
        let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
        guard let next, next > date else { return nil }
        return next
    }

    /// Whether `lhs` and `rhs` would store the same event: everything but
    /// the time, the trigger and the fields that are never stored.
    static func sameContent(_ lhs: ActivitySample, _ rhs: ActivitySample) -> Bool {
        normalised(lhs) == normalised(rhs)
    }

    private static func normalised(_ sample: ActivitySample) -> ActivitySample {
        var sample = sample
        sample.timestamp = .distantPast
        sample.trigger = .snapshot
        sample.app.processID = 0
        sample.app.name = nil
        return sample
    }
}
