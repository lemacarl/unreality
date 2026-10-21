import CoreServices
import Foundation
import UnrealityCore

/// `BrowserURLProvider` that asks Safari and Chrome-family browsers for the
/// URL of the front window's active tab with Apple Events (the equivalent
/// of AppleScript's `get URL of current tab of window id <id>`).
///
/// - Needs the **Automation** permission for each browser (System Settings >
///   Privacy & Security > Automation > Unreality). Reading never prompts:
///   before sending anything it checks the permission without asking
///   (`AEDeterminePermissionToAutomateTarget` with `askUserIfNeeded: false`)
///   and returns `.automationNotDetermined` or `.automationDenied` instead.
///   A granted state is cached for the process until ``resetCachedState()``
///   (every app activation) or an event reports a permission error. Only
///   ``requestAutomationPermission(for:)``, for an explicit user action,
///   shows the system prompt.
/// - One read is a short sequence of events, all addressed to the window
///   found first, by its unique ID, so a window that comes to the front
///   mid-sequence is never read: `id of window 1`; for the Chrome family
///   that window's `mode` (only `normal` continues: an `incognito`, unknown
///   or unreadable mode stops with `.privateWindow` or `.failed`); its
///   `name`, which must equal the focused window's Accessibility title
///   (otherwise `.windowMismatch`: the title and URL could belong to
///   different windows, such as an undocked DevTools window); then the URL
///   of its current tab. The sequence stops at the first failure.
/// - Events go to the browser's process ID, so they never launch a browser.
///   Each waits at most `timeout`; after a timeout, the process is not sent
///   anything until the next app activation (``resetCachedState()``).
/// - Safari has no private-window property, so its private windows cannot
///   be told apart (docs/PRIVACY.md, "Limits").
/// - Firefox, other unsupported browsers and web apps: `.unsupportedBrowser`,
///   nothing is sent.
/// - The URL is the browser's own (normalised) string; nothing is parsed
///   from window titles or the address bar.
@MainActor
public final class AppleEventBrowserURLProvider: BrowserURLProvider {
    /// Property codes for one scripting dictionary.
    struct Dictionary: Equatable {
        /// Property of the window that holds the active tab.
        let activeTab: String
        /// Property of the tab that holds its URL.
        let url: String
        /// Window property that says whether the window is private, if any.
        let mode: String?

        static let safari = Dictionary(activeTab: "cTab", url: "pURL", mode: nil)
        static let chromium = Dictionary(activeTab: "acTa", url: "URL ", mode: "mode")
    }

    private let client: any AppleEventClient
    private let timeout: TimeInterval
    /// The process whose Automation permission was last found granted.
    private var grantedProcessID: Int32?
    /// The process that last timed out; not sent anything until reset.
    private var unresponsiveProcessID: Int32?

    /// - Parameter timeout: seconds to wait for each Apple Event reply.
    public convenience init(timeout: TimeInterval = 0.25) {
        self.init(client: SystemAppleEventClient(), timeout: timeout)
    }

    init(client: any AppleEventClient, timeout: TimeInterval = 0.25) {
        self.client = client
        self.timeout = timeout
    }

    public func activeTabURL(of app: FrontmostApp, focusedWindowTitle: String?) -> BrowserURLReading {
        guard let dictionary = Self.dictionary(for: app) else { return .unreadable(.unsupportedBrowser) }
        // Without a title there is nothing to match the scripted window to.
        guard let focusedWindowTitle, !focusedWindowTitle.isEmpty else { return .unreadable(.windowMismatch) }
        let pid = app.processID
        if unresponsiveProcessID == pid { return .unreadable(.failed) }
        if grantedProcessID != pid {
            if let refusal = Self.refusal(for: automationPermission(for: app)) { return .unreadable(refusal) }
            grantedProcessID = pid
        }
        let reading = read(dictionary, processID: pid, title: focusedWindowTitle)
        if case let .unreadable(reason) = reading, [.automationDenied, .automationNotDetermined].contains(reason) {
            grantedProcessID = nil
        }
        return reading
    }

