import Testing
import UnrealityCore
@testable import UnrealityPlatform

@Suite("PlatformInfo")
struct PlatformInfoTests {
    @Test("OS version has major.minor.patch form and is at least macOS 14")
    func operatingSystemVersion() throws {
        let parts = PlatformInfo.operatingSystemVersion.split(separator: ".")
        #expect(parts.count == 3)
        let major = try #require(Int(parts[0]))
        #expect(major >= 14)
    }

    @Test("display name comes from the core")
    func appDisplayName() {
        #expect(PlatformInfo.appDisplayName == AppIdentity.displayName)
    }
}
