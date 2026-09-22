import AppKit
import ControlKit
import SwiftUI

@main
@MainActor
enum ControlMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Menu-bar only. No Dock icon, and activating Control never steals a
        // window from whatever the user is filling out.
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = Preferences()
    private let vault: VaultStore
    private let cache: MatchCache
    private let fillController: FillController
    private let hotkey = HotkeyManager()
    private let doubleTap = DoubleTapMonitor()

    private var menuBar: MenuBarController?
    private var settingsWindow: SettingsWindowController?
    private var inspectorWindow: FieldInspectorController?

    override init() {
        let vault = VaultStore()
        let cache = MatchCache()
        self.vault = vault
        self.cache = cache
        fillController = FillController(vault: vault, cache: cache, preferences: preferences)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        cache.prune(validKeys: Set(vault.fields.map(\.key)))

        let menuBar = MenuBarController(preferences: preferences)
        menuBar.onFillNow = { [weak self] in self?.fire() }
        menuBar.onOpenSettings = { [weak self] in self?.showSettings() }
        menuBar.onOpenInspector = { [weak self] in self?.showInspector() }
        menuBar.onGrantAccess = { [weak self] in self?.requestAccess() }
        self.menuBar = menuBar

        hotkey.onFire = { [weak self] in self?.fire() }
        doubleTap.onFire = { [weak self] in self?.fire() }
        installTrigger()

        if !PermissionsGate.isGranted {
            // First run with no permission: the app is inert until this is fixed,
            // so say so up front rather than letting the first hotkey press fail.
            showSettings()
        }

        Log.app.info("Control launched. Accessibility trusted: \(PermissionsGate.isGranted, privacy: .public)")
    }

    // MARK: Actions

    private func fire() {
        Task { await fillController.handleHotkey() }
    }

    /// Only one trigger is live at a time, so switching tears the other down.
    func installTrigger() {
        hotkey.unregister()
        doubleTap.stop()

        switch preferences.triggerMode {
        case .doubleCommand:
            doubleTap.start(modifier: .command)
        case .doubleControl:
            doubleTap.start(modifier: .control)
        case .chord:
            let binding = HotkeyBinding(
                keyCode: UInt32(preferences.hotKeyCode),
                modifiers: NSEvent.ModifierFlags(rawValue: UInt(preferences.hotKeyModifiers))
            )
            if !hotkey.register(binding) {
                hotkey.register(.default)
                preferences.hotKeyCode = Int(HotkeyBinding.default.keyCode)
                preferences.hotKeyModifiers = Int(HotkeyBinding.default.modifiers.rawValue)
            }
        }
    }

    private func requestAccess() {
        PermissionsGate.request()
        PermissionsGate.openSystemSettings()
        Task {
            if await PermissionsGate.waitForGrant() {
                Log.app.info("Accessibility access granted.")
            }
        }
    }

    // MARK: Windows

    private func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(
                vault: vault,
                cache: cache,
                preferences: preferences,
                onTriggerChanged: { [weak self] in self?.installTrigger() }
            )
        }
        NSApp.activate()
        settingsWindow?.show()
    }

    private func showInspector() {
        if inspectorWindow == nil {
            let controller = FieldInspectorController()
            controller.onVisibilityChanged = { [weak self] isOpen in
                self?.fillController.inspectorIsOpen = isOpen
            }
            fillController.onInspect = { [weak controller] context, attributes in
                controller?.update(context: context, attributes: attributes)
            }
            inspectorWindow = controller
        }
        NSApp.activate()
        inspectorWindow?.show()
    }
}
