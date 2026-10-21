import Foundation
import ServiceManagement
import Testing
@testable import UnrealityPlatform

/// Only the pure mapping is tested here: registering a real login item needs
/// a signed app bundle and changes the user's Login Items, so it is a manual
/// check (CONTRIBUTING.md, "Manual checks").
@Suite("SMAppServiceLoginItemService")
struct SMAppServiceLoginItemServiceTests {
    @Test("maps every SMAppService status")
    func mapsStatus() {
        #expect(SMAppServiceLoginItemService.map(.notRegistered) == .notRegistered)
        #expect(SMAppServiceLoginItemService.map(.enabled) == .enabled)
        #expect(SMAppServiceLoginItemService.map(.requiresApproval) == .requiresApproval)
        #expect(SMAppServiceLoginItemService.map(.notFound) == .notFound)
    }

    @Test("errors keep only domain and code")
    func errorKeepsDomainAndCode() {
        let underlying = NSError(
            domain: "SMAppServiceErrorDomain",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "/private/path/should/not/leak"]
        )
        let error = SMAppServiceLoginItemService.loginItemError(underlying, operation: .unregister)
        #expect(error.operation == .unregister)
        #expect(error.domain == "SMAppServiceErrorDomain")
        #expect(error.code == 1)
        #expect(!String(describing: error).contains("/private/path"))
    }
}
