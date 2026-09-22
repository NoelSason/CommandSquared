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
    private let suggester: InlineSuggester

    private var menuBar: MenuBarController?
    private var settingsWindow: SettingsWindowController?
    private var inspectorWindow: FieldInspectorController?

    override init() {
        let vault = VaultStore()
        let cache = MatchCache()
        self.vault = vault
        self.cache = cache
        fillController = FillController(vault: vault, cache: cache, preferences: preferences)
        suggester = InlineSuggester(vault: vault, cache: cache, preferences: preferences)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        retireOtherInstances()
        installMainMenu()
        cache.prune(validKeys: Set(vault.fields.map(\.key)))

        let menuBar = MenuBarController(preferences: preferences)
        menuBar.onFillNow = { [weak self] in self?.fire() }
        menuBar.onOpenSettings = { [weak self] in self?.showSettings() }
        menuBar.onOpenInspector = { [weak self] in self?.showInspector() }
        menuBar.onGrantAccess = { [weak self] in self?.requestAccess() }
        menuBar.activeProfileID = { [weak self] in self?.vault.activeProfileID ?? VaultProfile.defaultID }
        menuBar.onSelectProfile = { [weak self] id in
            guard let self else { return }
            vault.activeProfileID = id
            preferences.activeProfileID = id
        }
        self.menuBar = menuBar

        hotkey.onFire = { [weak self] in self?.fire() }
        doubleTap.onFire = { [weak self] in self?.fire() }
        fillController.suggester = suggester
        installTrigger()
        installSuggester()

        if !PermissionsGate.isGranted {
            // First run with no permission: the app is inert until this is fixed,
            // so say so up front rather than letting the first hotkey press fail.
            showSettings()
        }

        Log.app.info("Control launched. Accessibility trusted: \(PermissionsGate.isGranted, privacy: .public)")
    }

    /// Two copies of a menu-bar app means two hotkey handlers, two suggesters,
    /// and text inserted twice — with no window to make it obvious. The newest
    /// launch wins, since that is the one the user just asked for.
    private func retireOtherInstances() {
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier && $0.processIdentifier != me
        }
        guard !others.isEmpty else { return }

        Log.app.info("Retiring \(others.count) older instance(s).")
        for instance in others { instance.terminate() }
    }

    /// A menu-bar-only app gets no main menu, and ⌘X/⌘C/⌘V in AppKit are routed
    /// through the Edit menu's items — so without one, you cannot paste into
    /// Control's own text fields. The menu is never drawn; it exists purely so the
    /// standard editing shortcuts have somewhere to go.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Control", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        let entries: [(String, String, String)] = [
            ("Undo", "undo:", "z"),
            ("Redo", "redo:", "Z"),
            ("", "", ""),
            ("Cut", "cut:", "x"),
            ("Copy", "copy:", "c"),
            ("Paste", "paste:", "v"),
            ("Select All", "selectAll:", "a"),
        ]
        for (title, selector, key) in entries {
            if title.isEmpty {
                editMenu.addItem(.separator())
            } else {
                editMenu.addItem(withTitle: title, action: Selector((selector)), keyEquivalent: key)
            }
        }
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: Actions

    func installSuggester() {
        if preferences.inlineSuggestionsEnabled {
            suggester.start()
        } else {
            suggester.stop()
        }
    }

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
                onTriggerChanged: { [weak self] in
                    self?.installTrigger()
                    self?.installSuggester()
                }
            )
        }
        // Order the window front first, then activate. The other way round, a
        // menu-bar-only app opens the window behind whatever is in front and it
        // looks like the click did nothing — so you click again.
        settingsWindow?.show()
        NSApp.activate(ignoringOtherApps: true)
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
        inspectorWindow?.show()
        NSApp.activate(ignoringOtherApps: true)
    }
}
