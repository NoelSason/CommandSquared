import ControlKit
import Foundation
import ServiceManagement

/// Registers Control to start with the Mac.
///
/// `SMAppService` replaces the old login-item and helper-bundle dances: the app
/// registers itself, macOS shows it in System Settings → General → Login Items,
/// and the user can revoke it there. Which means the stored preference and the
/// real state can disagree, so `isEnabled` reads the system rather than trusting
/// a defaults key.
@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns whether the request was honoured. `requiresApproval` means macOS
    /// wants the user to allow it in System Settings first.
    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            Log.app.error("Launch at login \(enabled ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }
}
