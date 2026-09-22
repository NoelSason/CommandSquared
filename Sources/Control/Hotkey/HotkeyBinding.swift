import AppKit
import Carbon.HIToolbox
import Foundation

/// A key combination, stored as an `NSEvent`-style modifier mask (what the
/// recorder UI produces) and translated to Carbon's mask on registration.
struct HotkeyBinding: Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: NSEvent.ModifierFlags

    /// ⌃⌘V — "Control's paste".
    ///
    /// Space is a bad neighbourhood: ⌘Space is Spotlight, ⌃Space and ⌃⌥Space
    /// switch input sources, ⌃⌘Space is the character picker, and ⌘⇧Space opens
    /// the system text-actions panel (Ask Siri / Image Search). That last one
    /// takes keyboard focus when it appears, so the field Control was asked to
    /// fill is no longer focused by the time it looks — it fails *and* reports
    /// the failure accurately, which reads like a bug in Control.
    static let `default` = HotkeyBinding(
        keyCode: UInt32(kVK_ANSI_V),
        modifiers: [.control, .command]
    )

    var carbonModifiers: UInt32 {
        var mask: UInt32 = 0
        if modifiers.contains(.command) { mask |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { mask |= UInt32(shiftKey) }
        if modifiers.contains(.option) { mask |= UInt32(optionKey) }
        if modifiers.contains(.control) { mask |= UInt32(controlKey) }
        return mask
    }

    var isValid: Bool {
        // A bare key, or a key with only shift, would fire while typing.
        !modifiers.intersection([.command, .control, .option]).isEmpty
    }

    var displayString: String {
        var parts = ""
        if modifiers.contains(.control) { parts += "⌃" }
        if modifiers.contains(.option) { parts += "⌥" }
        if modifiers.contains(.shift) { parts += "⇧" }
        if modifiers.contains(.command) { parts += "⌘" }
        return parts + Self.keyName(for: keyCode)
    }

    static func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Space: "Space"
        case kVK_Return: "Return"
        case kVK_Tab: "Tab"
        case kVK_Escape: "Esc"
        case kVK_ANSI_Period: "."
        case kVK_ANSI_Comma: ","
        case kVK_ANSI_Slash: "/"
        case kVK_ANSI_Semicolon: ";"
        case kVK_ANSI_Quote: "'"
        case kVK_ANSI_Backslash: "\\"
        default: literalKeyName(for: keyCode) ?? "Key \(keyCode)"
        }
    }

    /// Asks the current keyboard layout what the key produces, so the settings
    /// window shows the right letter on a non-QWERTY layout.
    private static func literalKeyName(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)

        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }

        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}
