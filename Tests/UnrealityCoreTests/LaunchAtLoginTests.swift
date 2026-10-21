import Testing
import UnrealityCore

@MainActor
@Suite("Launch at login")
struct LaunchAtLoginTests {
    private let failure = LoginItemError(operation: .register, domain: "test", code: 1)

    @Test("off by default and never registers on its own")
    func offByDefault() {
        let service = FakeLoginItemService()
        let model = LaunchAtLoginModel(service: service)
        model.refresh()
        #expect(!model.isEnabled)
        #expect(model.status == .notRegistered)
        #expect(service.registerCount == 0)
        #expect(service.unregisterCount == 0)
    }

    @Test("reflects what the service reports at creation")
    func initialStatusFromService() {
        #expect(LaunchAtLoginModel(service: FakeLoginItemService(status: .enabled)).isEnabled)
        #expect(LaunchAtLoginModel(service: FakeLoginItemService(status: .requiresApproval)).isEnabled)
        #expect(!LaunchAtLoginModel(service: FakeLoginItemService(status: .notFound)).isEnabled)
    }

    @Test("turning on registers, turning off unregisters")
    func toggle() {
        let service = FakeLoginItemService()
        let model = LaunchAtLoginModel(service: service)
        model.setEnabled(true)
        #expect(service.registerCount == 1)
        #expect(model.status == .enabled)
        #expect(model.lastError == nil)
        model.setEnabled(false)
        #expect(service.unregisterCount == 1)
        #expect(model.status == .notRegistered)
        #expect(!model.isEnabled)
    }

    @Test("setting the current state again calls nothing")
    func idempotent() {
        let service = FakeLoginItemService()
        let model = LaunchAtLoginModel(service: service)
        model.setEnabled(false)
        #expect(service.unregisterCount == 0)
        model.setEnabled(true)
        model.setEnabled(true)
        #expect(service.registerCount == 1)
    }

    @Test("registration that needs approval shows on, with the approval status")
    func requiresApproval() {
        let service = FakeLoginItemService()
        service.statusAfterRegister = .requiresApproval
        let model = LaunchAtLoginModel(service: service)
        model.setEnabled(true)
        #expect(model.isEnabled)
        #expect(model.status == .requiresApproval)
        #expect(model.lastError == nil)
        model.openLoginItemsSettings()
        #expect(service.openSettingsCount == 1)
    }

    @Test("turning off while approval is pending unregisters")
    func offWhilePendingApproval() {
        let service = FakeLoginItemService(status: .requiresApproval)
        let model = LaunchAtLoginModel(service: service)
        model.setEnabled(false)
        #expect(service.unregisterCount == 1)
        #expect(!model.isEnabled)
    }

    @Test("a failed registration keeps the toggle off and reports the error")
    func registerFailure() {
        let service = FakeLoginItemService()
        service.registerError = failure
        let model = LaunchAtLoginModel(service: service)
        model.setEnabled(true)
        #expect(!model.isEnabled)
        #expect(model.lastError == failure)
        service.registerError = nil
        model.setEnabled(true)
        #expect(model.isEnabled)
        #expect(model.lastError == nil)
    }

    @Test("a failed unregistration keeps the toggle on and reports the error")
    func unregisterFailure() {
        let service = FakeLoginItemService(status: .enabled)
        let error = LoginItemError(operation: .unregister, domain: "test", code: 2)
        service.unregisterError = error
        let model = LaunchAtLoginModel(service: service)
        model.setEnabled(false)
        #expect(model.isEnabled)
        #expect(model.lastError == error)
    }

    @Test("an error is dropped when the status shows the request took effect")
    func errorWithRequestRecorded() {
        let service = FakeLoginItemService()
        service.registerError = failure
        service.statusAfterFailure = .requiresApproval
        let model = LaunchAtLoginModel(service: service)
        model.setEnabled(true)
        #expect(service.registerCount == 1)
        #expect(model.lastError == nil)
        #expect(model.status == .requiresApproval)
    }

    @Test("refresh clears a register error once macOS reports it on")
    func refreshClearsRegisterError() {
        let service = FakeLoginItemService()
        service.registerError = failure
        let model = LaunchAtLoginModel(service: service)
        model.setEnabled(true)
        #expect(model.lastError == failure)
        model.refresh()
        #expect(model.lastError == failure)
        service.currentStatus = .enabled
        model.refresh()
        #expect(model.lastError == nil)
        #expect(model.isEnabled)
    }

    @Test("refresh clears an unregister error once macOS reports it off")
    func refreshClearsUnregisterError() {
        let service = FakeLoginItemService(status: .enabled)
        let error = LoginItemError(operation: .unregister, domain: "test", code: 2)
        service.unregisterError = error
        let model = LaunchAtLoginModel(service: service)
        model.setEnabled(false)
        #expect(model.lastError == error)
        service.currentStatus = .notRegistered
        model.refresh()
        #expect(model.lastError == nil)
        #expect(!model.isEnabled)
    }

    @Test("turning on from notFound registers")
    func registerFromNotFound() {
        let service = FakeLoginItemService(status: .notFound)
        let model = LaunchAtLoginModel(service: service)
        model.setEnabled(true)
        #expect(service.registerCount == 1)
        #expect(model.status == .enabled)
    }

    @Test("refresh picks up changes made in System Settings")
    func refreshSeesExternalChange() {
        let service = FakeLoginItemService(status: .enabled)
        let model = LaunchAtLoginModel(service: service)
        service.currentStatus = .requiresApproval
        #expect(model.status == .enabled)
        model.refresh()
        #expect(model.status == .requiresApproval)
        service.currentStatus = .notRegistered
        model.refresh()
        #expect(!model.isEnabled)
    }

    @Test("only enabled and requiresApproval count as requested")
    func isRequested() {
        let requested = LoginItemStatus.allCases.filter(\.isRequested)
        #expect(Set(requested) == [.enabled, .requiresApproval])
    }
}
