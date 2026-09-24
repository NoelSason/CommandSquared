import AppKit
import Carbon.HIToolbox
import ControlKit
import Foundation

/// Takes Tab for itself while an inline suggestion is showing, so Tab can fill
/// the suggestion in instead of moving to the next field.
///
/// A global event monitor can only watch, so this is an event tap, which can
/// swallow an event. It is created once and stays disabled except while a
/// suggestion is on screen; the rest of the time Tab is never seen, let alone
/// taken. Only a bare Tab is taken — ⇧Tab and every chord pass straight through.
@MainActor
final class TabInterceptor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private(set) var isArmed = false

    /// Called on the main actor after a Tab was taken. The tap disarms itself
    /// first, so a second Tab behaves normally.
    var onTab: (@MainActor () -> Void)?

    /// Whether Tab can be taken at all. False when macOS refused the tap, and
    /// then suggestions are filled with the trigger instead.
    var isAvailable: Bool { tap != nil }

    /// Creates the tap, disabled. Safe to call more than once.
    @discardableResult
    func install() -> Bool {
        if tap != nil { return true }

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let interceptor = Unmanaged<TabInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
            // The tap's source is on the main run loop, so this is the main thread.
            let swallow = MainActor.assumeIsolated { interceptor.shouldSwallow(type: type, event: event) }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.app.error("Couldn't create the Tab tap; suggestions will fill with the trigger only.")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: false)
        self.tap = tap
        self.source = source
        return true
    }

    func uninstall() {
        disarm()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
    }

    func arm() {
        guard let tap, !isArmed else { return }
        isArmed = true
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func disarm() {
        guard isArmed else { return }
        isArmed = false
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    }

    /// Puts back a Tab that was taken but couldn't be used, so the user's
    /// keypress still does what they meant. Posted past this tap's own point
    /// in the event stream, so it can't be taken twice.
    static func repostTab() {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Tab), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Tab), keyDown: false)
        else { return }
        down.flags = []
        up.flags = []
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }

    /// Decided inside the tap, so it must be quick: no Accessibility calls
    /// here. The fill happens afterwards, off the tap.
    private func shouldSwallow(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if isArmed, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard isArmed,
              type == .keyDown,
              event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Tab),
              event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
              event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty
        else { return false }

        disarm()
        let handler = onTab
        Task { @MainActor in handler?() }
        return true
    }
}
