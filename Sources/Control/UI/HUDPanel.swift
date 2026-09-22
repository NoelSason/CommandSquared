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

    enum Placement {
        /// Above the field. Covers the label of the field just filled, which the
        /// user is done with — rather than the next field, which they are not.
        case above
        /// Below the field, for the picker, which must not hide what it refers to.
        case below
    }

    /// Places the panel relative to the field it refers to, nudged back on screen
    /// when the field is near an edge.
    func position(near anchor: NSRect?, size: NSSize, placement: Placement = .below) {
        let screen = NSScreen.screens.first { $0.frame.contains(anchor?.origin ?? .zero) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else {
            setContentSize(size)
            center()
            return
        }

        setContentSize(size)

        guard let anchor else {
            let origin = NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2
            )
            setFrameOrigin(origin)
            return
        }

        let above = anchor.maxY + 6
        let below = anchor.minY - size.height - 6

        var x = anchor.minX
        var y: CGFloat
        switch placement {
        case .above:
            y = above
            if y + size.height > visible.maxY { y = below }
        case .below:
            y = below
            if y < visible.minY { y = above }
        }

        if x + size.width > visible.maxX { x = visible.maxX - size.width - 8 }
        if x < visible.minX { x = visible.minX + 8 }
        y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)
        setFrameOrigin(NSPoint(x: x, y: y))
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
