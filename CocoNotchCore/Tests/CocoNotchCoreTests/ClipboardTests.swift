import CocoNotchCore
import Testing

private func text(_ value: String, isPinned: Bool = false) -> ClipboardItem {
    ClipboardItem(kind: .text, value: value, isPinned: isPinned)
}

@Test(
    arguments: [
        (["public.utf8-plain-text"], "hi", nil, true, ClipboardItem.Kind.text),
        (["public.utf8-plain-text", "public.tiff"], "hi", nil, true, .text),  // text wins
        (["public.png"], nil, nil, true, .image),
        (["public.tiff"], nil, nil, false, nil),  // images off
        (["public.utf8-plain-text"], "  \n", nil, true, nil),  // blank text
        (["public.utf8-plain-text", "org.nspasteboard.ConcealedType"], "secret", nil, true, nil),
        (["public.utf8-plain-text", "org.nspasteboard.TransientType"], "x", nil, true, nil),
        (["public.utf8-plain-text"], "hi", "com.ignored", true, nil),  // ignored app
        (["public.utf8-plain-text"], "hi", "com.other", true, .text),
        (["public.rtf"], nil, nil, true, nil),
    ] as [([String], String?, String?, Bool, ClipboardItem.Kind?)])
func choosesWhatToCapture(
    types: [String], text: String?, sourceBundleID: String?, capturesImages: Bool, expected: ClipboardItem.Kind?
) {
    #expect(
        getClipboardCaptureKind(
            types: types, text: text, sourceBundleID: sourceBundleID, ignoredBundleIDs: ["com.ignored"],
            capturesImages: capturesImages) == expected)
}

@Test func addsNewItemsOnTop() {
    let history = addClipboardItem(text("b"), to: [text("a")], limit: 10)
    #expect(history.map(\.value) == ["b", "a"])
}

@Test func keepsOneCopyOfARepeatedTopItem() {
    let a = text("a")
    let history = addClipboardItem(text("a"), to: [a, text("b")], limit: 10)
    #expect(history.map(\.value) == ["a", "b"])
    #expect(history[0].id == a.id)
}

@Test func movesARecopiedItemToTopKeepingItsPin() {
    let history = addClipboardItem(text("b"), to: [text("a"), text("b", isPinned: true)], limit: 10)
    #expect(history.map(\.value) == ["b", "a"])
    #expect(history[0].isPinned)
}

@Test func treatsTextAndImageWithTheSameValueAsDifferent() {
    let image = ClipboardItem(kind: .image, value: "a")
    #expect(addClipboardItem(image, to: [text("a")], limit: 10).count == 2)
}

@Test func dropsTheOldestUnpinnedItems() {
    let history = [text("new"), text("pinned", isPinned: true), text("mid"), text("old")]
    #expect(trimClipboardHistory(history, limit: 3).map(\.value) == ["new", "pinned", "mid"])
    #expect(trimClipboardHistory(history, limit: 1).map(\.value) == ["pinned"])
}

@Test func showsPinnedFirstAndSearchesText() {
    let history = [text("Hello"), text("world", isPinned: true), ClipboardItem(kind: .image, value: "hello.png")]
    #expect(getVisibleClipboardItems(history, query: "").map(\.value) == ["world", "Hello", "hello.png"])
    #expect(getVisibleClipboardItems(history, query: " hel ").map(\.value) == ["Hello"])
}

@Test func findsImageFilesNoLongerUsed() {
    let a = ClipboardItem(kind: .image, value: "a.png")
    let b = ClipboardItem(kind: .image, value: "b.png")
    #expect(getUnusedImageFiles(old: [a, b, text("c.png")], new: [b]) == ["a.png"])
}

@Test func previewsTextWithoutBlankLines() {
    #expect(formatClipboardPreview("\n  first  \n\n\tsecond\n") == "first\nsecond")
    #expect(formatClipboardPreview(String(repeating: "x", count: 500)).count == 300)
}