    public func resetCachedState() {
        grantedProcessID = nil
        unresponsiveProcessID = nil
    }

    public func automationPermission(for app: FrontmostApp) -> BrowserAutomationPermission {
        guard Self.dictionary(for: app) != nil else { return .notApplicable }
        return Self.permission(for: client.permissionStatus(processID: app.processID))
    }

    public func requestAutomationPermission(for app: FrontmostApp) async -> BrowserAutomationPermission {
        guard Self.dictionary(for: app) != nil else { return .notApplicable }
        resetCachedState()
        return Self.permission(for: await client.requestPermission(processID: app.processID))
    }

    // MARK: Reading

    private enum Stop: Error { case unavailable(BrowserURLUnavailability) }

    private func read(_ dictionary: Dictionary, processID pid: Int32, title: String) -> BrowserURLReading {
        do throws(Stop) {
            guard let windowID = try get(AppleEventPath(.window(1), .property("ID  ")), pid) else {
                return .unreadable(.noWindow)
            }
            let window = AppleEventPath.Step.windowID(windowID)
            if let mode = dictionary.mode {
                switch try get(AppleEventPath(window, .property(mode)), pid) {
                case .text("normal")?: break
                case .text("incognito")?: return .unreadable(.privateWindow)
                default: return .unreadable(.failed) // unknown or missing mode: fail closed
                }
            }
            guard case .text(title)? = try get(AppleEventPath(window, .property("pnam")), pid) else {
                return .unreadable(.windowMismatch)
            }
            let url = AppleEventPath(window, .property(dictionary.activeTab), .property(dictionary.url))
            guard case let .text(value)? = try get(url, pid), !value.isEmpty else { return .unreadable(.noWindow) }
            return .url(value)
        } catch {
            guard case let .unavailable(reason) = error else { return .unreadable(.failed) }
            return .unreadable(reason)
        }
    }

    private func get(_ path: AppleEventPath, _ pid: Int32) throws(Stop) -> AppleEventValue? {
        switch client.value(at: path, processID: pid, timeout: timeout) {
        case let .success(value):
            return value
        case let .failure(error):
            if error.status == AppleEventStatus.timeout { unresponsiveProcessID = pid }
            throw .unavailable(Self.unavailability(for: error))
        }
    }

    // MARK: Mapping

    static func dictionary(for app: FrontmostApp) -> Dictionary? {
        switch KnownBrowser.matching(bundleID: app.bundleID)?.scripting {
        case .safari?: .safari
        case .chromium?: .chromium
        case .unsupported?, nil: nil
        }
    }

