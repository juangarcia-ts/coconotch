public enum NotchDisplayChoice: String, CaseIterable, Sendable {
    /// The display with the menu bar, as set in System Settings → Displays → Arrangement.
    case main
    /// The built-in display with a physical notch.
    case builtIn
    case all
}

/// Which displays get a notch panel, as indices into the system's display list, where index 0 holds the menu bar.
/// `builtIn` falls back to the main display when no display has a notch, for example with the lid closed.
public func getNotchDisplayIndices(hasNotch: [Bool], choice: NotchDisplayChoice) -> [Int] {
    guard !hasNotch.isEmpty else { return [] }
    switch choice {
    case .main: return [0]
    case .builtIn: return [hasNotch.firstIndex(of: true) ?? 0]
    case .all: return Array(hasNotch.indices)
    }
}
