import AppKit
import ApplicationServices
import ControlKit
import Foundation

/// Completes a field as you type, the way an address bar does.
///
/// The completion is inserted as *selected* text rather than drawn as grey ghost
/// text, because the pixels inside another app's text field are not ours to draw
/// on. Selection carries the same meaning and behaves correctly for free:
///
///   - keep typing        → the selection is replaced, as with any selected text
///   - Tab, Return, click → focus leaves and the completion stays, i.e. accepted
///   - Delete             → the selection is removed, i.e. rejected
///   - ⌘⌘                 → cycle to the next candidate
///
/// That last point is why this works at all. A global event monitor can observe
/// keystrokes but cannot swallow them, so Tab could never have been intercepted.
/// Selected-text completion needs no interception: every key already does the
/// right thing.
@MainActor
final class InlineSuggester {
    private var keyMonitor: Any?
    private var debounce: Task<Void, Never>?

    /// The element we last computed candidates for, so the expensive context read
    /// happens once per field rather than once per keystroke.
    private var cachedElement: AXUIElement?
    private var cachedContext: FieldContext?
    private var candidates: [String] = []
    private var candidateIndex = 0

    /// What we last wrote, so our own edit is not mistaken for the user's.
    private var suggestedValue: String?
    private var typedPrefix: String?

    private let vault: VaultStore
    private let cache: MatchCache
    private let preferences: Preferences
    private let matcher = LocalMatcher()

    init(vault: VaultStore, cache: MatchCache, preferences: Preferences) {
        self.vault = vault
        self.cache = cache
        self.preferences = preferences
    }

    var hasActiveSuggestion: Bool { suggestedValue != nil }

    // MARK: Lifecycle

    func start() {
        stop()
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.keyPressed(event) }
        }
    }

    func stop() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        debounce?.cancel()
        debounce = nil
        clearState()
    }

    private func clearState() {
        cachedElement = nil
        cachedContext = nil
        candidates = []
        candidateIndex = 0
        suggestedValue = nil
        typedPrefix = nil
    }

    // MARK: Typing

    private func keyPressed(_ event: NSEvent) {
        // Any modifier chord is a command, not typing.
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            suggestedValue = nil
            return
        }

        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: SuggestionPolicy.idleBeforeSuggesting)
            guard !Task.isCancelled else { return }
            await self?.suggest()
        }
    }

    private func suggest() async {
        guard AX.isTrusted else { return }
        let systemWide = AXUIElementCreateSystemWide()
        guard let element = AX.element(systemWide, kAXFocusedUIElementAttribute) else {
            clearState()
            return
        }

        let typed = (AX.rawValue(element, kAXValueAttribute) ?? "")
        // Our own completion still sitting there — leave it alone.
        guard typed != suggestedValue else { return }

        if cachedElement == nil || !AX.same(cachedElement!, element) {
            await rebuildCandidates(for: element)
        }
        guard let context = cachedContext, !candidates.isEmpty else {
            suggestedValue = nil
            return
        }

        // Whether this field may be completed at all is decided in ControlKit.
        if let refusal = SuggestionPolicy.refusal(
            context: context,
            isDenied: preferences.isDenied(context),
            typed: typed,
            caretAtEnd: caretIsAtEnd(of: element, length: typed.count)
        ) {
            Log.match.debug("No suggestion: \(refusal.rawValue, privacy: .public)")
            suggestedValue = nil
            return
        }

        typedPrefix = typed
        candidateIndex = 0
        offerCandidate(at: 0, into: element, typed: typed)
    }

    /// Only suggest when the caret sits at the end with nothing selected —
    /// completing mid-word would mangle an edit in progress.
    private func caretIsAtEnd(of element: AXUIElement, length: Int) -> Bool {
        guard let value = AX.copy(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return true }  // Unreported: assume the common case.

        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return true }
        return range.length == 0 && range.location == length
    }

    /// Reads the field once per element, then asks `SuggestionPolicy` what may be
    /// offered. The policy has no "and everything else" fallback on purpose: no
    /// opinion means no suggestion, which is what keeps this out of spreadsheets.
    private func rebuildCandidates(for element: AXUIElement) async {
        cachedElement = element
        candidates = []
        cachedContext = nil

        guard case let .success(field) = await AXFieldReader.readFocusedField() else { return }
        cachedContext = field.context

        let allowed = Set(vault.matchableFields.filter { !$0.sensitive }.map(\.key))
        candidates = SuggestionPolicy.candidates(
            learned: cache.entry(for: field.context)?.key,
            ranked: matcher.match(field.context, fillable: allowed, hints: vault.matchHints),
            allowed: allowed
        )
    }

    // MARK: Cycling

    /// Called when the trigger fires while a suggestion is on screen.
    @discardableResult
    func cycle() -> Bool {
        guard suggestedValue != nil,
              let element = cachedElement,
              let typed = typedPrefix,
              !candidates.isEmpty
        else { return false }

        for offset in 1 ... candidates.count {
            let index = (candidateIndex + offset) % candidates.count
            if offerCandidate(at: index, into: element, typed: typed) {
                candidateIndex = index
                return true
            }
        }
        return false
    }

    // MARK: Writing the completion

    @discardableResult
    private func offerCandidate(at index: Int, into element: AXUIElement, typed: String) -> Bool {
        guard candidates.indices.contains(index), let context = cachedContext else { return false }

        for offset in 0 ..< candidates.count {
            let candidate = candidates[(index + offset) % candidates.count]
            // An unreadable value is simply not suggested; nothing is inserted
            // unless the user accepts a suggestion that did read.
            guard let value = try? vault.resolvedValue(for: candidate, context: context),
                  !value.isEmpty,
                  let matchEnd = CompletionMatcher.matchEnd(of: typed, in: value)
            else { continue }

            // The whole stored value goes in — scheme and all — and only the part
            // beyond what was typed is selected. Typing "githu" therefore yields a
            // real https URL rather than a bare hostname.
            let completion = value
            guard AX.set(element, kAXValueAttribute, completion as CFTypeRef) else { return false }

            var range = CFRange(location: matchEnd, length: completion.count - matchEnd)
            if let selection = AXValueCreate(.cfRange, &range) {
                AX.set(element, kAXSelectedTextRangeAttribute, selection)
            }

            suggestedValue = completion
            candidateIndex = (index + offset) % candidates.count
            Log.match.debug("Suggested \(candidate, privacy: .public) inline.")
            return true
        }
        return false
    }
}
