import AppKit
import ControlKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let vault: VaultStore
    private let cache: MatchCache
    private let preferences: Preferences
    private let onTriggerChanged: @MainActor () -> Void

    init(
        vault: VaultStore,
        cache: MatchCache,
        preferences: Preferences,
        onTriggerChanged: @escaping @MainActor () -> Void
    ) {
        self.vault = vault
        self.cache = cache
        self.preferences = preferences
        self.onTriggerChanged = onTriggerChanged
    }

    func show() {
        if window == nil {
            let root = SettingsView(
                vault: vault,
                cache: cache,
                preferences: preferences,
                onTriggerChanged: onTriggerChanged
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Control"
            window.contentView = NSHostingView(rootView: root)
            window.center()
            window.isReleasedWhenClosed = false
            self.window = window
        }
        vault.refreshFilledKeys()
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: Root

private struct SettingsView: View {
    @Bindable var vault: VaultStore
    @Bindable var cache: MatchCache
    @Bindable var preferences: Preferences
    let onTriggerChanged: @MainActor () -> Void

    var body: some View {
        TabView {
            DetailsTab(vault: vault)
                .tabItem { Label("Your details", systemImage: "person.text.rectangle") }
            ShortcutTab(preferences: preferences, onTriggerChanged: onTriggerChanged)
                .tabItem { Label("Trigger", systemImage: "command") }
            MatchingTab(preferences: preferences)
                .tabItem { Label("Matching", systemImage: "wand.and.stars") }
            PrivacyTab(preferences: preferences)
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
            MemoryTab(cache: cache, vault: vault)
                .tabItem { Label("Memory", systemImage: "clock.arrow.circlepath") }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 480)
    }
}

// MARK: Permission banner

private struct AccessBanner: View {
    @State private var granted = PermissionsGate.isGranted

    var body: some View {
        Group {
            if !granted {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Control needs Accessibility access")
                            .font(.system(size: 12, weight: .medium))
                        Text("Without it Control can't read the field you're in or type into it.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Settings") {
                        PermissionsGate.request()
                        PermissionsGate.openSystemSettings()
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            }
        }
        .task {
            while !granted {
                try? await Task.sleep(for: .milliseconds(700))
                granted = PermissionsGate.isGranted
            }
        }
    }
}

// MARK: Details

private struct DetailsTab: View {
    @Bindable var vault: VaultStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AccessBanner()
            StorageBanner(vault: vault)
            if let error = vault.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(VaultCategory.allCases) { category in
                        let fields = vault.fields(in: category).filter { !$0.isDerived }
                        if !fields.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(category.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(fields) { field in
                                    VaultFieldRow(vault: vault, field: field)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

/// Shown when saved values exist that this build cannot open.
private struct StorageBanner: View {
    @Bindable var vault: VaultStore
    @State private var confirming = false

    var body: some View {
        if !vault.unreadableKeys.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "key.slash.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(vault.unreadableKeys.count) saved details can't be opened")
                        .font(.system(size: 12, weight: .medium))
                    Text("They were saved by an earlier version of Control. Clear them and enter them again — they'll stick from now on.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(confirming ? "Really clear?" : "Clear and start over") {
                    if confirming {
                        vault.resetAllValues()
                        confirming = false
                    } else {
                        confirming = true
                    }
                }
                .tint(confirming ? .red : nil)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        }
    }
}

private struct VaultFieldRow: View {
    @Bindable var vault: VaultStore
    let field: VaultField

    @State private var text = ""
    @State private var loaded = false
    @State private var unreadable = false

    private var isFilled: Bool { vault.filledKeys.contains(field.key) }

    private var placeholder: String {
        if unreadable { return "Saved earlier — can't be opened" }
        if field.sensitive { return isFilled ? "Saved — type to replace" : "Not set" }
        return "Not set"
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(field.label)
                .font(.system(size: 12))
                .frame(width: 150, alignment: .leading)

            Group {
                if field.sensitive {
                    // Never read back: displaying it would demand Touch ID just to
                    // open this window. Typing replaces, and that's the only path.
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))
            .onSubmit { save() }

            Button {
                vault.clearValue(for: field.key)
                text = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .disabled(!isFilled)
            .help("Clear")
        }
        .onAppear(perform: load)
        .onChange(of: text) { _, _ in
            guard loaded else { return }
            save()
        }
    }

    private func load() {
        guard !loaded else { return }
        if !field.sensitive {
            switch vault.readState(for: field.key) {
            case let .value(stored): text = stored
            case .unreadable: unreadable = true
            case .empty: break
            }
        }
        loaded = true
    }

    private func save() {
        guard loaded else { return }
        if field.sensitive, text.isEmpty { return }
        vault.setValue(text, for: field.key)
    }
}

// MARK: Shortcut

private struct ShortcutTab: View {
    @Bindable var preferences: Preferences
    let onTriggerChanged: @MainActor () -> Void

    @State private var recording = false
    @State private var monitor: Any?

    private var binding: HotkeyBinding {
        HotkeyBinding(
            keyCode: UInt32(preferences.hotKeyCode),
            modifiers: NSEvent.ModifierFlags(rawValue: UInt(preferences.hotKeyModifiers))
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("How you summon Control, anywhere on your Mac.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(TriggerMode.allCases) { mode in
                    Button {
                        preferences.triggerMode = mode
                        onTriggerChanged()
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: preferences.triggerMode == mode
                                  ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(preferences.triggerMode == mode ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.title).font(.system(size: 13, weight: .medium))
                                Text(mode.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if preferences.triggerMode == .chord {
                Divider()
                HStack(spacing: 12) {
                Text(recording ? "Press a key combination…" : binding.displayString)
                    .font(.system(size: 22, weight: .medium, design: .rounded))
                    .frame(minWidth: 140)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 20)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(recording ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
                    )

                    Button(recording ? "Cancel" : "Change…") {
                        recording ? stopRecording() : startRecording()
                    }
                }

                Text("Needs ⌘, ⌃, or ⌥ in the combination — anything less would fire while you type.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .onDisappear(perform: stopRecording)
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let candidate = HotkeyBinding(
                keyCode: UInt32(event.keyCode),
                modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            )
            guard candidate.isValid else { return nil }
            preferences.hotKeyCode = Int(candidate.keyCode)
            preferences.hotKeyModifiers = Int(candidate.modifiers.rawValue)
            onTriggerChanged()
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: Matching

private struct MatchingTab: View {
    @Bindable var preferences: Preferences
    @State private var apiKey = ""
    @State private var keyLoaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Fill straight away when the match is obvious", isOn: $preferences.autoInsertEnabled)
                Text("Turn this off to confirm every fill before it lands.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Use Jev for fields Control can't work out on its own", isOn: $preferences.jevEnabled)
                HStack {
                    Text("API key")
                        .font(.system(size: 12))
                        .frame(width: 70, alignment: .leading)
                    SecureField(preferences.hasJevKey ? "Saved" : "Not set", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            preferences.jevAPIKey = apiKey
                            apiKey = ""
                        }
                }
                Text("Control sends the field's label and the names of your saved details — never their values.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Always ask before filling")
                    .font(.system(size: 12, weight: .medium))
                ForEach(VaultCategory.allCases) { category in
                    Toggle(category.title, isOn: Binding(
                        get: { preferences.confirmedCategories.contains(category) },
                        set: { isOn in
                            var set = preferences.confirmedCategories
                            if isOn { set.insert(category) } else { set.remove(category) }
                            preferences.confirmedCategories = set
                        }
                    ))
                    .font(.system(size: 12))
                }
            }

            Spacer()
        }
    }
}

// MARK: Privacy

private struct PrivacyTab: View {
    @Bindable var preferences: Preferences
    @State private var newDomain = ""
    @State private var newBundleID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Control never fills password fields.", systemImage: "lock.shield")
                    .font(.system(size: 12))
                Label("Your saved details stay on this Mac.", systemImage: "internaldrive")
                    .font(.system(size: 12))
                Label("Payment details are locked behind Touch ID every time.", systemImage: "touchid")
                    .font(.system(size: 12))
            }

            Divider()

            listEditor(
                title: "Turned off on these sites",
                placeholder: "example.com",
                text: $newDomain,
                items: preferences.deniedDomains.sorted(),
                add: { preferences.deniedDomains.insert($0.lowercased()) },
                remove: { preferences.deniedDomains.remove($0) }
            )

            listEditor(
                title: "Turned off in these apps",
                placeholder: "com.example.app",
                text: $newBundleID,
                items: preferences.deniedBundleIDs.sorted(),
                add: { preferences.deniedBundleIDs.insert($0) },
                remove: { preferences.deniedBundleIDs.remove($0) }
            )

            Spacer()
        }
    }

    @ViewBuilder
    private func listEditor(
        title: String,
        placeholder: String,
        text: Binding<String>,
        items: [String],
        add: @escaping (String) -> Void,
        remove: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
            HStack {
                TextField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Button("Add") {
                    let trimmed = text.wrappedValue.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    add(trimmed)
                    text.wrappedValue = ""
                }
            }
            if items.isEmpty {
                Text("Nothing yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(items, id: \.self) { item in
                    HStack {
                        Text(item).font(.system(size: 11, design: .monospaced))
                        Spacer()
                        Button {
                            remove(item)
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: Memory

private struct MemoryTab: View {
    @Bindable var cache: MatchCache
    @Bindable var vault: VaultStore

    private var rows: [(signature: String, entry: MatchCache.Entry)] {
        cache.entries
            .map { (signature: $0.key, entry: $0.value) }
            .sorted { $0.entry.learnedAt > $1.entry.learnedAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Control remembers what each field turned out to be, so it doesn't have to work it out twice.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Forget all") { cache.reset() }
                    .disabled(rows.isEmpty)
            }

            if rows.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    Text("Nothing remembered yet.").foregroundStyle(.tertiary)
                    Spacer()
                }
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(rows, id: \.signature) { row in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(row.entry.label ?? "Unlabelled field")
                                        .font(.system(size: 12))
                                    Text([row.entry.appName, vault.field(for: row.entry.key)?.label]
                                        .compactMap { $0 }
                                        .joined(separator: " → "))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if row.entry.userConfirmed {
                                    Image(systemName: "hand.point.up.left.fill")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                        .help("You chose this one")
                                }
                                Button {
                                    cache.forget(signature: row.signature)
                                } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 6)
                            Divider()
                        }
                    }
                }
            }
        }
    }
}
