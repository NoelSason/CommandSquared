import AppKit
import ControlKit
import Foundation

/// Accessibility access is the whole ballgame — without it Control cannot read a
/// label or write a value, and every failure mode looks like a bug instead of a
/// missing permission. So the state is surfaced everywhere: menu bar, settings,
/// and the toast the hotkey shows.
@MainActor
enum PermissionsGate {
    static var isGranted: Bool { AX.isTrusted }

    /// Triggers the system prompt. Only call this from an explicit user action —
    /// an unexplained permission dialog at launch is how apps get force-quit.
    static func request() {
        AX.requestTrust()
    }

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Polls until access is granted, so the UI can flip the moment the user
    /// toggles the switch in System Settings. There is no notification for this.
    static func waitForGrant(timeout: Duration = .seconds(120)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if isGranted { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return isGranted
    }
}
