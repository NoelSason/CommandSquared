import AppKit
import SwiftUI

/// Brief confirmation of what just landed in the field.
///
/// It reports; it does not offer to undo. Undoing an insertion belongs to the app
/// that received it, and whether ⌘Z works there depends on how the text got in —
/// promising it here would be a lie a quarter of the time.
@MainActor
final class ToastPresenter {
    private var panel: HUDPanel?
    private var dismissTask: Task<Void, Never>?

    func show(title: String, detail: String, symbol: String, tone: ToastTone, near anchor: NSRect?, footnote: String? = nil) {
        dismissTask?.cancel()

        let view = ToastView(title: title, detail: detail, symbol: symbol, tone: tone, footnote: footnote)
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize

        let panel = self.panel ?? HUDPanel(contentRect: NSRect(origin: .zero, size: size))
        panel.contentView = hosting
        // Pure output: it never takes focus, and clicks pass straight through to
        // whatever is underneath, so it can never come between you and a field.
        panel.ignoresMouseEvents = true
        panel.position(near: anchor, size: size, placement: .above)
        panel.orderFrontRegardless()
        self.panel = panel

        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1300))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        panel?.orderOut(nil)
    }
}

enum ToastTone {
    case success
    case warning

    var color: Color {
        switch self {
        case .success: .accentColor
        case .warning: .orange
        }
    }
}

private struct ToastView: View {
    let title: String
    let detail: String
    let symbol: String
    let tone: ToastTone
    let footnote: String?

    var body: some View {
        HUDBackground {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tone.color)

                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let footnote {
                        Text(footnote)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minWidth: 120, alignment: .leading)
        }
        .fixedSize()
    }
}
