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

    /// Full Disk Access has no request API — unlike Accessibility, there is no
    /// prompt an app can raise. All that can be done is open the pane. Control
    /// will already be listed there, because the denied read is what adds it.
    static func openFullDiskAccess() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }

    /// Relaunches Control. A permission granted while it is running does not
    /// apply to the running process, so this is the second half of the fix.
    ///
    /// Quits *first* and reopens afterwards, from a detached process. Opening a
    /// new instance and then terminating the old one races: press the button
    /// twice and you end up with several copies of a menu-bar app, each with its
    /// own hotkey handler.
    static func restart() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; open -a \"\(Bundle.main.bundlePath)\""]
        try? task.run()

        // `terminate` is a request, and a modal sheet can refuse it — which is
        // exactly where this button lives. Ask nicely, then stop asking. There is
        // no unsaved state here: every value is already in the Keychain.
        NSApp.terminate(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            exit(0)
        }
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
