import CoreGraphics
import Foundation

/// Isolated bridge to private SkyLight SPIs for delivering a synthetic event to a specific process
/// WITHOUT moving the real cursor or raising the app. It is the *enhancement* layer over the public
/// per-process post (`CGEvent.postToPid`): it adds the activity-monitor tickle some apps need to treat
/// a synthetic key as live input, and the macOS-14 key authentication envelope Chromium/Electron
/// require, plus a window-local hit-test point for a backgrounded window.
///
/// The bridge is enabled by default — there is no flag to turn it on. Instead it is gated by capability
/// detection: symbols are loaded via `dlopen`/`dlsym`, and when any required one is missing the bridge
/// reports itself unavailable and every method returns `false`, so the caller falls back to the public
/// per-process post (still cursor-neutral) and ultimately to the HID tap. This is the ONLY file that
/// names a SkyLight symbol.
///
/// Focus-without-raise (the window-server event-record post) is intentionally not implemented in this
/// cut: the public per-process post and the no-auth mouse recipe do not require it, and it is the most
/// fragile of the reverse-engineered pieces. It is the natural next addition if a backgrounded mouse
/// gesture on a web surface needs the target to be app-active first.
public final class SkyLightEventPost: @unchecked Sendable {
    public static let shared = SkyLightEventPost()

    private typealias PostToPidFn = @convention(c) (pid_t, CGEvent) -> Void
    private typealias SetAuthMessageFn = @convention(c) (CGEvent, AnyObject) -> Void
    private typealias FactoryMsgSendFn = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer, Int32, UInt32) -> AnyObject?
    private typealias SetIntegerFieldFn = @convention(c) (CGEvent, UInt32, Int64) -> Void
    private typealias SetWindowLocationFn = @convention(c) (CGEvent, CGPoint) -> Void

    private struct Resolved {
        let postToPid: PostToPidFn
        let setAuthMessage: SetAuthMessageFn
        let msgSendFactory: FactoryMsgSendFn
        let messageClass: AnyClass
        let factorySelector: Selector
    }

    private let resolved: Resolved?
    /// Resolved independently so one missing symbol doesn't disable the core post path.
    private let setIntegerField: SetIntegerFieldFn?
    private let setWindowLocation: SetWindowLocationFn?

    public var isAvailable: Bool { resolved != nil }

    public init() {
        let symbols = Self.resolveSymbols()
        resolved = symbols.resolved
        setIntegerField = symbols.setIntegerField
        setWindowLocation = symbols.setWindowLocation
    }

    /// Designated initializer used to construct a known-unavailable instance for tests, without touching
    /// the real symbol table. Production always goes through `init()`.
    private init(
        resolved: Resolved?,
        setIntegerField: SetIntegerFieldFn?,
        setWindowLocation: SetWindowLocationFn?
    ) {
        self.resolved = resolved
        self.setIntegerField = setIntegerField
        self.setWindowLocation = setWindowLocation
    }

    /// A bridge that always reports unavailable — the deterministic stand-in for "the SkyLight symbols
    /// didn't resolve", so the fallback contract is testable without depending on the host's symbols.
    static func unavailableForTesting() -> SkyLightEventPost {
        SkyLightEventPost(resolved: nil, setIntegerField: nil, setWindowLocation: nil)
    }

    private static func resolveSymbols() -> (
        resolved: Resolved?,
        setIntegerField: SetIntegerFieldFn?,
        setWindowLocation: SetWindowLocationFn?
    ) {
        _ = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        func symbol(_ name: String) -> UnsafeMutableRawPointer? { dlsym(rtldDefault, name) }

        let setIntegerField = symbol("SLEventSetIntegerValueField")
            .map { unsafeBitCast($0, to: SetIntegerFieldFn.self) }
        let setWindowLocation = symbol("CGEventSetWindowLocation")
            .map { unsafeBitCast($0, to: SetWindowLocationFn.self) }

        guard let postPtr = symbol("SLEventPostToPid"),
              let authPtr = symbol("SLEventSetAuthenticationMessage"),
              let msgSendPtr = symbol("objc_msgSend"),
              let messageClass = NSClassFromString("SLSEventAuthenticationMessage")
        else {
            return (nil, setIntegerField, setWindowLocation)
        }

        let resolved = Resolved(
            postToPid: unsafeBitCast(postPtr, to: PostToPidFn.self),
            setAuthMessage: unsafeBitCast(authPtr, to: SetAuthMessageFn.self),
            msgSendFactory: unsafeBitCast(msgSendPtr, to: FactoryMsgSendFn.self),
            messageClass: messageClass,
            factorySelector: NSSelectorFromString("messageWithEventRecord:pid:version:")
        )
        return (resolved, setIntegerField, setWindowLocation)
    }

    /// Posts a keyboard event to `pid`, attaching the macOS-14 authentication envelope so Chromium/Electron
    /// accept the synthetic key. Returns true when the SPI path was taken; false (unavailable) means the
    /// caller should fall back to the public per-process post.
    @discardableResult
    public func postKey(_ event: CGEvent, toPid pid: pid_t) -> Bool {
        guard let resolved else { return false }
        if let record = extractEventRecord(from: event),
           let message = resolved.msgSendFactory(
               resolved.messageClass as AnyObject,
               resolved.factorySelector,
               record,
               Int32(pid),
               0
           ) {
            resolved.setAuthMessage(event, message)
        }
        resolved.postToPid(pid, event)
        return true
    }

    /// Posts a mouse event to `pid`, stamping the window-local hit-test point and the target pid field so
    /// the window server routes it to the backgrounded window. The mouse recipe deliberately attaches no
    /// authentication envelope. Returns true when the SPI path was taken; false (unavailable) means the
    /// caller should fall back to the public per-process post.
    @discardableResult
    public func postMouse(
        _ event: CGEvent,
        toPid pid: pid_t,
        windowID: UInt32,
        windowLocalPoint: CGPoint
    ) -> Bool {
        guard let resolved else { return false }
        // Best-effort stamps; absence of either optional SPI simply means the window server falls back to
        // re-projecting from the event's screen-space location. windowID is carried for parity with the
        // recipe but is auto-filled by the event bridge, so it is not written explicitly here.
        _ = windowID
        setWindowLocation?(event, windowLocalPoint)
        setIntegerField?(event, 40, Int64(pid))
        resolved.postToPid(pid, event)
        return true
    }

    /// Reads the `SLSEventRecord*` embedded in the opaque `__CGEvent`, probing the candidate pointer
    /// slots the layout has used across OS revisions. Returns nil when none holds a pointer, in which
    /// case `postKey` posts without the authentication envelope (valid on older releases).
    private func extractEventRecord(from event: CGEvent) -> UnsafeMutableRawPointer? {
        let base = Unmanaged.passUnretained(event).toOpaque()
        for offset in [24, 32, 16] {
            if let record = base.load(fromByteOffset: offset, as: UnsafeMutableRawPointer?.self) {
                return record
            }
        }
        return nil
    }
}
