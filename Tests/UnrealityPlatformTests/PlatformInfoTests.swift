import Testing
import UnrealityPlatform

@Suite("PlatformInfo")
struct PlatformInfoTests {
    @Test("OS version has major.minor.patch form and is at least macOS 14")
    func operatingSystemVersion() throws {
        let parts = PlatformInfo.operatingSystemVersion.split(separator: ".")
        try #require(parts.count == 3)
        let major = try #require(Int(parts[0]))
        #expect(major >= 14)
    }
}
