import AppKit
import ControlKit
import Observation
import SwiftUI

/// First-run setup: access, your details, a first fill. Opens by itself once on
/// a fresh install, and from the menu any time after. Which step shows is
/// `OnboardingFlow`'s decision; this only draws it.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: OnboardingModel
    private let preferences: Preferences

    init(
        vault: VaultStore,
        preferences: Preferences,
        fillController: FillController,
        onOpenSettings: @escaping @MainActor () -> Void,
        onOpenInspector: @escaping @MainActor () -> Void
    ) {
        self.preferences = preferences
        model = OnboardingModel(
            vault: vault,
            preferences: preferences,
            fillController: fillController,
            onOpenSettings: onOpenSettings,
            onOpenInspector: onOpenInspector
        )
        super.init()
        model.isFrontmost = { [weak self] in self?.window?.isKeyWindow ?? false }
        model.onFinish = { [weak self] in self?.window?.performClose(nil) }
        fillController.practiceHandler = { [weak model] in await model?.practice() ?? false }
    }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Set Up Control"
            window.contentView = NSHostingView(rootView: OnboardingView(model: model))
            window.center()
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
        }
        model.vault.refreshFilledKeys()
        window?.orderFrontRegardless()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Closing setup at any step counts as done with it: it won't reopen by
    /// itself, and the menu still has it.
    func windowWillClose(_ notification: Notification) {
        preferences.onboardingCompleted = true
    }
}

@MainActor
@Observable
final class OnboardingModel {
    let vault: VaultStore
    let preferences: Preferences
    @ObservationIgnored private let fillController: FillController
    @ObservationIgnored let onOpenSettings: @MainActor () -> Void
    @ObservationIgnored let onOpenInspector: @MainActor () -> Void
    @ObservationIgnored var isFrontmost: () -> Bool = { false }
    @ObservationIgnored var onFinish: () -> Void = {}

    var accessGranted = PermissionsGate.isGranted
    var detailsSkipped = false
    var practiced = false
    var practiceSkipped = false

    var practiceText = ""
    var practiceFocused = false
    /// What the practice box got: nil before trying, then whether it worked.
    var practiceWorked: Bool?
    var importModel: ImportModel?

    init(
        vault: VaultStore,
        preferences: Preferences,
        fillController: FillController,
        onOpenSettings: @escaping @MainActor () -> Void,
        onOpenInspector: @escaping @MainActor () -> Void
    ) {
        self.vault = vault
        self.preferences = preferences
        self.fillController = fillController
        self.onOpenSettings = onOpenSettings
        self.onOpenInspector = onOpenInspector
    }

    var step: OnboardingFlow.Step {
        OnboardingFlow.step(for: .init(
            accessGranted: accessGranted,
            savedDetails: vault.filledKeys.count,
            detailsSkipped: detailsSkipped,
            practiced: practiced,
            practiceSkipped: practiceSkipped
        ))
    }

    var practiceLabel: String {
        OnboardingFlow.practiceLabel(filled: vault.filledKeys) ?? "Email address"
    }

    /// "tap ⌘ twice" or "press ⌃⌘V", to finish a sentence.
    var triggerPhrase: String {
        switch preferences.triggerMode {
        case .doubleCommand, .doubleControl:
            let title = preferences.triggerDescription
            return title.prefix(1).lowercased() + title.dropFirst()
        case .chord:
            return "press \(preferences.triggerDescription)"
        }
    }

    func requestAccess() {
        PermissionsGate.request()
        PermissionsGate.openSystemSettings()
    }

    /// There is no notification for a permission being granted, so look.
    func watchAccess() async {
        while !accessGranted {
            try? await Task.sleep(for: .milliseconds(700))
            accessGranted = PermissionsGate.isGranted
        }
    }

    func startImport() {
        importModel = ImportModel(vault: vault)
    }

    func finishImport() {
        importModel = nil
        vault.refreshFilledKeys()
    }

    /// Handles the trigger when it fires in the practice box. Returns false
    /// anywhere else, so the ordinary fill runs.
    func practice() async -> Bool {
        guard step == .tryIt, practiceFocused, isFrontmost() else { return false }
        if let value = await fillController.practiceFill(label: practiceLabel) {
            practiceText = value
            practiceWorked = true
        } else {
            practiceWorked = false
        }
        return true
    }
}

private struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    @FocusState private var practiceFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            progress
            switch model.step {
            case .access: access
            case .details: details
            case .tryIt: tryIt
            case .done: done
            }
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(width: 520, height: 420, alignment: .topLeading)
        .sheet(item: $model.importModel) { importModel in
            ImportSheet(model: importModel, onClose: { model.finishImport() })
        }
        .task { await model.watchAccess() }
        .onChange(of: practiceFocused) { _, focused in model.practiceFocused = focused }
    }

    // MARK: Progress

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach([OnboardingFlow.Step.access, .details, .tryIt], id: \.self) { step in
                Capsule()
                    .fill(step.rawValue <= model.step.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: 28, height: 4)
            }
        }
    }

    private func heading(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 20, weight: .semibold))
            Text(body)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Steps

    private var access: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading(
                "Let Control see the box you're in",
                "Control reads what a box is asking for — “Email”, “ZIP code” — and fills in your answer. "
                    + "macOS needs your permission for that, once."
            )
            Button("Open System Settings") { model.requestAccess() }
                .buttonStyle(.borderedProminent)
            Text("Turn Control on in the list. This page moves on by itself.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading(
                "Tell Control about you",
                "Bring in what's already on your Mac — your contact card, or what your browser has saved — "
                    + "or type it in yourself. You see everything before anything is saved."
            )
            HStack(spacing: 10) {
                Button("Bring in my details…") { model.startImport() }
                    .buttonStyle(.borderedProminent)
                Button("Type them in") { model.onOpenSettings() }
                Button("Skip for now") { model.detailsSkipped = true }
                    .buttonStyle(.link)
            }
            Label("Your details stay on this Mac. Card details and your traveler number always ask for Touch ID first.", systemImage: "lock")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading("Try it", "Click the box below, then \(model.triggerPhrase).")

            VStack(alignment: .leading, spacing: 5) {
                Text(model.practiceLabel).font(.system(size: 12, weight: .medium))
                TextField("", text: $model.practiceText)
                    .textFieldStyle(.roundedBorder)
                    .focused($practiceFocused)
            }
            .frame(maxWidth: 320)

            switch model.practiceWorked {
            case true?:
                VStack(alignment: .leading, spacing: 10) {
                    Label("That's it. It works the same way in any app or website.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button("Continue") { model.practiced = true }
                        .buttonStyle(.borderedProminent)
                }
            case false?:
                Text("Control didn't find an answer for this one. Add it in Settings, or skip ahead.")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            case nil:
                EmptyView()
            }

            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline) {
                Text("If a box somewhere else won't fill, the Field Inspector shows what Control can read there.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("Field Inspector") { model.onOpenInspector() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                Spacer()
                Button("Skip") { model.practiceSkipped = true }
            }
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading(
                "You're set",
                "Whenever a box wants something about you, \(model.triggerPhrase). If Control picks the wrong "
                    + "thing, do it again to swap in the next answer — and it'll remember."
            )
            HStack(spacing: 10) {
                Button("Done") { model.onFinish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                Button("Open Settings") { model.onOpenSettings() }
            }
        }
    }
}
