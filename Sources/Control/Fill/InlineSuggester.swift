import AppKit
import ApplicationServices
import ControlKit
import Foundation

/// Offers to complete a field as you type, the way an address bar does — and
/// never touches the field until you say so.
///
/// The suggestion is shown in a small hint beside the field. Nothing is written
/// while you type:
///
///   - keep typing  → the hint goes, and a fresh one may follow your next pause
///   - Tab          → the suggestion is filled in (Tab is taken only while the
///                    hint is up; see `TabInterceptor`)
///   - the trigger  → the same, for when Tab can't be taken
///
/// An earlier version wrote each suggestion into the field as selected text
/// while the user was still typing. Writing the whole value into a field
/// someone is typing into races their next keystroke, and in web forms it also
/// goes behind the page's back — so correctly typed text came out mangled.
@MainActor
final class InlineSuggester {
    /// What is on offer: the field, what it held when the offer was made, and
    /// the stored value that would complete it.
    private struct Offer {
        let element: AXUIElement
        let typed: String
        let value: String
        /// Where the typed text ends inside `value`; see `CompletionMatcher`.
        let matchEnd: Int
    }

    /// Long enough to read the hint and decide; short enough that a Tab much
    /// later still means "next field".
    private static let offerLifetime: Duration = .seconds(8)

    private var keyMonitor: Any?
    private var dismissMonitor: Any?
    private var appSwitchObserver: NSObjectProtocol?
    private var debounce: Task<Void, Never>?
    private var expiry: Task<Void, Never>?

    /// The element we last computed candidates for, so the expensive context read
    /// happens once per field rather than once per keystroke.
    private var cachedElement: AXUIElement?
    private var cachedContext: FieldContext?
    private var candidates: [String] = []
    private var offer: Offer?

    private let hint = SuggestionHintPresenter()
    private let tab = TabInterceptor()

    private let vault: VaultStore
    private let cache: MatchCache
    private let preferences: Preferences
    private let matcher = LocalMatcher()

    init(vault: VaultStore, cache: MatchCache, preferences: Preferences) {
        self.vault = vault
        self.cache = cache
        self.preferences = preferences
        tab.onTab = { [weak self] in
            Task { await self?.accept(viaTab: true) }
        }
    }

    var hasActiveSuggestion: Bool { offer != nil }

    // MARK: Lifecycle

