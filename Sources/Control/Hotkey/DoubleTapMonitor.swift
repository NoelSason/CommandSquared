import AppKit
import ControlKit
import Foundation

/// Fires when a modifier is tapped twice on its own, and separately when it is
/// tapped three times.
///
/// Nothing in macOS binds a bare double-tap of ⌘ or ⌃, so there is nothing to
/// collide with and nothing to consume — a modifier pressed and released by
/// itself does nothing, which is exactly what makes it safe to overload. It also
/// means no chord to stretch for: one finger, twice.
///
/// The discipline that keeps it from misfiring: any key pressed while the
/// modifier is held cancels the tap. So ⌘C followed quickly by ⌘V never triggers
/// it, because both of those carry a key press.
///
/// A third tap can only be told apart from a double by waiting for it. So while
/// `wantsTripleTap` says a triple would do something, the double holds back for
/// `tripleWindow` after the second tap; a third press inside it cancels the
/// double. When it says no, the double fires at once, exactly as before.
@MainActor
final class DoubleTapMonitor {
    /// A tap held longer than this was a modifier being *used*, not tapped.
    private static let maxTapDuration: TimeInterval = 0.30
    /// Two taps further apart than this are two separate taps.
    private static let maxGapBetweenTaps: TimeInterval = 0.40
    /// How long after a second tap a third press may start. Every double waits
    /// this long while triples are wanted, so it is kept short: quick triple
    /// taps leave about a tenth of a second between them.
    private static let tripleWindow: Duration = .milliseconds(250)

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
    /// The double, waiting to see whether a third tap follows.
    private var pendingDouble: Task<Void, Never>?
    /// A third press started inside the window; its release decides.
    private var thirdPressStarted = false

    var onFire: (@MainActor () -> Void)?
    var onTripleFire: (@MainActor () -> Void)?
    /// Asked at the second tap. False means fire the double without waiting.
    var wantsTripleTap: (@MainActor () -> Bool)?

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
        pendingDouble?.cancel()
        pendingDouble = nil
        thirdPressStarted = false
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
            // A third press inside the window: the double stands down until
            // this press's release says whether it was a tap.
            if let pendingDouble, otherModifiers.isEmpty {
                pendingDouble.cancel()
                self.pendingDouble = nil
                thirdPressStarted = true
            }
            return
        }

        let isThird = thirdPressStarted
        thirdPressStarted = false

        guard let pressedAt, !keyPressedDuringHold,
              Date().timeIntervalSince(pressedAt) <= Self.maxTapDuration
        else {
            self.pressedAt = nil
            lastTapAt = nil
            // The third press turned out to be a chord or a hold. The user
            // still tapped twice, so that stands.
            if isThird { onFire?() }
            return
        }
        self.pressedAt = nil
        let now = Date()

        if isThird {
            lastTapAt = nil
            onTripleFire?()
        } else if let lastTapAt, now.timeIntervalSince(lastTapAt) <= Self.maxGapBetweenTaps {
            self.lastTapAt = nil
            guard onTripleFire != nil, wantsTripleTap?() == true else {
                onFire?()
                return
            }
            pendingDouble = Task { [weak self] in
                try? await Task.sleep(for: Self.tripleWindow)
                guard !Task.isCancelled, let self else { return }
                self.pendingDouble = nil
                self.onFire?()
            }
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
