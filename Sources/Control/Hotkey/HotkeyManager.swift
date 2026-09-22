import AppKit
import Carbon.HIToolbox
import ControlKit
import Foundation

/// Registers the global hotkey.
///
/// Carbon's `RegisterEventHotKey` rather than `NSEvent.addGlobalMonitorForEvents`
/// for two reasons: it consumes the event, so the keystroke never leaks into the
/// field being filled, and it needs only Accessibility rather than Input
/// Monitoring. It remains the supported path on current macOS.
@MainActor
final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var binding: HotkeyBinding?

    /// Called on the main actor each time the hotkey fires.
    var onFire: (@MainActor () -> Void)?

    private static let signature: OSType = 0x4354_524C // 'CTRL'

    // No deinit: the Carbon refs are non-Sendable so they cannot be touched from
    // a nonisolated deinit, and this object lives for the whole process anyway.
    // Call `unregister()` explicitly if that ever stops being true.

    var currentBinding: HotkeyBinding? { binding }

    @discardableResult
    func register(_ binding: HotkeyBinding) -> Bool {
        unregister()
        guard binding.isValid else {
            Log.app.error("Refusing to register a hotkey with no command/control/option modifier.")
            return false
        }

        installHandlerIfNeeded()

        var reference: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(
            binding.keyCode,
            binding.carbonModifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &reference
        )

        guard status == noErr, let reference else {
            Log.app.error("RegisterEventHotKey failed with status \(status).")
            return false
        }

        hotKeyRef = reference
        self.binding = binding
        Log.app.info("Registered hotkey \(binding.displayString, privacy: .public).")
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        binding = nil
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // Non-capturing, so it converts to a C function pointer. The manager is
        // passed through userData; Carbon delivers this on the main run loop.
        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { manager.onFire?() }
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
    }
}
