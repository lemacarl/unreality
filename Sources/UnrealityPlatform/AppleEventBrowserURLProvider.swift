import CoreServices
import Foundation
import UnrealityCore

/// `BrowserURLProvider` that asks Safari and Chrome-family browsers for the
/// URL of the front window's active tab with one Apple Event each (the
/// equivalent of AppleScript's `get URL of current tab of front window`).
///
/// - Needs the **Automation** permission for each browser (System Settings >
///   Privacy & Security > Automation > Unreality). Reading never prompts:
///   before sending anything it checks the permission without asking
///   (`AEDeterminePermissionToAutomateTarget` with `askUserIfNeeded: false`)
///   and returns `.automationNotDetermined` or `.automationDenied` instead.
///   Only ``requestAutomationPermission(for:)``, for an explicit user action,
///   shows the system prompt.
/// - Events go to the frontmost browser's process ID, so they never launch
///   a browser, and use a short timeout so a busy browser cannot stall the
///   main thread for long.
/// - Chrome family: the front window's `mode` is read first; an `incognito`
///   window, or a mode that cannot be read, gives `.privateWindow` or
///   `.failed` and its URL is never read. Safari has no such property, so
///   its private windows cannot be told apart (docs/PRIVACY.md, "Limits").
/// - Firefox and web apps have no scripting support for tabs:
///   `.unsupportedBrowser`, nothing is sent.
/// - The URL is the browser's own (normalised) string; nothing is parsed
///   from window titles or the address bar.
@MainActor
public final class AppleEventBrowserURLProvider: BrowserURLProvider {
    private let client: any AppleEventClient
    private let timeout: TimeInterval

    /// - Parameter timeout: seconds to wait for each Apple Event reply.
    public convenience init(timeout: TimeInterval = 0.25) {
        self.init(client: SystemAppleEventClient(), timeout: timeout)
    }

    init(client: any AppleEventClient, timeout: TimeInterval = 0.25) {
        self.client = client
        self.timeout = timeout
    }

    public func activeTabURL(of app: FrontmostApp) -> BrowserURLReading {
        guard let paths = Self.paths(for: app) else { return .unreadable(.unsupportedBrowser) }
        switch automationPermission(for: app) {
        case .granted: break
        case .denied: return .unreadable(.automationDenied)
        case .notDetermined: return .unreadable(.automationNotDetermined)
        case .notRunning, .notApplicable, .unknown: return .unreadable(.failed)
        }
        if let modePath = paths.mode {
            switch client.string(at: modePath, processID: app.processID, timeout: timeout) {
            case .success("normal"?): break
            case .success("incognito"?): return .unreadable(.privateWindow)
            case .success: return .unreadable(.failed) // unknown or missing mode: fail closed
            case let .failure(error): return .unreadable(Self.unavailability(for: error))
            }
        }
        switch client.string(at: paths.url, processID: app.processID, timeout: timeout) {
        case let .success(url?) where !url.isEmpty: return .url(url)
        case .success: return .unreadable(.noWindow)
        case let .failure(error): return .unreadable(Self.unavailability(for: error))
        }
    }

    public func automationPermission(for app: FrontmostApp) -> BrowserAutomationPermission {
        guard Self.paths(for: app) != nil else { return .notApplicable }
        return Self.permission(for: client.permissionStatus(processID: app.processID))
    }

    public func requestAutomationPermission(for app: FrontmostApp) async -> BrowserAutomationPermission {
        guard Self.paths(for: app) != nil else { return .notApplicable }
        return Self.permission(for: await client.requestPermission(processID: app.processID))
    }

    // MARK: Mapping

    /// Where the URL (and, for the Chrome family, the window mode) lives.
    static func paths(for app: FrontmostApp) -> (url: AppleEventPath, mode: AppleEventPath?)? {
        switch KnownBrowser.matching(bundleID: app.bundleID)?.scripting {
        case .safari?:
            // URL of current tab of window 1
            return (AppleEventPath(.window(1), .property("cTab"), .property("pURL")), nil)
        case .chromium?:
            // URL of active tab of window 1; mode of window 1
            return (AppleEventPath(.window(1), .property("acTa"), .property("URL ")),
                    AppleEventPath(.window(1), .property("mode")))
        case .unsupported?, nil:
            return nil
        }
    }

    static func permission(for status: OSStatus) -> BrowserAutomationPermission {
        switch status {
        case noErr: .granted
        case AppleEventStatus.notPermitted: .denied
        case AppleEventStatus.wouldRequireConsent: .notDetermined
        case AppleEventStatus.processNotFound: .notRunning
        default: .unknown
        }
    }

    static func unavailability(for error: AppleEventError) -> BrowserURLUnavailability {
        switch error.status {
        case AppleEventStatus.notPermitted: .automationDenied
        case AppleEventStatus.wouldRequireConsent: .automationNotDetermined
        case AppleEventStatus.noSuchObject, AppleEventStatus.illegalIndex: .noWindow
        default: .failed
        }
    }
}

