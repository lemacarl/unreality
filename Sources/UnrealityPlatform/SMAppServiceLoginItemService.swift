import Foundation
import ServiceManagement
import UnrealityCore

/// `LoginItemService` backed by `SMAppService.mainApp` (macOS 13+): the app
/// itself is the login item, with no helper bundle.
///
/// Status is read from macOS on every call and never cached. Registration
/// only works reliably for a signed app in a stable location (for example
/// /Applications); ad-hoc and unsigned dev builds may report `notFound`,
/// fail to register, or leave a stale entry in Login Items. See
/// CONTRIBUTING.md, "Manual checks".
@MainActor
public final class SMAppServiceLoginItemService: LoginItemService {
    private let service: SMAppService

    public init() {
        service = .mainApp
    }

    public func status() -> LoginItemStatus {
        Self.map(service.status)
    }

    public func register() throws(LoginItemError) {
        do {
            try service.register()
        } catch {
            throw Self.loginItemError(error, operation: .register)
        }
    }

    public func unregister() throws(LoginItemError) {
        do {
            try service.unregister()
        } catch {
            throw Self.loginItemError(error, operation: .unregister)
        }
    }

    public func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Maps the framework status to the core's. `@unknown` cases read as
    /// `notFound` (off), so a new status never shows the toggle as on.
    nonisolated static func map(_ status: SMAppService.Status) -> LoginItemStatus {
        switch status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    /// Keeps only the domain and code: localised descriptions may name
    /// paths, which must not reach logs.
    nonisolated static func loginItemError(_ error: any Error, operation: LoginItemError.Operation) -> LoginItemError {
        let nsError = error as NSError
        return LoginItemError(operation: operation, domain: nsError.domain, code: nsError.code)
    }
}
