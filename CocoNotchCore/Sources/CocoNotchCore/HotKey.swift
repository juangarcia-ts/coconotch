import Foundation

/// A system-wide shortcut, in the form Carbon's `RegisterEventHotKey` takes.
public struct HotKey: Equatable, Sendable {
    /// A virtual key code, such as 49 for Space.
    public let keyCode: UInt32
    /// Carbon modifier bits; see the `HotKey` modifier constants.
    public let modifiers: UInt32
    /// What the key prints, such as "K" or "Space", since the code alone depends on the keyboard layout.
    public let key: String

    public init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    // Carbon's cmdKey, shiftKey, optionKey and controlKey, which this package can't import.
    public static let command: UInt32 = 1 << 8
    public static let shift: UInt32 = 1 << 9
    public static let option: UInt32 = 1 << 11
    public static let control: UInt32 = 1 << 12

    /// "⌃⌥⇧⌘K", in the order macOS menus use.
    public var label: String {
        let symbols: [(UInt32, String)] = [
            (Self.control, "⌃"), (Self.option, "⌥"), (Self.shift, "⇧"), (Self.command, "⌘"),
        ]
        return symbols.filter { modifiers & $0.0 != 0 }.map(\.1).joined() + key
    }

    /// Shift alone would swallow capital letters everywhere, so a hotkey needs ⌘, ⌥ or ⌃.
    public var isValid: Bool {
        modifiers & (Self.command | Self.option | Self.control) != 0 && !key.isEmpty
    }
}

/// Stored as "keyCode:modifiers:key"; the key goes last because it can itself be a colon.
public func encodeHotKey(_ hotKey: HotKey?) -> String {
    hotKey.map { "\($0.keyCode):\($0.modifiers):\($0.key)" } ?? ""
}

public func decodeHotKey(_ stored: String) -> HotKey? {
    let parts = stored.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
    guard parts.count == 3, let keyCode = UInt32(parts[0]), let modifiers = UInt32(parts[1]) else { return nil }
    let hotKey = HotKey(keyCode: keyCode, modifiers: modifiers, key: String(parts[2]))
    return hotKey.isValid ? hotKey : nil
}

private let namedKeys: [UInt16: String] = [
    49: String(localized: "Space", bundle: .module), 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 123: "←", 124: "→", 125: "↓",
    126: "↑",
    122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
    103: "F11", 111: "F12",
]

/// What to call a pressed key: a name for keys that print nothing readable, else its character in capitals.
public func getHotKeyName(keyCode: UInt16, characters: String?) -> String {
    namedKeys[keyCode] ?? (characters ?? "").uppercased()
}

/// A hotkey toggles: the notch hotkey ("" here) opens or closes it, and a widget's opens it on that widget unless
/// that widget is already showing.
public func shouldOpenNotchForHotKey(widgetID: String, isExpanded: Bool, selectedWidgetID: String) -> Bool {
    !isExpanded || (!widgetID.isEmpty && widgetID != selectedWidgetID)
}

/// Which notch answers a hotkey: the one on the pointer's display, or the first one when that display has none, so
/// a hotkey still works with the pointer on a monitor without a notch. Displays are identified by their index.
public func shouldHandleHotKey(ownDisplay: Int, panelDisplays: [Int], pointerDisplay: Int?) -> Bool {
    if let pointerDisplay, panelDisplays.contains(pointerDisplay) { return ownDisplay == pointerDisplay }
    return ownDisplay == panelDisplays.first
}
