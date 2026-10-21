import Foundation
import Observation

/// Whether macOS starts Unreality when the user logs in, as macOS reports it.
public enum LoginItemStatus: String, Sendable, Equatable, CaseIterable {
    /// Not registered: Unreality does not start at login.
    case notRegistered
    /// Registered and allowed: Unreality starts at login.
    case enabled
    /// Registered, but the user must allow it in System Settings > General >
    /// Login Items before it takes effect (for example after turning it off
    /// there).
    case requiresApproval
    /// macOS could not find the app's login item (typical for an unsigned
    /// build or one run from a temporary location). Treated as off.
    case notFound

    /// True when the user has asked for launch at login, whether or not
    /// macOS still needs approval. Drives the settings toggle.
    public var isRequested: Bool {
        self == .enabled || self == .requiresApproval
    }
}

/// A failure macOS reported while changing the login item. Carries only the
/// error domain and code (no paths or user data), so it is safe to log.
public struct LoginItemError: Error, Sendable, Equatable {
    public enum Operation: String, Sendable, Equatable {
        case register
        case unregister
    }

    public let operation: Operation
    public let domain: String
    public let code: Int

    public init(operation: Operation, domain: String, code: Int) {
        self.operation = operation
        self.domain = domain
        self.code = code
    }
}

/// Registers the app itself to start at login (ADR 0001: `SMAppService`).
///
/// The service is the source of truth: implementations read the status from
/// macOS each time and keep no copy of it (in particular not in settings),
/// because the user can change it in System Settings at any time.
@MainActor
public protocol LoginItemService: AnyObject {
    /// The current status. Must have no side effects.
    func status() -> LoginItemStatus
    /// Asks macOS to start the app at login. Call it only from an explicit
    /// user action, never at launch. On success the status is `enabled` or
    /// `requiresApproval`.
    func register() throws(LoginItemError)
    /// Stops starting the app at login.
    func unregister() throws(LoginItemError)
    /// Opens System Settings > General > Login Items.
    func openLoginItemsSettings()
}

/// Test double for `LoginItemService`.
@MainActor
public final class FakeLoginItemService: LoginItemService {
    /// The status `status()` reports; also changed by `register`/`unregister`.
    public var currentStatus: LoginItemStatus
    /// The status a successful `register()` leaves behind.
    public var statusAfterRegister: LoginItemStatus = .enabled
    /// When set, `register()` throws it (and the status is unchanged).
    public var registerError: LoginItemError?
    /// When set, `unregister()` throws it (and the status is unchanged).
    public var unregisterError: LoginItemError?
    /// When set, a throwing `register()`/`unregister()` still moves the
    /// status here, simulating macOS recording a request it reports as failed.
    public var statusAfterFailure: LoginItemStatus?
    public private(set) var registerCount = 0
    public private(set) var unregisterCount = 0
    public private(set) var openSettingsCount = 0

    public init(status: LoginItemStatus = .notRegistered) {
        currentStatus = status
    }

    public func status() -> LoginItemStatus { currentStatus }

    public func register() throws(LoginItemError) {
        registerCount += 1
        if let registerError {
            if let statusAfterFailure { currentStatus = statusAfterFailure }
            throw registerError
        }
        currentStatus = statusAfterRegister
    }

    public func unregister() throws(LoginItemError) {
        unregisterCount += 1
        if let unregisterError {
            if let statusAfterFailure { currentStatus = statusAfterFailure }
            throw unregisterError
        }
        currentStatus = .notRegistered
    }

    public func openLoginItemsSettings() {
        openSettingsCount += 1
    }
}

/// Observable launch-at-login state for the settings UI. It never registers
/// on its own: only `setEnabled(_:)`, called from the user's toggle, changes
/// the login item. `status` is a display copy of the service's answer,
/// re-read after every change and on `refresh()`; it is never persisted.
@MainActor
@Observable
public final class LaunchAtLoginModel {
    @ObservationIgnored private let service: any LoginItemService
    public private(set) var status: LoginItemStatus
    /// The last failed change, cleared by the next successful one or by
    /// `refresh()` when the status shows the request took effect.
    public private(set) var lastError: LoginItemError?

    public init(service: any LoginItemService) {
        self.service = service
        status = service.status()
    }

    /// Whether the toggle shows on (`enabled` or `requiresApproval`).
    public var isEnabled: Bool { status.isRequested }

    /// Re-reads the status, for example when the settings window appears or
    /// the app becomes active again after System Settings. Clears
    /// `lastError` once the status shows the failed request took effect.
    public func refresh() {
        let current = service.status()
        // Skip same-value writes so observers are not invalidated needlessly.
        if current != status {
            status = current
        }
        if let lastError, requestTookEffect(lastError) {
            self.lastError = nil
        }
    }

    /// Registers or unregisters the login item for an explicit user action.
    /// A no-op when the status already matches. Failures are kept in
    /// `lastError`; the status is re-read either way.
    public func setEnabled(_ enabled: Bool) {
        refresh()
        guard enabled != status.isRequested else {
            lastError = nil
            return
        }
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            lastError = nil
        } catch {
            lastError = error
        }
        // Also drops the error if macOS recorded the request anyway.
        refresh()
    }

    /// macOS can report a failure while still recording the request (for
    /// example register throwing while approval is pending, or the user
    /// changing it in System Settings afterwards): the status, not the
    /// error, is what the user needs to act on.
    private func requestTookEffect(_ error: LoginItemError) -> Bool {
        status.isRequested == (error.operation == .register)
    }

    public func openLoginItemsSettings() {
        service.openLoginItemsSettings()
    }
}
