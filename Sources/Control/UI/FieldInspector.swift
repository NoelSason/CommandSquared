import AppKit
import ControlKit
import Observation
import SwiftUI

struct AXAttributeRow: Identifiable, Equatable {
    let name: String
    let value: String
    var id: String { name }
}

@MainActor
@Observable
final class InspectorModel {
    var context: FieldContext?
    var attributes: [AXAttributeRow] = []
    var capturedAt: Date?
}

/// Capture without filling.
///
/// While this window is open the hotkey stops inserting anything and just reports
/// what the Accessibility API returned. It exists because label quality varies a
/// lot between apps, and that needs to be a thing you can look at rather than
/// guess at from a failed fill.
@MainActor
final class FieldInspectorController: NSObject, NSWindowDelegate {
    private let model = InspectorModel()
    private var window: NSWindow?

    var onVisibilityChanged: (@MainActor (Bool) -> Void)?

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Field Inspector"
            window.contentView = NSHostingView(rootView: InspectorView(model: model))
            window.center()
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
        }
        window?.orderFrontRegardless()
        window?.makeKeyAndOrderFront(nil)
        onVisibilityChanged?(true)
    }

    func update(context: FieldContext, attributes: [(String, String)]) {
        model.context = context
        model.attributes = attributes.map { AXAttributeRow(name: $0.0, value: $0.1) }
        model.capturedAt = Date()
    }

    func windowWillClose(_ notification: Notification) {
        onVisibilityChanged?(false)
    }
}

private struct InspectorView: View {
    @Bindable var model: InspectorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            banner
            Divider()
            if let context = model.context {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        extracted(context)
                        Divider()
                        rawAttributes
                    }
                    .padding(16)
                }
            } else {
                Spacer()
                HStack {
                    Spacer()
                    Text("Focus a text field and press the Control hotkey.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Spacer()
            }
        }
        .frame(minWidth: 460, minHeight: 420)
    }

    private var banner: some View {
        HStack(spacing: 8) {
            Image(systemName: "scope")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Capture only — nothing will be filled while this window is open")
                    .font(.system(size: 12, weight: .medium))
                if let capturedAt = model.capturedAt {
                    Text("Last capture \(capturedAt.formatted(date: .omitted, time: .standard))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(12)
    }

    @ViewBuilder
    private func extracted(_ context: FieldContext) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What Control extracted")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            grid([
                ("App", context.appName),
                ("Bundle ID", context.bundleID),
                ("Domain", context.domain ?? "—"),
                ("Role", context.role ?? "—"),
                ("Subrole", context.subrole ?? "—"),
                ("Label", context.label ?? "—"),
                ("Placeholder", context.placeholder ?? "—"),
                ("Help", context.helpText ?? "—"),
                ("Nearby text", context.nearbyText.isEmpty ? "—" : context.nearbyText.joined(separator: " · ")),
                ("Section heading", context.heading ?? "—"),
                ("Field is empty", context.isEmpty ? "yes" : "no"),
                ("Normalized", context.searchText.isEmpty ? "—" : context.searchText),
            ])

            if context.hasNoDescriptiveText {
                Label("No label, placeholder, or help text — matching has nothing to work with here.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
            if context.isSecureField {
                Label("Secure text field — Control refuses these.", systemImage: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var rawAttributes: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Raw accessibility attributes")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            grid(model.attributes.map { ($0.name, $0.value) })
        }
    }

    private func grid(_ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows, id: \.0) { name, value in
                HStack(alignment: .top, spacing: 10) {
                    Text(name)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 150, alignment: .leading)
                    Text(value)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
