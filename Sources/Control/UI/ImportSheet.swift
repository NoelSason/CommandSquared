import AppKit
import ControlKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class ImportModel: Identifiable {
    // Presented with `.sheet(item:)` rather than `.sheet(isPresented:)`. With the
    // latter, the model is still nil the first time SwiftUI builds the sheet's
    // content, which renders an empty box — the fix is to hand SwiftUI the value
    // itself so it cannot be presented without one.
    nonisolated let id = UUID()

    var proposals: [ImportedValue] = []
    var selected: Set<String> = []
    var status: String?
    var isWorking = false
    /// Set when the only thing standing in the way is a permission.
    var needsFullDiskAccess = false

    private let vault: VaultStore

    init(vault: VaultStore) {
        self.vault = vault
    }

    var browserProfiles: [BrowserAutofillReader.Profile] {
        BrowserAutofillReader.availableProfiles()
    }

    // MARK: Gathering

    func loadContacts() async {
        await gather("your contact card") { try await ContactsImporter.readMeCard() }
    }

    func loadBrowser(_ profile: BrowserAutofillReader.Profile) async {
        await gather(profile.name) {
            VaultImporter.fromBrowserAutofill(try BrowserAutofillReader.read(profile))
        }
    }

    func loadVCardFile() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "vcf") ?? .text]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a contact card to import from."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        await gather(url.lastPathComponent) { try ContactsImporter.readVCardFile(at: url) }
    }

    private func gather(_ label: String, _ work: @escaping () async throws -> [ImportedValue]) async {
        isWorking = true
        defer { isWorking = false }

        needsFullDiskAccess = false
        do {
            let found = try await work()
            // Existing sources keep priority; a new one fills the gaps.
            proposals = VaultImporter.merge([proposals, found])
            // Only the unambiguous rows are ticked. Everything else is visible
            // but opt-in, because a wrong row here becomes a wrong answer later.
            selected.formUnion(found.filter(\.isConfident).map(\.id))
            status = found.isEmpty
                ? "Nothing usable in \(label)."
                : "Found \(found.count) from \(label)."
        } catch {
            status = error.localizedDescription
            if let readError = error as? BrowserAutofillReader.ReadError {
                needsFullDiskAccess = readError.needsFullDiskAccess
            }
        }
    }

    // MARK: Applying

    var selectedCount: Int { selected.count }

    func apply() -> Int {
        var applied = 0
        for proposal in proposals where selected.contains(proposal.id) {
            vault.setValue(proposal.value, for: proposal.key)
            applied += 1
        }
        vault.refreshFilledKeys()
        return applied
    }

    func label(for key: String) -> String {
        vault.field(for: key)?.label ?? key
    }

    func willOverwrite(_ proposal: ImportedValue) -> Bool {
        vault.filledKeys.contains(proposal.key)
    }
}

struct ImportSheet: View {
    @Bindable var model: ImportModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.proposals.isEmpty {
                empty
            } else {
                list
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bring in what you already have")
                .font(.system(size: 15, weight: .semibold))
            Text("Nothing is saved until you press Add. Values are read, never changed.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Your contact card") { Task { await model.loadContacts() } }
                Button("A vCard file…") { Task { await model.loadVCardFile() } }
                ForEach(model.browserProfiles) { profile in
                    Button(profile.name) { Task { await model.loadBrowser(profile) } }
                }
            }
            .disabled(model.isWorking)

            if let status = model.status {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(model.needsFullDiskAccess ? .orange : .secondary)
            }

            if model.needsFullDiskAccess {
                HStack(spacing: 8) {
                    Button("Open Full Disk Access") { PermissionsGate.openFullDiskAccess() }
                        .buttonStyle(.borderedProminent)
                    Button("Restart Control") { PermissionsGate.restart() }
                    Text("Turn Control on in the list, then restart.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(16)
    }

    private var empty: some View {
        VStack {
            Spacer()
            Text("Pick a source above.")
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(model.proposals) { proposal in
                    row(proposal)
                    Divider()
                }
            }
        }
    }

    private func row(_ proposal: ImportedValue) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { model.selected.contains(proposal.id) },
                set: { on in
                    if on { model.selected.insert(proposal.id) } else { model.selected.remove(proposal.id) }
                }
            ))
            .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.label(for: proposal.key))
                        .font(.system(size: 13, weight: .medium))
                    if model.willOverwrite(proposal) {
                        Text("replaces what's saved")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                }
                Text(proposal.value)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                // Seeing `project-name` next to "Full name" is what makes a bad
                // row obvious without having to think about it.
                Text("\(proposal.source.title) · \(proposal.origin)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack {
            Button("Select all") { model.selected = Set(model.proposals.map(\.id)) }
                .disabled(model.proposals.isEmpty)
            Button("Select none") { model.selected.removeAll() }
                .disabled(model.selected.isEmpty)
            Spacer()
            Button("Cancel", action: onClose)
            Button("Add \(model.selectedCount)") {
                _ = model.apply()
                onClose()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.selectedCount == 0)
        }
        .padding(16)
    }
}
