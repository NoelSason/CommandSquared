import AppKit
import SwiftUI

/// Shows what an inline suggestion would fill in, beside the field, without
/// touching the field.
///
/// Pure output, like the toast: it never takes focus and clicks pass through
/// it. The suggester decides when it comes and goes.
@MainActor
final class SuggestionHintPresenter {
    private var panel: HUDPanel?

    func show(value: String, key: String, near anchor: NSRect?) {
        let hosting = NSHostingView(rootView: SuggestionHintView(value: value, key: key))
        let size = hosting.fittingSize

        let panel = self.panel ?? HUDPanel(contentRect: NSRect(origin: .zero, size: size))
        panel.contentView = hosting
        panel.ignoresMouseEvents = true
        panel.position(near: anchor, size: size, placement: .below)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

private struct SuggestionHintView: View {
    let value: String
    let key: String

    var body: some View {
        HUDBackground {
            HStack(spacing: 8) {
                Text(value)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 320, alignment: .leading)
                Text(key)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .fixedSize()
    }
}
