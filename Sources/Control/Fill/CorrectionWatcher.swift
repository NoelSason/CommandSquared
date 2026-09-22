import AppKit
import ApplicationServices
import ControlKit
import Foundation

/// Watches a field after Control fills it, so that correcting it by hand teaches
/// Control the same way pressing ⌘⌘ again does.
///
/// Cycling is the explicit correction path and was always recorded. This covers
/// the implicit one: you clear the box and type the thing you actually wanted.
/// When the replacement matches another value from the vault, that is an
/// unambiguous statement about what this field is for, and it should stick.
///
/// Uses an accessibility observer rather than polling — a filled field can sit
/// there for minutes before anyone touches it, and polling that is pure waste.
@MainActor
final class CorrectionWatcher {
    /// Stop listening after this long. A correction arrives within seconds; a
    /// change an hour later is a different intent, not a correction.
    private static let window: Duration = .seconds(90)

    private var observer: AXObserver?
    private var element: AXUIElement?
    private var expiry: Task<Void, Never>?

    /// Called with the field's new contents once the user changes them.
    var onChange: (@MainActor (String) -> Void)?

    func watch(_ element: AXUIElement, pid: pid_t, ignoring filledValue: String) {
        stop()

        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let watcher = Unmanaged<CorrectionWatcher>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.valueChanged() }
        }

        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }

        let context = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(created, element, kAXValueChangedNotification as CFString, context) == .success
        else { return }

        CFRunLoopAddSource(
            CFRunLoopGetCurrent(),
            AXObserverGetRunLoopSource(created),
            .defaultMode
        )

        observer = created
        self.element = element
        lastSeen = filledValue

        expiry = Task { [weak self] in
            try? await Task.sleep(for: Self.window)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func stop() {
        if let observer, let element {
            AXObserverRemoveNotification(observer, element, kAXValueChangedNotification as CFString)
            CFRunLoopRemoveSource(
                CFRunLoopGetCurrent(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
        }
        observer = nil
        element = nil
        lastSeen = nil
        expiry?.cancel()
        expiry = nil
    }

    private var lastSeen: String?

    private func valueChanged() {
        guard let element else { return }
        let current = (AX.rawValue(element, kAXValueAttribute) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Mid-edit noise: every keystroke fires this. Only a settled, different,
        // non-empty value is worth interpreting as a correction.
        guard !current.isEmpty, current != lastSeen else { return }
        lastSeen = current
        onChange?(current)
    }
}