    /// Why nothing may be sent with this permission state, or `nil` if granted.
    static func refusal(for permission: BrowserAutomationPermission) -> BrowserURLUnavailability? {
        switch permission {
        case .granted: nil
        case .denied: .automationDenied
        case .notDetermined: .automationNotDetermined
        case .notRunning, .notApplicable, .unknown: .failed
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
    static let timeout: OSStatus = -1712 // errAETimeout
    /// The object specifier could not be built (`errAECoercionFail`).
    static let specifierUnavailable: OSStatus = -1700
}

/// A failed Apple Event, as its OSStatus. Never carries reply data.
struct AppleEventError: Error, Equatable {
    let status: OSStatus
}

/// A reply value the provider uses: text, or an integer (Safari window IDs).
enum AppleEventValue: Hashable, Sendable {
    case text(String)
    case integer(Int32)

    var descriptor: NSAppleEventDescriptor {
        switch self {
        case let .text(text): NSAppleEventDescriptor(string: text)
        case let .integer(value): NSAppleEventDescriptor(int32: value)
        }
    }
}

/// A property path from the target application, for example "property
/// `pURL` of property `cTab` of window id 42".
struct AppleEventPath: Hashable, Sendable {
    enum Step: Hashable, Sendable {
        /// `window <index>` (front to back, from 1).
        case window(Int32)
        /// `window id <id>`: one window, whatever its position.
        case windowID(AppleEventValue)
        case property(String)
    }

    let steps: [Step]

    init(_ steps: Step...) { self.steps = steps }

    /// The object specifier for this path, built innermost first.
    func specifier() -> NSAppleEventDescriptor? {
        var container = NSAppleEventDescriptor.null()
        for step in steps {
            let next: NSAppleEventDescriptor?
            switch step {
            case let .window(index):
                // keyAEDesiredClass cWindow, keyAEKeyForm formAbsolutePosition
                next = Self.objectSpecifier(want: "cwin", form: "indx", data: NSAppleEventDescriptor(int32: index),
                                            from: container)
            case let .windowID(id):
                // keyAEDesiredClass cWindow, keyAEKeyForm formUniqueID
                next = Self.objectSpecifier(want: "cwin", form: "ID  ", data: id.descriptor, from: container)
            case let .property(code):
                // keyAEDesiredClass cProperty, keyAEKeyForm formPropertyID
                next = Self.objectSpecifier(want: "prop", form: "prop",
                                            data: NSAppleEventDescriptor(typeCode: fourCharCode(code)), from: container)
            }
            guard let next else { return nil }
            container = next
        }
        return container
    }

    private static func objectSpecifier(
        want: String, form: String, data: NSAppleEventDescriptor, from container: NSAppleEventDescriptor
    ) -> NSAppleEventDescriptor? {
        guard let specifier = NSAppleEventDescriptor.record().coerce(toDescriptorType: fourCharCode("obj ")) else {
            return nil
        }
        specifier.setDescriptor(NSAppleEventDescriptor(typeCode: fourCharCode(want)), forKeyword: fourCharCode("want"))
        specifier.setDescriptor(NSAppleEventDescriptor(enumCode: fourCharCode(form)), forKeyword: fourCharCode("form"))
        specifier.setDescriptor(data, forKeyword: fourCharCode("seld"))
        specifier.setDescriptor(container, forKeyword: fourCharCode("from"))
        return specifier
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
    /// Sends `get <path>` and returns the reply's value (`nil` when the
    /// reply has none, such as AppleScript's `missing value`).
    func value(at path: AppleEventPath, processID: Int32,
               timeout: TimeInterval) -> Result<AppleEventValue?, AppleEventError>
}

/// The real Apple Event Manager.
struct SystemAppleEventClient: AppleEventClient {
    nonisolated private static let coreSuite = fourCharCode("core") // kAECoreSuite
    nonisolated private static let getData = fourCharCode("getd") // kAEGetData
    private static let directObject = fourCharCode("----") // keyDirectObject
    private static let errorNumber = fourCharCode("errn") // keyErrorNumber
    private static let integerType = fourCharCode("long") // typeSInt32

    func permissionStatus(processID: Int32) -> OSStatus {
        Self.determinePermission(processID: processID, ask: false)
    }

    func requestPermission(processID: Int32) async -> OSStatus {
        // Blocks until the user answers the prompt: keep it off the main thread.
        await Task.detached { Self.determinePermission(processID: processID, ask: true) }.value
    }

    nonisolated private static func determinePermission(processID: Int32, ask: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(processIdentifier: processID)
        // `aeDesc` points into `target`'s storage: keep `target` alive until
        // the call has read it (Swift may release it after its last use).
        return withExtendedLifetime(target) {
            guard let address = target.aeDesc else { return AppleEventStatus.processNotFound }
            return AEDeterminePermissionToAutomateTarget(address, coreSuite, getData, ask)
        }
    }

    func value(at path: AppleEventPath, processID: Int32,
               timeout: TimeInterval) -> Result<AppleEventValue?, AppleEventError> {
        guard let specifier = path.specifier() else {
            return .failure(AppleEventError(status: AppleEventStatus.specifierUnavailable))
        }
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
            guard let value = reply.paramDescriptor(forKeyword: Self.directObject) else { return .success(nil) }
            if value.descriptorType == Self.integerType { return .success(.integer(value.int32Value)) }
            return .success(value.stringValue.map(AppleEventValue.text))
        } catch {
            return .failure(AppleEventError(status: OSStatus(truncatingIfNeeded: (error as NSError).code)))
        }
    }
}
