import ControlKit
import SwiftUI

/// Saved blocks of text with `{placeholders}` in them.
///
/// Snippets deliberately sit apart from the rest of the vault: nothing guesses
/// them into a field. A paragraph of boilerplate appearing because a label looked
/// vaguely right would be far worse than nothing happening. You reach for one by
/// name in the picker, and that is the only way one ever lands.
struct SnippetsTab: View {
    @Bindable var vault: VaultStore

    @State private var editing: String?
    @State private var draftName = ""
    @State private var draftBody = ""

    private var snippets: [VaultField] {
        vault.fields(in: .snippet).sorted { $0.label < $1.label }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if snippets.isEmpty && editing == nil {
                empty
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if editing != nil { editor }
                        ForEach(snippets) { snippet in
                            if editing != snippet.key { row(snippet) }
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Reach these by name — tap ⌘ twice, then start typing the snippet's name.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button("New snippet") { startNew() }
                .disabled(editing != nil)
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 10) {
            Spacer()
            HStack {
                Spacer()
                VStack(spacing: 8) {
                    Text("No snippets yet.").foregroundStyle(.tertiary)
                    Button("Add a few examples") { addExamples() }
                }
                Spacer()
            }
            Spacer()
        }
    }

    private func row(_ snippet: VaultField) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(snippet.label).font(.system(size: 13, weight: .medium))
                Text((try? vault.storedValue(for: snippet.key)) ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer(minLength: 8)
            Button("Edit") { startEditing(snippet) }
                .buttonStyle(.link)
            Button {
                vault.removeCustomField(key: snippet.key)
            } label: {
                Image(systemName: "trash").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name — what you'll type to find it", text: $draftName)
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $draftBody)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))

            Text("Use {full_name}, {school email}, {date}, {date+7d}, {clipboard}, {cursor}.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            HStack {
                Button("Cancel") { editing = nil }
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty || draftBody.isEmpty)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
    }

    // MARK: Actions

    private func startNew() {
        editing = ""
        draftName = ""
        draftBody = ""
    }

    private func startEditing(_ snippet: VaultField) {
        editing = snippet.key
        draftName = snippet.label
        draftBody = (try? vault.storedValue(for: snippet.key)) ?? ""
    }

    private func save() {
        let name = draftName.trimmingCharacters(in: .whitespaces)
        // A stable key so editing the name doesn't orphan the stored value.
        let key = editing?.isEmpty == false ? editing! : "snippet_\(UUID().uuidString.prefix(8).lowercased())"

        if vault.field(for: key) == nil {
            vault.addCustomField(VaultField(
                key: key,
                label: name,
                category: .snippet,
                detail: "A saved block of text.",
                isBuiltIn: false
            ))
        } else {
            vault.renameCustomField(key: key, to: name)
        }
        vault.setValue(draftBody, for: key)
        editing = nil
    }

    private func addExamples() {
        let examples: [(String, String)] = [
            ("Intro", "Hi — I'm {full_name}, a {class standing} at {university} studying {major}. You can reach me at {school email}."),
            ("Signature", "{full_name}\n{school email}\n{github}"),
            ("Today", "{date:MMMM d, yyyy}"),
            ("Follow up", "Following up on this — happy to talk any time before {date+7d:MMMM d}.\n\n{cursor}"),
        ]
        for (name, body) in examples {
            let key = "snippet_\(name.lowercased().replacingOccurrences(of: " ", with: "_"))"
            guard vault.field(for: key) == nil else { continue }
            vault.addCustomField(VaultField(key: key, label: name, category: .snippet,
                                            detail: "A saved block of text.", isBuiltIn: false))
            vault.setValue(body, for: key)
        }
    }
}
