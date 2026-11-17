import AppKit
import Carbon.HIToolbox
import CocoNotchCore
import SwiftUI

let openNotchHotKeyKey = "shortcuts.openNotch"

/// Shortcuts that are on until the user records another or clears them; a cleared one is stored as "".
private let defaultHotKeys = [
    openNotchHotKeyKey: encodeHotKey(
        HotKey(keyCode: UInt32(kVK_ANSI_N), modifiers: HotKey.command | HotKey.shift, key: "N"))
]

func getWidgetHotKeyKey(widgetID: String) -> String {
    "shortcuts.widget.\(widgetID)"
}

extension Notification.Name {
    /// Posted with the widget ID to open as `object`, or "" to open or close the notch on its last tab.
    static let hotKeyPressed = Notification.Name("CocoNotch.hotKeyPressed")
}

/// Registers the user's system-wide shortcuts with Carbon, which needs no Accessibility permission.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var refs: [EventHotKeyRef] = []
    /// The widget ID per registered hotkey ID, "" for opening the notch.
    private var actions: [UInt32: String] = [:]
    private var registeredKeys: [String] = []

    func start() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                // Carbon delivers hotkeys on the main thread.
                MainActor.assumeIsolated { HotKeyCenter.shared.press(hotKeyID.id) }
                return noErr
            }, 1, &spec, nil, nil)
        register()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) {
            _ in
            MainActor.assumeIsolated { HotKeyCenter.shared.register() }
        }
    }

    /// Re-registers only when a shortcut changed, since every settings write lands here.
    private func register() {
        let defaults = UserDefaults.standard
        let entries =
            ([("", openNotchHotKeyKey)]
            + ([NotchWidget.home] + NotchWidget.all).map {
                ($0.id, getWidgetHotKeyKey(widgetID: $0.id))
            }).compactMap { action, key in
                decodeHotKey(defaults.string(forKey: key) ?? defaultHotKeys[key] ?? "").map { (action, $0) }
            }
        let keys = entries.map { "\($0.0)=\(encodeHotKey($0.1))" }
        guard keys != registeredKeys else { return }
        registeredKeys = keys
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        actions = [:]
        for (index, (action, hotKey)) in entries.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x436E_4E74), id: UInt32(index))
            // ponytail: a shortcut another app already holds fails silently; show it in the recorder if it confuses.
            guard
                RegisterEventHotKey(hotKey.keyCode, hotKey.modifiers, id, GetApplicationEventTarget(), 0, &ref)
                    == noErr,
                let ref
            else { continue }
            refs.append(ref)
            actions[UInt32(index)] = action
        }
    }

    private func press(_ id: UInt32) {
        guard let action = actions[id] else { return }
        NotificationCenter.default.post(name: .hotKeyPressed, object: action)
    }
}

private func getCarbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
    var modifiers: UInt32 = 0
    if flags.contains(.command) { modifiers |= HotKey.command }
    if flags.contains(.shift) { modifiers |= HotKey.shift }
    if flags.contains(.option) { modifiers |= HotKey.option }
    if flags.contains(.control) { modifiers |= HotKey.control }
    return modifiers
}

/// A button that records the next key combination pressed; Escape cancels.
struct HotKeyRecorder: View {
    @AppStorage private var stored: String
    @State private var monitor: Any?

    init(storageKey: String) {
        _stored = AppStorage(wrappedValue: defaultHotKeys[storageKey] ?? "", storageKey)
    }

    var body: some View {
        HStack(spacing: 4) {
            Button(monitor != nil ? "Press keys…" : decodeHotKey(stored)?.label ?? "Record Shortcut") {
                monitor == nil ? startRecording() : stopRecording()
            }
            .monospacedDigit()
            if decodeHotKey(stored) != nil {
                Button("Clear", systemImage: "xmark.circle.fill") { stored = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func startRecording() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
                return nil
            }
            let hotKey = HotKey(
                keyCode: UInt32(event.keyCode),
                modifiers: getCarbonModifiers(event.modifierFlags),
                key: getHotKeyName(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers))
            // Keeps listening until a combination with ⌘, ⌥ or ⌃ arrives.
            if hotKey.isValid {
                stored = encodeHotKey(hotKey)
                stopRecording()
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
