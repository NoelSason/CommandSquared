import AppKit
import ControlKit

@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let preferences: Preferences

    var onFillNow: (@MainActor () -> Void)?
    var onOpenSettings: (@MainActor () -> Void)?
    var onOpenInspector: (@MainActor () -> Void)?
    var onGrantAccess: (@MainActor () -> Void)?

    init(preferences: Preferences) {
        self.preferences = preferences
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "text.insert",
            accessibilityDescription: "Control"
        )
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = MenuDelegate.shared
        MenuDelegate.shared.rebuild = { [weak self] menu in self?.rebuild(menu) }
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        if !PermissionsGate.isGranted {
            let warning = NSMenuItem(title: "Accessibility access needed", action: #selector(Actions.grant), keyEquivalent: "")
            warning.target = Actions.shared
            warning.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            menu.addItem(warning)
            menu.addItem(.separator())
        }

        let fill = NSMenuItem(title: "Fill focused field", action: #selector(Actions.fill), keyEquivalent: "")
        fill.target = Actions.shared
        menu.addItem(fill)

        let description: String
        switch preferences.triggerMode {
        case .doubleCommand, .doubleControl:
            description = preferences.triggerMode.title
        case .chord:
            description = HotkeyBinding(
                keyCode: UInt32(preferences.hotKeyCode),
                modifiers: NSEvent.ModifierFlags(rawValue: UInt(preferences.hotKeyModifiers))
            ).displayString
        }
        let shortcut = NSMenuItem(title: description, action: nil, keyEquivalent: "")
        shortcut.isEnabled = false
        menu.addItem(shortcut)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(Actions.settings), keyEquivalent: ",")
        settings.target = Actions.shared
        menu.addItem(settings)

        let inspector = NSMenuItem(title: "Field Inspector…", action: #selector(Actions.inspector), keyEquivalent: "")
        inspector.target = Actions.shared
        menu.addItem(inspector)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Control", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        Actions.shared.controller = self
    }

    // MARK: Target plumbing

    @MainActor
    final class Actions: NSObject {
        static let shared = Actions()
        weak var controller: MenuBarController?

        @objc func fill() { controller?.onFillNow?() }
        @objc func settings() { controller?.onOpenSettings?() }
        @objc func inspector() { controller?.onOpenInspector?() }
        @objc func grant() { controller?.onGrantAccess?() }
    }

    @MainActor
    final class MenuDelegate: NSObject, NSMenuDelegate {
        static let shared = MenuDelegate()
        var rebuild: ((NSMenu) -> Void)?

        func menuNeedsUpdate(_ menu: NSMenu) {
            rebuild?(menu)
        }
    }
}
