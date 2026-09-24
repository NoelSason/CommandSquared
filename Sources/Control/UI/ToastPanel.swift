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
    private var activityMonitors: [Any] = []
    private var appSwitchObserver: NSObjectProtocol?

    /// - Parameter duration: how long it stays when nothing happens. Longer for
    ///   "working on it", which the result replaces; any activity still clears it.
    func show(
        title: String,
        detail: String,
        symbol: String,
        tone: ToastTone,
        near anchor: NSRect?,
        footnote: String? = nil,
        duration: Duration = .milliseconds(1800)
    ) {
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

        watchForActivity()

        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    /// The toast is a floating window pinned to a screen position, so it does not
    /// move when the page scrolls and cannot be clicked away — it ignores mouse
    /// events by design, so clicks reach the field underneath. That makes it the
    /// toast's own job to get out of the way the moment the user does anything.
    private func watchForActivity() {
        stopWatching()

        let dismissOnActivity: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }

        for mask in [NSEvent.EventTypeMask.scrollWheel,
                     .keyDown,
                     .leftMouseDown,
                     .rightMouseDown] {
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: dismissOnActivity) {
                activityMonitors.append(monitor)
            }
            // Local too, in case the click lands on one of Control's own windows.
            if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
                dismissOnActivity(event)
                return event
            }) {
                activityMonitors.append(monitor)
            }
        }

        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    private func stopWatching() {
        for monitor in activityMonitors { NSEvent.removeMonitor(monitor) }
        activityMonitors.removeAll()
        if let appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appSwitchObserver)
        }
        appSwitchObserver = nil
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        stopWatching()
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
