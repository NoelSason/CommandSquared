import AppKit
import ControlKit
import Foundation

/// Fires when a modifier is tapped twice on its own.
///
/// Nothing in macOS binds a bare double-tap of ⌘ or ⌃, so there is nothing to
/// collide with and nothing to consume — a modifier pressed and released by
/// itself does nothing, which is exactly what makes it safe to overload. It also
/// means no chord to stretch for: one finger, twice.
///
/// The discipline that keeps it from misfiring: any key pressed while the
/// modifier is held cancels the tap. So ⌘C followed quickly by ⌘V never triggers
/// it, because both of those carry a key press.
@MainActor
final class DoubleTapMonitor {
    /// A tap held longer than this was a modifier being *used*, not tapped.
    private static let maxTapDuration: TimeInterval = 0.30
    /// Two taps further apart than this are two separate taps.
    private static let maxGapBetweenTaps: TimeInterval = 0.40

    private var flagsMonitor: Any?
    private var keyMonitor: Any?
    /// Global monitors never see events sent to Control's own windows, so
    /// these cover setup's practice box. They observe and pass every event on.
    private var localFlagsMonitor: Any?
    private var localKeyMonitor: Any?

    private var modifier: NSEvent.ModifierFlags = .command
    private var pressedAt: Date?
    private var lastTapAt: Date?
    private var keyPressedDuringHold = false

    var onFire: (@MainActor () -> Void)?

    var isRunning: Bool { flagsMonitor != nil }

    /// Global monitors only observe — they cannot swallow events — which is fine
    /// here and is why this needs no permission beyond the Accessibility access
    /// Control already requires.
    func start(modifier: NSEvent.ModifierFlags) {
        stop()
        self.modifier = modifier

        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.handleFlags(event) }
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyPressedDuringHold = true }
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.handleFlags(event) }
            return event
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.keyPressedDuringHold = true }
            return event
        }

        Log.app.info("Watching for a double-tap of \(Self.name(for: modifier), privacy: .public).")
    }

    func stop() {
        for monitor in [flagsMonitor, keyMonitor, localFlagsMonitor, localKeyMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        flagsMonitor = nil
        keyMonitor = nil
        localFlagsMonitor = nil
        localKeyMonitor = nil
        pressedAt = nil
        lastTapAt = nil
    }

    private func handleFlags(_ event: NSEvent) {
        let isDown = event.modifierFlags.contains(modifier)
        // Another modifier joined in — that's a chord, not a tap.
        let otherModifiers = event.modifierFlags
            .intersection([.command, .control, .option, .shift])
            .subtracting(modifier)

        if isDown {
            pressedAt = otherModifiers.isEmpty ? Date() : nil
            keyPressedDuringHold = false
            return
        }

        guard let pressedAt, !keyPressedDuringHold else {
            self.pressedAt = nil
            return
        }
        self.pressedAt = nil

        let now = Date()
        guard now.timeIntervalSince(pressedAt) <= Self.maxTapDuration else {
            lastTapAt = nil
            return
        }

        if let lastTapAt, now.timeIntervalSince(lastTapAt) <= Self.maxGapBetweenTaps {
            self.lastTapAt = nil
            onFire?()
        } else {
            lastTapAt = now
        }
    }

    static func name(for modifier: NSEvent.ModifierFlags) -> String {
        switch modifier {
        case .command: "⌘"
        case .control: "⌃"
        case .option: "⌥"
        case .shift: "⇧"
        default: "?"
        }
    }
}
