import Foundation
import Observation

/// Seam for the privacy filter (#20). The coordinator asks it before any
/// window title is read and runs every sample through it before the sample
/// leaves the coordinator.
@MainActor
public protocol ActivitySampleFilter: AnyObject {
    /// Whether the focused window title of `app` may be read at all. Asked
    /// before the title is read, so excluded apps' titles are never read.
    func allowsWindowTitle(for app: FrontmostApp) -> Bool
    /// The sample to pass on (possibly redacted), or `nil` to drop it.
    func filter(_ sample: ActivitySample) -> ActivitySample?
}

/// Connects an `ActivitySource` to the rest of the app and enforces the
/// rules every sample must obey before anyone sees it:
///
/// - Paused means nothing is read or emitted: the source is stopped while
///   `CaptureStateStore` is paused and restarted (with a fresh snapshot) on
///   resume; a sample that still arrives while paused is dropped.
/// - Window titles need Accessibility permission. The trust state is
///   re-checked on every sample (event driven, no polling) and published as
///   `accessibilityTrust`; without it, samples are app-only (title `nil`)
///   and title-change samples are dropped. The coordinator never prompts.
/// - Titles are never read for a process without a bundle ID (no filter
///   could match it) or for Unreality's own process. Wherever a title is
///   withheld, so is the browser URL reading (#19).
/// - The filter decides which titles may be read and which samples pass
///   (for browsers: the site check and URL redaction, #19).
///   It is a required parameter with deliberately no pass-through default,
///   so nothing can wire the coordinator unfiltered.
@MainActor
@Observable
public final class ActivityCoordinator {
    /// Latest known Accessibility trust state; updated on `start`, on every
    /// sample and on `refreshAccessibilityTrust()`.
    public private(set) var accessibilityTrust: AccessibilityTrustState
    /// True between `start` and `stop` (also while paused).
    public private(set) var isActive = false

    @ObservationIgnored private let source: any ActivitySource
    @ObservationIgnored private let captureState: CaptureStateStore
    @ObservationIgnored private let trust: any AccessibilityTrust
    @ObservationIgnored private let filter: any ActivitySampleFilter
    @ObservationIgnored private var sink: (@MainActor (ActivitySample) -> Void)?
    @ObservationIgnored private var subscription: CaptureStateSubscription?

    private static let ownProcessID = ProcessInfo.processInfo.processIdentifier

    public init(
        source: any ActivitySource,
        captureState: CaptureStateStore,
        trust: any AccessibilityTrust,
        filter: any ActivitySampleFilter
    ) {
        self.source = source
        self.captureState = captureState
        self.trust = trust
        self.filter = filter
        accessibilityTrust = trust.currentState()
    }

    /// Starts delivering filtered samples to `sink` (on the main actor).
    /// Calling it again replaces the sink (and, while running, restarts the
    /// source with a fresh snapshot).
    public func start(_ sink: @escaping @MainActor (ActivitySample) -> Void) {
        self.sink = sink
        updateTrust()
        if !isActive {
            isActive = true
            subscription = captureState.onChange { [weak self] state in self?.captureStateChanged(to: state) }
        }
        if !captureState.isPaused { startSource() }
    }

    /// Stops the source; nothing is delivered afterwards.
    public func stop() {
        guard isActive else { return }
        isActive = false
        subscription?.cancel()
        subscription = nil
        sink = nil
        source.stop()
    }

    /// Re-reads the trust state, for example when the app becomes active
    /// after the user changed it in System Settings. Never prompts. If trust
    /// was just granted while active and running, the source is restarted
    /// (with a fresh snapshot) so titles of the app that is already
    /// frontmost start now rather than at the next app switch.
    public func refreshAccessibilityTrust() {
        let previous = accessibilityTrust
        updateTrust()
        if previous != .trusted, accessibilityTrust == .trusted, isActive, !captureState.isPaused {
            startSource()
        }
    }

    /// Updates the published state only; safe to call from source callbacks.
    private func updateTrust() {
        let state = trust.currentState()
        if state != accessibilityTrust { accessibilityTrust = state }
    }

    private func captureStateChanged(to state: CaptureState) {
        guard isActive else { return }
        switch state {
        case .paused: source.stop()
        case .running: startSource()
        }
    }

    private func startSource() {
        source.start(
            windowTitlePolicy: { [weak self] app in self?.mayReadTitle(of: app) ?? false },
            handler: { [weak self] sample in self?.receive(sample) }
        )
    }

    private func mayReadTitle(of app: FrontmostApp) -> Bool {
        updateTrust()
        guard accessibilityTrust == .trusted, app.bundleID != nil, app.processID != Self.ownProcessID else {
            return false
        }
        return filter.allowsWindowTitle(for: app)
    }

    private func receive(_ sample: ActivitySample) {
        guard isActive, !captureState.isPaused, let sink else { return }
        var sample = sample
        // Defence in depth: do not rely on the source honouring the policy.
        if !mayReadTitle(of: sample.app) {
            if sample.trigger == .titleChanged { return }
            sample.windowTitle = nil
            sample.browserURL = nil
        }
        guard let filtered = filter.filter(sample) else { return }
        sink(filtered)
    }
}