/// Apple Event and Open Scripting Architecture result codes used above.
enum AppleEventStatus {
    static let notPermitted: OSStatus = -1743 // errAEEventNotPermitted
    static let wouldRequireConsent: OSStatus = -1744 // errAEEventWouldRequireUserConsent
    static let processNotFound: OSStatus = -600 // procNotFound
    static let noSuchObject: OSStatus = -1728 // errAENoSuchObject
    static let illegalIndex: OSStatus = -1719 // errAEIllegalIndex
}

/// A failed Apple Event, as its OSStatus. Never carries reply data.
struct AppleEventError: Error, Equatable {
    let status: OSStatus
}

/// A property path from the target application, for example "property
/// `pURL` of property `cTab` of window 1".
struct AppleEventPath: Hashable, Sendable {
    enum Step: Hashable, Sendable {
        case window(Int32)
        case property(String)
    }

    let steps: [Step]

    init(_ steps: Step...) { self.steps = steps }

    /// The object specifier for this path, built innermost first.
    func specifier() -> NSAppleEventDescriptor? {
        var container = NSAppleEventDescriptor.null()
        for step in steps {
            guard let next = NSAppleEventDescriptor.record().coerce(toDescriptorType: fourCharCode("obj ")) else {
                return nil
            }
            switch step {
            case let .window(index):
                next.setDescriptor(NSAppleEventDescriptor(typeCode: fourCharCode("cwin")), forKeyword: fourCharCode("want"))
                next.setDescriptor(NSAppleEventDescriptor(enumCode: fourCharCode("indx")), forKeyword: fourCharCode("form"))
                next.setDescriptor(NSAppleEventDescriptor(int32: index), forKeyword: fourCharCode("seld"))
            case let .property(code):
                next.setDescriptor(NSAppleEventDescriptor(typeCode: fourCharCode("prop")), forKeyword: fourCharCode("want"))
                next.setDescriptor(NSAppleEventDescriptor(enumCode: fourCharCode("prop")), forKeyword: fourCharCode("form"))
                next.setDescriptor(NSAppleEventDescriptor(typeCode: fourCharCode(code)), forKeyword: fourCharCode("seld"))
            }
            next.setDescriptor(container, forKeyword: fourCharCode("from"))
            container = next
        }
        return container
    }
}

/// `"pURL"` as an OSType. `code` must be four ASCII characters.
func fourCharCode(_ code: String) -> FourCharCode {
    code.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
}

/// Seam over the Apple Event Manager, so the provider's logic is testable
/// without a browser or a permission grant.
@MainActor
protocol AppleEventClient {
    /// Automation permission for the process, without prompting.
    func permissionStatus(processID: Int32) -> OSStatus
    /// Automation permission for the process, prompting if undecided.
    func requestPermission(processID: Int32) async -> OSStatus
    /// Sends `get <path>` and returns the reply's text (`nil` when the reply
    /// has no text, such as AppleScript's `missing value`).
    func string(at path: AppleEventPath, processID: Int32, timeout: TimeInterval) -> Result<String?, AppleEventError>
}

/// The real Apple Event Manager.
struct SystemAppleEventClient: AppleEventClient {
    nonisolated private static let coreSuite = fourCharCode("core") // kAECoreSuite
    nonisolated private static let getData = fourCharCode("getd") // kAEGetData
    private static let directObject = fourCharCode("----") // keyDirectObject
    private static let errorNumber = fourCharCode("errn") // keyErrorNumber

    func permissionStatus(processID: Int32) -> OSStatus {
        Self.determinePermission(processID: processID, ask: false)
    }

    func requestPermission(processID: Int32) async -> OSStatus {
        // Blocks until the user answers the prompt: keep it off the main thread.
        await Task.detached { Self.determinePermission(processID: processID, ask: true) }.value
    }

    nonisolated private static func determinePermission(processID: Int32, ask: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(processIdentifier: processID)
        guard let address = target.aeDesc else { return AppleEventStatus.processNotFound }
        return AEDeterminePermissionToAutomateTarget(address, coreSuite, getData, ask)
    }

    func string(at path: AppleEventPath, processID: Int32, timeout: TimeInterval) -> Result<String?, AppleEventError> {
        guard let specifier = path.specifier() else { return .failure(AppleEventError(status: -1)) }
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: Self.coreSuite,
            eventID: Self.getData,
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: processID),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(specifier, forKeyword: Self.directObject)
        do {
            let reply = try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: timeout)
            if let code = reply.paramDescriptor(forKeyword: Self.errorNumber)?.int32Value, code != noErr {
                return .failure(AppleEventError(status: code))
            }
            return .success(reply.paramDescriptor(forKeyword: Self.directObject)?.stringValue)
        } catch {
            return .failure(AppleEventError(status: OSStatus(truncatingIfNeeded: (error as NSError).code)))
        }
    }
}
