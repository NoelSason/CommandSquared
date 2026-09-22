import CoreGraphics
import Foundation

/// Works out where a floating panel should sit.
///
/// Multi-monitor is where naive placement falls apart, and it does so quietly:
/// pick the wrong screen and the panel is clamped onto it, so it appears on the
/// main display while you are typing on the other one. All of this is geometry
/// over plain rectangles, so it can be tested for the arrangements that are
/// awkward to reproduce by hand — a display above, to the left, or with a
/// different height.
public enum HUDPlacement {
    public enum Anchoring: Sendable, Equatable {
        /// Above the field. Covers the label of the field just filled, which the
        /// user is done with, rather than the next one, which they are not.
        case above
        /// Below the field, for the picker, which must not hide what it refers to.
        case below
    }

    public static let gap: CGFloat = 6
    public static let margin: CGFloat = 8

    /// The screen a panel belongs on.
    ///
    /// Chosen by greatest overlap rather than by whether a corner happens to fall
    /// inside — a field at the very edge of a display, or one scrolled half out
    /// of view, still belongs to the display showing most of it. With nothing to
    /// anchor to, the pointer is the best available guess at where the user is
    /// looking.
    public static func screen(
        for anchor: CGRect?,
        screens: [CGRect],
        mouse: CGPoint,
        fallback: CGRect
    ) -> CGRect {
        guard !screens.isEmpty else { return fallback }

        if let anchor {
            let overlapping = screens
                .map { ($0, $0.intersection(anchor)) }
                .filter { !$0.1.isNull && !$0.1.isEmpty }
                .max { area($0.1) < area($1.1) }
            if let overlapping { return overlapping.0 }

            // Off every display — put it on whichever is nearest, not the main one.
            if let nearest = screens.min(by: { distance($0, anchor) < distance($1, anchor) }) {
                return nearest
            }
        }

        return screens.first { $0.contains(mouse) } ?? fallback
    }

    /// The panel's origin, in the same coordinate space as `anchor` and `visible`.
    public static func origin(
        anchor: CGRect?,
        size: CGSize,
        visible: CGRect,
        anchoring: Anchoring
    ) -> CGPoint {
        guard let anchor else {
            return CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        }

        let above = anchor.maxY + gap
        let below = anchor.minY - size.height - gap

        var y: CGFloat
        switch anchoring {
        case .above:
            y = above
            // No room above — flip rather than clamp, or it covers the field.
            if y + size.height > visible.maxY { y = below }
        case .below:
            y = below
            if y < visible.minY { y = above }
        }

        var x = anchor.minX
        if x + size.width > visible.maxX { x = visible.maxX - size.width - margin }
        if x < visible.minX { x = visible.minX + margin }

        y = min(max(y, visible.minY + margin), visible.maxY - size.height - margin)
        return CGPoint(x: x, y: y)
    }

    private static func area(_ rect: CGRect) -> CGFloat { rect.width * rect.height }

    private static func distance(_ screen: CGRect, _ anchor: CGRect) -> CGFloat {
        let dx = max(0, max(screen.minX - anchor.midX, anchor.midX - screen.maxX))
        let dy = max(0, max(screen.minY - anchor.midY, anchor.midY - screen.maxY))
        return dx * dx + dy * dy
    }
}
