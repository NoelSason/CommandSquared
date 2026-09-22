import Foundation

/// How Control is summoned.
public enum TriggerMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Tap ⌘ twice. No chord, nothing to collide with.
    case doubleCommand
    /// Tap ⌃ twice, for anyone who uses ⌘ too heavily to want it overloaded.
    case doubleControl
    /// A conventional key combination, configured in settings.
    case chord

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .doubleCommand: "Tap ⌘ twice"
        case .doubleControl: "Tap ⌃ twice"
        case .chord: "A key combination"
        }
    }

    public var detail: String {
        switch self {
        case .doubleCommand: "Quickest to reach. Holding ⌘ or using any ⌘ shortcut never triggers it."
        case .doubleControl: "Same idea, if you'd rather leave ⌘ alone."
        case .chord: "Pick your own combination below."
        }
    }
}
