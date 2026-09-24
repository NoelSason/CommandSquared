import Foundation
import Observation

/// User-facing settings. Everything here is non-secret except the Jev and Claude
/// API keys and the "About you" text for drafting, which live in the Keychain
/// under their own service.
@MainActor
@Observable
public final class Preferences {
    private enum Key {
        static let triggerMode = "triggerMode"
        static let activeProfile = "activeProfile"
        static let profileByDomain = "profileByDomain"
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let deniedBundleIDs = "deniedBundleIDs"
        static let deniedDomains = "deniedDomains"
        static let jevEnabled = "jevEnabled"
        static let inlineSuggestions = "inlineSuggestions"
        static let autoInsertEnabled = "autoInsertEnabled"
        static let confirmedCategories = "confirmedCategories"
        static let onboardingCompleted = "onboardingCompleted"
        static let draftAnswersEnabled = "draftAnswersEnabled"
        static let learnFromAnswers = "learnFromAnswers"
        static let usageByMonth = "usageByMonth"
        static let reuseAnswers = "reuseAnswers"
    }

    /// Keychain account for the API key.
    private static let apiKeyAccount = "jev_api_key"
    private static let claudeKeyAccount = "claude_api_key"
    private static let aboutYouAccount = "about_you"
    private static let learnedFactsAccount = "learned_facts"
    private static let savedAnswersAccount = "saved_answers"
    /// The least recently used go first past this.
    public static let maxSavedAnswers = 200
    /// Oldest go first past this. Every draft carries the whole list.
    public static let maxLearnedFacts = 150

    /// Where the Jev key lives: its own service, stored on this Mac only.
    ///
    /// Builds before this one kept it under the vault's service, despite a
    /// comment saying otherwise. That counted it as a saved detail, let "Clear
    /// and start over" delete it, and would have synced it along with the vault.
    public static let settingsService = "com.noelsason.Control.settings"

    private let defaults: UserDefaults
    private let settingsService: String
    /// Where older builds put the key. Read as a fallback until it has moved.
    private let legacyKeyService: String

    public init(
        defaults: UserDefaults = .standard,
        settingsService: String = Preferences.settingsService,
        legacyKeyService: String = Keychain.service
    ) {
        self.defaults = defaults
        self.settingsService = settingsService
        self.legacyKeyService = legacyKeyService
        defaults.register(defaults: [
            Key.triggerMode: TriggerMode.doubleCommand.rawValue,
            Key.hotKeyCode: 9,               // V
            Key.hotKeyModifiers: 1_310_720,  // NSEvent .control | .command
            Key.jevEnabled: true,
            Key.draftAnswersEnabled: true,
            Key.reuseAnswers: true,
            Key.inlineSuggestions: true,
            Key.autoInsertEnabled: true,
            Key.confirmedCategories: [VaultCategory.payment.rawValue],
        ])
    }

    // MARK: Setup

    /// Set once first-run setup has been finished or closed. Setup stays
    /// reachable from the menu either way.
    public var onboardingCompleted: Bool {
        get { defaults.bool(forKey: Key.onboardingCompleted) }
        set { defaults.set(newValue, forKey: Key.onboardingCompleted) }
    }

    // MARK: Profiles

    public var activeProfileID: String {
        get { defaults.string(forKey: Key.activeProfile) ?? VaultProfile.defaultID }
        set { defaults.set(newValue, forKey: Key.activeProfile) }
    }