    func start() {
        stop()
        tab.install()
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.keyPressed(event) }
        }
    }

    func stop() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        debounce?.cancel()
        debounce = nil
        withdraw()
        tab.uninstall()
        cachedElement = nil
        cachedContext = nil
        candidates = []
    }

    // MARK: Typing

    private func keyPressed(_ event: NSEvent) {
        // Whatever was on offer was for the text before this key.
        withdraw()
        debounce?.cancel()

        // Any modifier chord is a command, not typing.
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return }

        debounce = Task { [weak self] in
            try? await Task.sleep(for: SuggestionPolicy.idleBeforeSuggesting)
            guard !Task.isCancelled else { return }
            await self?.suggest()
        }
    }

    /// Works out an offer and shows it. Reads the field; never writes to it.
    private func suggest() async {
        guard AX.isTrusted else { return }
        let systemWide = AXUIElementCreateSystemWide()
        guard let element = AX.element(systemWide, kAXFocusedUIElementAttribute) else {
            cachedElement = nil
            return
        }

        let typed = AX.rawValue(element, kAXValueAttribute) ?? ""

        if cachedElement == nil || !AX.same(cachedElement!, element) {
            await rebuildCandidates(for: element)
            // The user may have typed again while the field was being read.
            guard !Task.isCancelled else { return }
        }
        guard let context = cachedContext, !candidates.isEmpty else { return }

        // Whether this field may be completed at all is decided in ControlKit.
        if let refusal = SuggestionPolicy.refusal(
            context: context,
            isDenied: preferences.isDenied(context),
            typed: typed,
            caretAtEnd: caretIsAtEnd(of: element, length: typed.count)
        ) {
            Log.match.debug("No suggestion: \(refusal.rawValue, privacy: .public)")
            return
        }

        guard let offer = firstOffer(in: element, typed: typed, context: context),
              AX.rawValue(element, kAXValueAttribute) == typed
        else { return }
        present(offer)
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

    /// The best candidate whose stored value continues what was typed. An
    /// unreadable value is simply not offered.
    private func firstOffer(in element: AXUIElement, typed: String, context: FieldContext) -> Offer? {
        for candidate in candidates {
            guard let value = try? vault.resolvedValue(for: candidate, context: context),
                  !value.isEmpty,
                  let matchEnd = CompletionMatcher.matchEnd(of: typed, in: value)
            else { continue }
            return Offer(element: element, typed: typed, value: value, matchEnd: matchEnd)
        }
        return nil
    }

    // MARK: The hint

    private func present(_ offer: Offer) {
        self.offer = offer
        if tab.isAvailable { tab.arm() }
        hint.show(
            value: offer.value,
            key: tab.isAvailable ? "Tab" : triggerKey,
            near: AX.frame(offer.element)
        )

        // Clicking, scrolling or switching away means the user has moved on.
        dismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .scrollWheel]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.withdraw() }
        }
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.withdraw() }
        }
        expiry = Task { [weak self] in
            try? await Task.sleep(for: Self.offerLifetime)
            guard !Task.isCancelled else { return }
            self?.withdraw()
        }
    }

    /// Takes the offer down, and gives Tab back.
    private func withdraw() {
        offer = nil
        tab.disarm()
        hint.hide()
        expiry?.cancel()
        expiry = nil
        if let dismissMonitor { NSEvent.removeMonitor(dismissMonitor) }
        dismissMonitor = nil
        if let appSwitchObserver { NSWorkspace.shared.notificationCenter.removeObserver(appSwitchObserver) }
        appSwitchObserver = nil
    }

    /// The trigger, as the hint names it when Tab can't be taken.
    private var triggerKey: String {
        switch preferences.triggerMode {
        case .doubleCommand: "⌘⌘"
        case .doubleControl: "⌃⌃"
        case .chord: preferences.triggerDescription
        }
    }

    // MARK: Filling

    /// Called when the trigger fires. With a suggestion showing, the trigger
    /// fills it in; otherwise it's an ordinary fill.
    func acceptFromTrigger() async -> Bool {
        guard offer != nil else { return false }
        await accept(viaTab: false)
        return true
    }

    /// Fills the offer in — only if the field is still the one it was made for
    /// and still holds exactly what it did. A Tab that can't be used is put back.
    private func accept(viaTab: Bool) async {
        guard let offer else {
            if viaTab { TabInterceptor.repostTab() }
            return
        }
        withdraw()

        let systemWide = AXUIElementCreateSystemWide()
        guard let focused = AX.element(systemWide, kAXFocusedUIElementAttribute),
              AX.same(focused, offer.element),
              AX.rawValue(offer.element, kAXValueAttribute) == offer.typed
        else {
            if viaTab { TabInterceptor.repostTab() }
            return
        }

        let text = replaceTyped(offer) ? offer.value : String(offer.value.dropFirst(offer.matchEnd))
        guard let strategy = await TextInserter.insert(text, into: offer.element, allowClipboard: true) else {
            Log.insert.error("Couldn't fill an accepted suggestion.")
            return
        }
        Log.insert.info("Filled a suggestion via \(strategy.rawValue, privacy: .public).")
    }

    /// Whether to put the whole stored value in place of what was typed, so
    /// "githu" becomes the full https URL and "NOEL" takes the stored case.
    ///
    /// Only when the typed text can be selected and the selection reads back:
    /// otherwise the rest of the value goes in after the caret, which is always
    /// safe. A plain prefix never needs replacing.
    private func replaceTyped(_ offer: Offer) -> Bool {
        guard !offer.value.hasPrefix(offer.typed) else { return false }

        var wanted = CFRange(location: 0, length: offer.typed.utf16.count)
        guard let selection = AXValueCreate(.cfRange, &wanted),
              AX.set(offer.element, kAXSelectedTextRangeAttribute, selection),
              let current = AX.copy(offer.element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(current) == AXValueGetTypeID()
        else { return false }

        var range = CFRange()
        guard AXValueGetValue(current as! AXValue, .cfRange, &range) else { return false }
        return range.location == wanted.location && range.length == wanted.length
    }
}
