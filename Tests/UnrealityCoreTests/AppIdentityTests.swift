import Testing
import UnrealityCore

@Suite("AppIdentity")
struct AppIdentityTests {
    @Test("display name is Unreality")
    func displayName() {
        #expect(AppIdentity.displayName == "Unreality")
    }

    @Test("bundle identifier is the stable reverse-DNS ID")
    func bundleIdentifier() {
        #expect(AppIdentity.bundleIdentifier == "com.lemacarl.unreality")
    }
}