    /// Which profile a site last used. Learned rather than configured — the same
    /// bet the match cache makes, and for the same reason: nobody is going to
    /// maintain a per-site list by hand, but everybody will pick the right one
    /// once when it matters.
    public var profileByDomain: [String: String] {
        get { defaults.dictionary(forKey: Key.profileByDomain) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Key.profileByDomain) }
    }

    public func profile(for context: FieldContext) -> String? {
        guard let domain = context.domain?.lowercased() else { return nil }
        let learned = profileByDomain
        if let exact = learned[domain] { return exact }
        // A profile chosen on one part of a university's site applies across it.
        return learned.first { domain.hasSuffix("." + $0.key) }?.value
    }

    public func rememberProfile(_ profileID: String, for context: FieldContext) {
        guard let domain = context.domain?.lowercased() else { return }
        var learned = profileByDomain
        learned[domain] = profileID
        profileByDomain = learned
    }

    public func forgetProfile(for domain: String) {
        var learned = profileByDomain
        learned.removeValue(forKey: domain)
        profileByDomain = learned
    }

    // MARK: Trigger

    public var triggerMode: TriggerMode {
        get { TriggerMode(rawValue: defaults.string(forKey: Key.triggerMode) ?? "") ?? .doubleCommand }
        set { defaults.set(newValue.rawValue, forKey: Key.triggerMode) }
    }

    // MARK: Hotkey

    public var hotKeyCode: Int {
        get { defaults.integer(forKey: Key.hotKeyCode) }
        set { defaults.set(newValue, forKey: Key.hotKeyCode) }
    }

    public var hotKeyModifiers: Int {
        get { defaults.integer(forKey: Key.hotKeyModifiers) }
        set { defaults.set(newValue, forKey: Key.hotKeyModifiers) }
    }

    // MARK: Behaviour

    /// When false, every match is confirmed in the HUD before it lands.
    public var autoInsertEnabled: Bool {
        get { defaults.bool(forKey: Key.autoInsertEnabled) }
        set { defaults.set(newValue, forKey: Key.autoInsertEnabled) }
    }

    /// Complete a field as you type, before the trigger is ever pressed.
    public var inlineSuggestionsEnabled: Bool {
        get { defaults.bool(forKey: Key.inlineSuggestions) }
        set { defaults.set(newValue, forKey: Key.inlineSuggestions) }
    }

    /// When false, matching stops at the local rules and never reaches the network.
    public var jevEnabled: Bool {
        get { defaults.bool(forKey: Key.jevEnabled) }
        set { defaults.set(newValue, forKey: Key.jevEnabled) }
    }

    /// Categories that always require confirmation no matter how confident the match.
    public var confirmedCategories: Set<VaultCategory> {
        get {
            let raw = defaults.stringArray(forKey: Key.confirmedCategories) ?? []
            return Set(raw.compactMap(VaultCategory.init(rawValue:)))
        }
        set { defaults.set(newValue.map(\.rawValue).sorted(), forKey: Key.confirmedCategories) }
    }

    // MARK: Denylist

    public var deniedBundleIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.deniedBundleIDs) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Key.deniedBundleIDs) }
    }

    public var deniedDomains: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.deniedDomains) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Key.deniedDomains) }
    }

    public func isDenied(_ context: FieldContext) -> Bool {
        if deniedBundleIDs.contains(context.bundleID) { return true }
        guard let domain = context.domain?.lowercased() else { return false }
        return deniedDomains.contains { denied in
            domain == denied || domain.hasSuffix("." + denied)
        }
    }

    // MARK: Jev API key

    /// Non-nil when the last attempt to store a key failed. Swallowing this is
    /// how a key silently fails to save and everything downstream looks broken
    /// for reasons that have nothing to do with it.
    public private(set) var jevKeyError: String?

    /// The key, from its own place first and from where older builds kept it
    /// second, so it keeps working whether or not it has moved yet.
    ///
    /// A read that *fails* — as opposed to finding nothing — used to become ""
    /// and silently switch Jev off. It now says why.
    public var jevAPIKey: String {
        get {
            do {
                if let key = try Keychain.get(Self.apiKeyAccount, service: settingsService) { return key }
                return try Keychain.get(Self.apiKeyAccount, service: legacyKeyService) ?? ""
            } catch {
                jevKeyError = "Couldn't read the Jev key: \(error.localizedDescription)"
                Log.app.error("Could not read the Jev key: \(error.localizedDescription, privacy: .public)")
                return ""
            }
        }
        set {
            do {
                if newValue.isEmpty {
                    try Keychain.delete(Self.apiKeyAccount, service: settingsService)
                } else {
                    try Keychain.set(newValue, for: Self.apiKeyAccount, sensitive: false, deviceOnly: true,
                                     service: settingsService)
                }
                // Whatever an older build left behind is superseded either way.
                try Keychain.delete(Self.apiKeyAccount, service: legacyKeyService)
                jevKeyError = nil
            } catch {
                jevKeyError = error.localizedDescription
                Log.app.error("Could not store the Jev key: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Read by the settings view on every redraw, so it only looks — a failure
    /// to look shows as "not set", and the next real read reports the error.
    public var hasJevKey: Bool {
        let here = (try? Keychain.storedAccounts(service: settingsService)) ?? []
        let legacy = (try? Keychain.storedAccounts(service: legacyKeyService)) ?? []
        return here.contains(Self.apiKeyAccount) || legacy.contains(Self.apiKeyAccount)
    }

    /// Moves a key stored by an older build into its own service: copy, read
    /// back, and only then delete the old one. A failure at any step leaves the
    /// key where it was, still working, and is retried on the next launch.
    public func migrateJevKeyIfNeeded() {
        do {
            guard let legacy = try Keychain.get(Self.apiKeyAccount, service: legacyKeyService) else { return }
            if try Keychain.get(Self.apiKeyAccount, service: settingsService) == nil {
                try Keychain.set(legacy, for: Self.apiKeyAccount, sensitive: false, deviceOnly: true,
                                 service: settingsService)
                guard try Keychain.get(Self.apiKeyAccount, service: settingsService) == legacy else {
                    Log.app.error("The Jev key did not read back after moving; leaving the original in place.")
                    return
                }
            }
            try Keychain.delete(Self.apiKeyAccount, service: legacyKeyService)
            Log.app.info("Moved the Jev key to its own keychain service.")
        } catch {
            Log.app.error("Could not move the Jev key: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Long answers

    /// Draft answers to open-ended questions. Takes effect only once a Claude
    /// key and some "About you" text are saved too; see `canDraftAnswers`.
    public var draftAnswersEnabled: Bool {
        get { defaults.bool(forKey: Key.draftAnswersEnabled) }
        set { defaults.set(newValue, forKey: Key.draftAnswersEnabled) }
    }

    /// Non-nil when the last read or write of the Claude key or the "About you"
    /// text failed, for the same reason as `jevKeyError`.
    public private(set) var draftSettingsError: String?

    public var claudeAPIKey: String {
        get { readSetting(Self.claudeKeyAccount, what: "the Claude key") }
        set { writeSetting(newValue, Self.claudeKeyAccount, what: "the Claude key") }
    }

    /// What the user has told Control about themselves, for drafting.
    ///
    /// Unlike a vault value this *does* leave the Mac — to Claude, with the
    /// question, each time a draft is asked for — so it is not a vault field. It
    /// lives with the settings, on this Mac only, and survives "Clear and start
    /// over", which is about saved details.
    public var aboutYou: String {
        get { readSetting(Self.aboutYouAccount, what: "your About you text") }
        set { writeSetting(newValue, Self.aboutYouAccount, what: "your About you text") }
    }

    /// Only looks, like `hasJevKey`, so the settings view can call it freely.
    public var hasClaudeKey: Bool { settingsAccounts.contains(Self.claudeKeyAccount) }
    public var hasAboutYou: Bool { settingsAccounts.contains(Self.aboutYouAccount) }

    public var canDraftAnswers: Bool {
        guard draftAnswersEnabled else { return false }
        let stored = settingsAccounts
        return stored.contains(Self.claudeKeyAccount) && stored.contains(Self.aboutYouAccount)
    }

    /// Remember things from answers typed into form questions, for future
    /// drafts. Off until the user turns it on: it sends what they typed.
    public var learnFromAnswers: Bool {
        get { defaults.bool(forKey: Key.learnFromAnswers) }
        set { defaults.set(newValue, forKey: Key.learnFromAnswers) }
    }

    /// Learning needs everything drafting needs, since it feeds drafting.
    public var canLearnFromAnswers: Bool { learnFromAnswers && canDraftAnswers }

    /// What Control has learned, oldest first. Kept like "About you": in the
    /// Keychain, on this Mac only, apart from saved details.
    public var learnedFacts: [LearnedFact] {
        get {
            let stored = readSetting(Self.learnedFactsAccount, what: "what Control has learned")
            guard !stored.isEmpty else { return [] }
            do {
                return try JSONDecoder().decode([LearnedFact].self, from: Data(stored.utf8))
            } catch {
                draftSettingsError = "Couldn't read what Control has learned: \(error.localizedDescription)"
                return []
            }
        }
        set {
            let kept = Array(newValue.suffix(Self.maxLearnedFacts))
            guard !kept.isEmpty else {
                writeSetting("", Self.learnedFactsAccount, what: "what Control has learned")
                return
            }
            do {
                let data = try JSONEncoder().encode(kept)
                writeSetting(String(decoding: data, as: UTF8.self), Self.learnedFactsAccount, what: "what Control has learned")
            } catch {
                draftSettingsError = "Couldn't save what Control has learned: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Saved answers

    /// Use a saved answer when a question asks the same thing again, instead
    /// of drafting a new one.
    public var reuseAnswers: Bool {
        get { defaults.bool(forKey: Key.reuseAnswers) }
        set { defaults.set(newValue, forKey: Key.reuseAnswers) }
    }

    /// Answers Control drafted, as the user left them. The user's own writing,
    /// so kept like "About you": in the Keychain, on this Mac only.
    public var savedAnswers: [SavedAnswer] {
        get {
            let stored = readSetting(Self.savedAnswersAccount, what: "your saved answers")
            guard !stored.isEmpty else { return [] }
            do {
                return try JSONDecoder().decode([SavedAnswer].self, from: Data(stored.utf8))
            } catch {
                draftSettingsError = "Couldn't read your saved answers: \(error.localizedDescription)"
                return []
            }
        }
        set {
            let kept = Array(newValue.sorted { $0.updatedAt < $1.updatedAt }.suffix(Self.maxSavedAnswers))
            guard !kept.isEmpty else {
                writeSetting("", Self.savedAnswersAccount, what: "your saved answers")
                return
            }
            do {
                let data = try JSONEncoder().encode(kept)
                writeSetting(String(decoding: data, as: UTF8.self), Self.savedAnswersAccount, what: "your saved answers")
            } catch {
                draftSettingsError = "Couldn't save your answers: \(error.localizedDescription)"
            }
        }
    }

    /// Records the final text of an answer. An answer already saved under this
    /// id takes the new text, and learns the question's wording if it's new.
    public func saveAnswer(id: UUID, question: String, text: String, site: String?, at date: Date = Date()) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var library = savedAnswers
        if let index = library.firstIndex(where: { $0.id == id }) {
            library[index].text = text
            library[index].updatedAt = date
            let wording = AnswerLibrary.comparable(question)
            if !question.isEmpty, !library[index].questions.contains(where: { AnswerLibrary.comparable($0) == wording }) {
                library[index].questions.append(question)
            }
        } else {
            library.append(SavedAnswer(id: id, questions: question.isEmpty ? [] : [question], text: text,
                                       site: site, updatedAt: date))
        }
        savedAnswers = library
    }

    // MARK: What it costs

    /// One month's use of Claude: drafts written, answers checked, and an
    /// estimate of what they cost at list price.
    public struct MonthlyUsage: Codable, Sendable, Equatable {
        public var drafts = 0
        public var answersChecked = 0
        public var dollars = 0.0

        public init(drafts: Int = 0, answersChecked: Int = 0, dollars: Double = 0) {
            self.drafts = drafts
            self.answersChecked = answersChecked
            self.dollars = dollars
        }
    }

    public enum UsageKind: Sendable {
        case draft
        case answerCheck
    }

    /// Counts and costs only; never what was written.
    public func recordUsage(_ kind: UsageKind, dollars: Double, on date: Date = Date()) {
        var ledger = usageLedger
        let month = Self.monthKey(for: date)
        var entry = ledger[month] ?? MonthlyUsage()
        switch kind {
        case .draft: entry.drafts += 1
        case .answerCheck: entry.answersChecked += 1
        }
        entry.dollars += dollars
        ledger[month] = entry
        // A year is plenty to look back on.
        for key in ledger.keys.sorted().dropLast(12) { ledger.removeValue(forKey: key) }
        if let data = try? JSONEncoder().encode(ledger) { defaults.set(data, forKey: Key.usageByMonth) }
    }

    public func usage(in date: Date = Date()) -> MonthlyUsage {
        usageLedger[Self.monthKey(for: date)] ?? MonthlyUsage()
    }

    private var usageLedger: [String: MonthlyUsage] {
        guard let data = defaults.data(forKey: Key.usageByMonth) else { return [:] }
        return (try? JSONDecoder().decode([String: MonthlyUsage].self, from: data)) ?? [:]
    }

    static func monthKey(for date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    private var settingsAccounts: Set<String> {
        (try? Keychain.storedAccounts(service: settingsService)) ?? []
    }

    private func readSetting(_ account: String, what: String) -> String {
        do {
            return try Keychain.get(account, service: settingsService) ?? ""
        } catch {
            draftSettingsError = "Couldn't read \(what): \(error.localizedDescription)"
            Log.app.error("Could not read \(account, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return ""
        }
    }

    /// Blank means remove, so "is there one" stays a question about presence.
    private func writeSetting(_ value: String, _ account: String, what: String) {
        do {
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try Keychain.delete(account, service: settingsService)
            } else {
                try Keychain.set(value, for: account, sensitive: false, deviceOnly: true, service: settingsService)
            }
            draftSettingsError = nil
        } catch {
            draftSettingsError = "Couldn't save \(what): \(error.localizedDescription)"
            Log.app.error("Could not store \(account, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
