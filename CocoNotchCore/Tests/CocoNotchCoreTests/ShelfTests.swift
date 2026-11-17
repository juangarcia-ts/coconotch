import CocoNotchCore
import Foundation
import Testing

private func file(_ path: String, isCopy: Bool = false, byteCount: Int? = nil) -> ShelfItem {
    ShelfItem(kind: .file, value: path, isCopy: isCopy, byteCount: byteCount)
}

@Test func addsNewItemsAfterExistingOnes() {
    let items = addShelfItems([file("/b"), file("/a"), file("/b")], to: [file("/a")])
    #expect(items.map(\.value) == ["/a", "/b"])
}

@Test func keepsTextAndFileWithTheSameValueApart() {
    let items = addShelfItems([ShelfItem(kind: .text, value: "/a")], to: [file("/a")])
    #expect(items.count == 2)
}

@Test func findsCopiesToDelete() {
    let kept = file("/copy/a", isCopy: true)
    let old = [kept, file("/copy/b", isCopy: true), file("/original")]
    #expect(getUnusedShelfCopies(old: old, new: [kept]) == ["/copy/b"])
}

@Test(
    arguments: [
        ("/a", nil, false, ShelfFileStatus.missing),
        ("/a", "/a", false, .available),
        ("/a", "/a", true, .refresh(path: "/a")),
        ("/a", "/b", false, .refresh(path: "/b")),
        ("/a", "/Users/me/.Trash/a", false, .trashed),
        ("/a", "/Volumes/Drive/.Trashes/501/a", false, .trashed),
    ] as [(String, String?, Bool, ShelfFileStatus)])
func decidesWhatToDoWithAResolvedFile(saved: String, resolved: String?, isStale: Bool, expected: ShelfFileStatus) {
    #expect(getShelfFileStatus(savedPath: saved, resolvedPath: resolved, isStale: isStale) == expected)
}

@Test(
    arguments: [
        (ShelfItem.Kind.file, "/Users/me/Report final.pdf", "Report final.pdf"),
        (.text, "\n  First line  \nsecond", "First line"),
        (.link, "https://example.com/docs/page", "example.com/docs/page"),
        (.link, "https://example.com/", "example.com"),
        (.link, "not a url", "not a url"),
    ])
func titlesItems(kind: ShelfItem.Kind, value: String, expected: String) {
    #expect(getShelfItemTitle(ShelfItem(kind: kind, value: value)) == expected)
}

@Test func summarizesCountAndSize() {
    #expect(formatShelfSummary([]) == "0 items")
    #expect(formatShelfSummary([ShelfItem(kind: .text, value: "x")]) == "1 item")
    let summary = formatShelfSummary([file("/a", byteCount: 1_000_000), file("/b", byteCount: 1_000_000)])
    #expect(summary.hasPrefix("2 items · 2"))
}

@Test func selectsWithClicksAndModifiers() {
    let ids = (0..<4).map { _ in UUID() }
    let plain = selectShelfItems(
        clicked: ids[1], in: ids, selection: [ids[0]], anchor: ids[0], isToggling: false, isExtending: false)
    #expect(plain.selection == [ids[1]])
    let toggled = selectShelfItems(
        clicked: ids[3], in: ids, selection: plain.selection, anchor: plain.anchor, isToggling: true,
        isExtending: false)
    #expect(toggled.selection == [ids[1], ids[3]])
    let untoggled = selectShelfItems(
        clicked: ids[3], in: ids, selection: toggled.selection, anchor: ids[3], isToggling: true, isExtending: false)
    #expect(untoggled.selection == [ids[1]])
    let extended = selectShelfItems(
        clicked: ids[3], in: ids, selection: [ids[1]], anchor: ids[1], isToggling: false, isExtending: true)
    #expect(extended.selection == Set(ids[1...3]))
    #expect(extended.anchor == ids[1])
}

@Test func targetsTheSelectionOnlyWhenTheClickIsInIt() {
    let a = UUID()
    let b = UUID()
    #expect(getShelfTargets(clicked: a, selection: [a, b]) == [a, b])
    #expect(getShelfTargets(clicked: a, selection: [b]) == [a])
}

@Test func actsOnTheSelectionOrEverything() {
    let ids = (0..<3).map { _ in UUID() }
    #expect(getShelfSelectedOrAll(ids, selection: []) == ids)
    #expect(getShelfSelectedOrAll(ids, selection: [ids[2], ids[0]]) == [ids[0], ids[2]])
}
