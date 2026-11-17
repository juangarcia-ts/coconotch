import CocoNotchCore
import Testing

@Test func labelsHotKeysInMenuOrder() {
    let hotKey = HotKey(keyCode: 40, modifiers: HotKey.command | HotKey.shift | HotKey.control, key: "K")
    #expect(hotKey.label == "⌃⇧⌘K")
    #expect(HotKey(keyCode: 49, modifiers: HotKey.option, key: "Space").label == "⌥Space")
}

@Test func requiresACommandOptionOrControlModifier() {
    #expect(!HotKey(keyCode: 40, modifiers: HotKey.shift, key: "K").isValid)
    #expect(!HotKey(keyCode: 40, modifiers: 0, key: "K").isValid)
    #expect(HotKey(keyCode: 40, modifiers: HotKey.control, key: "K").isValid)
}

@Test func roundTripsHotKeys() {
    let colon = HotKey(keyCode: 41, modifiers: HotKey.command | HotKey.shift, key: ":")
    #expect(decodeHotKey(encodeHotKey(colon)) == colon)
    #expect(encodeHotKey(nil) == "")
    #expect(decodeHotKey("") == nil)
    #expect(decodeHotKey("40:0:K") == nil)
    #expect(decodeHotKey("nope") == nil)
}

@Test func namesPressedKeys() {
    #expect(getHotKeyName(keyCode: 49, characters: " ") == "Space")
    #expect(getHotKeyName(keyCode: 122, characters: "\u{F704}") == "F1")
    #expect(getHotKeyName(keyCode: 40, characters: "k") == "K")
    #expect(getHotKeyName(keyCode: 40, characters: nil) == "")
}

@Test func togglesTheNotchFromHotKeys() {
    #expect(shouldOpenNotchForHotKey(widgetID: "", isExpanded: false, selectedWidgetID: "home"))
    #expect(!shouldOpenNotchForHotKey(widgetID: "", isExpanded: true, selectedWidgetID: "home"))
    #expect(shouldOpenNotchForHotKey(widgetID: "ask", isExpanded: true, selectedWidgetID: "home"))
    #expect(!shouldOpenNotchForHotKey(widgetID: "ask", isExpanded: true, selectedWidgetID: "ask"))
    #expect(shouldOpenNotchForHotKey(widgetID: "ask", isExpanded: false, selectedWidgetID: "ask"))
}

@Test func handlesHotKeyOnPointerDisplayOrFirstNotch() {
    #expect(shouldHandleHotKey(ownDisplay: 0, panelDisplays: [0], pointerDisplay: 1))
    #expect(shouldHandleHotKey(ownDisplay: 1, panelDisplays: [0, 1], pointerDisplay: 1))
    #expect(!shouldHandleHotKey(ownDisplay: 0, panelDisplays: [0, 1], pointerDisplay: 1))
    #expect(shouldHandleHotKey(ownDisplay: 0, panelDisplays: [0, 1], pointerDisplay: 2))
    #expect(!shouldHandleHotKey(ownDisplay: 1, panelDisplays: [0, 1], pointerDisplay: nil))
}
