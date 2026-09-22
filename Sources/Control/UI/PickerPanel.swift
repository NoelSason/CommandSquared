import AppKit
import ControlKit
import SwiftUI

struct PickerRow: Identifiable, Equatable {
    let key: String
    let label: String
    let category: String
    /// Masked for sensitive fields — building the list must never read a value
    /// that would raise a Touch ID prompt.
    let preview: String
    let sensitive: Bool
    let score: Double

    var id: String { key }
}

@MainActor
final class PickerPresenter {
    private var panel: HUDPanel?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(
        title: String,
        hint: String?,
        rows: [PickerRow],
        preselected: String?,
        near anchor: NSRect?,
        onCommit: @escaping @MainActor (String) -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        dismiss()
        guard !rows.isEmpty else { return }

        let view = PickerView(
            title: title,
            hint: hint,
            rows: rows,
            preselected: preselected,
            onCommit: { [weak self] key in
                self?.dismiss()
                onCommit(key)
            },
            onCancel: { [weak self] in
                self?.dismiss()
                onCancel()
            }
        )

        let hosting = NSHostingView(rootView: view)
        let size = NSSize(width: 340, height: min(CGFloat(rows.count) * 44 + 92, 420))

        let panel = HUDPanel(contentRect: NSRect(origin: .zero, size: size))
        panel.contentView = hosting
        panel.position(near: anchor, size: size)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct PickerView: View {
    let title: String
    let hint: String?
    let rows: [PickerRow]
    let preselected: String?
    let onCommit: @MainActor (String) -> Void
    let onCancel: @MainActor () -> Void

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var searchFocused: Bool

    private var filtered: [PickerRow] {
        guard !query.isEmpty else { return rows }
        let needle = query.lowercased()
        return rows.filter {
            $0.label.lowercased().contains(needle) || $0.key.contains(needle)
        }
    }

    var body: some View {
        HUDBackground {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                list
            }
        }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.return) { commit(); return .handled }
        .onKeyPress(.escape) { onCancel(); return .handled }
        .onAppear {
            searchFocused = true
            if let preselected, let index = rows.firstIndex(where: { $0.key == preselected }) {
                selection = index
            }
        }
        .onChange(of: query) { _, _ in selection = 0 }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            if let hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($searchFocused)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, row in
                        PickerRowView(row: row, isSelected: index == selection)
                            .id(row.id)
                            .contentShape(Rectangle())
                            .onTapGesture { onCommit(row.key) }
                    }
                }
            }
            .onChange(of: selection) { _, new in
                guard filtered.indices.contains(new) else { return }
                proxy.scrollTo(filtered[new].id, anchor: .center)
            }
        }
    }

    private func move(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        selection = (selection + delta + filtered.count) % filtered.count
    }

    private func commit() {
        guard filtered.indices.contains(selection) else { return }
        onCommit(filtered[selection].key)
    }
}

private struct PickerRowView: View {
    let row: PickerRow
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(row.label)
                        .font(.system(size: 13, weight: .medium))
                    if row.sensitive {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(row.preview)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(row.category)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(isSelected ? Color.accentColor.opacity(0.18) : .clear)
    }
}
