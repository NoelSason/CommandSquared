import ControlKit
import AppKit
import SwiftUI

/// A floating overlay that can take keyboard focus without activating Control.
///
/// `.nonactivatingPanel` is the whole trick: the panel becomes key and receives
/// arrow keys and Return, while the app the user is actually working in stays
/// active behind it.
final class HUDPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Places the panel relative to the field it refers to, on the display that
    /// field is actually on. All the geometry lives in `HUDPlacement`.
    func position(near anchor: NSRect?, size: NSSize, placement: HUDPlacement.Anchoring = .below) {
        setContentSize(size)

        let screens = NSScreen.screens
        let frames = screens.map(\.frame)
        let chosen = HUDPlacement.screen(
            for: anchor,
            screens: frames,
            mouse: NSEvent.mouseLocation,
            fallback: NSScreen.main?.frame ?? .zero
        )
        // `visibleFrame` excludes the menu bar and Dock, and differs per display.
        let visible = screens.first { $0.frame == chosen }?.visibleFrame ?? chosen

        setFrameOrigin(HUDPlacement.origin(
            anchor: anchor,
            size: size,
            visible: visible,
            anchoring: placement
        ))
    }
}

/// Shared chrome so the toast and the picker read as one thing.
struct HUDBackground<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
