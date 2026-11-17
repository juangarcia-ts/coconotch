import CocoNotchCore
import Foundation
import Testing

private func file(_ path: String, isCopy: Bool = false, byteCount: Int? = nil) -> ShelfItem {
    ShelfItem(path: path, isCopy: isCopy, byteCount: byteCount)
}

@Test func addsNewItemsAfterExistingOnes() {
    let items = addShelfItems([file("/b"), file("/a"), file("/b")], to: [file("/a")])
    #expect(items.map(\.path) == ["/a", "/b"])
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

@Test func namesItemsByFileName() {
    #expect(file("/Users/me/Report final.pdf").name == "Report final.pdf")
}

@Test(
    arguments: [
        (["public.file-url", "public.utf8-plain-text"], ShelfDropSource.fileURL),
        (["public.jpeg", "public.url"], .data(type: "public.jpeg")),
        (["public.url", "public.png"], .data(type: "public.png")),
        (["com.adobe.pdf"], .data(type: "com.adobe.pdf")),
        (["public.url", "public.utf8-plain-text", "com.apple.webarchive"], nil),
        (["public.utf8-plain-text", "public.rtf"], nil),
    ] as [([String], ShelfDropSource?)])
func takesOnlyFilesFromDrops(types: [String], expected: ShelfDropSource?) {
    #expect(getShelfDropSource(typeIdentifiers: types) == expected)
}

@Test func summarizesCountAndSize() {
    #expect(formatShelfSummary([]) == "0 items")
    #expect(formatShelfSummary([file("/a")]) == "1 item")
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

@Test func namesNewShelves() {
    #expect(makeShelfName(existing: []) == "Shelf")
    #expect(makeShelfName(existing: [Shelf(name: "Shelf"), Shelf(name: "Shelf 3")]) == "Shelf 2")
    #expect(makeShelfName(existing: [Shelf(name: "Work")]) == "Shelf")
}

@Test func movesItemsBetweenShelves() {
    let a = file("/a")
    let b = file("/b")
    let duplicate = file("/b")
    let source = Shelf(name: "One", items: [a, b])
    let target = Shelf(name: "Two", items: [duplicate])
    let moved = moveShelfItems([a.id, b.id], to: target.id, in: [source, target])
    #expect(moved[0].items.isEmpty)
    #expect(moved[1].items.map(\.path) == ["/b", "/a"])
}

@Test func searchesShelvesAndItems() {
    let work = Shelf(name: "Work", items: [file("/x/Report.pdf"), file("/x/photo.png")])
    let trip = Shelf(name: "Trip", items: [file("/x/tickets.pdf"), file("/x/map.png")])
    #expect(filterShelves([work, trip], query: " ") == [work, trip])
    #expect(filterShelves([work, trip], query: "work").map(\.items.count) == [2])
    let pdfs = filterShelves([work, trip], query: ".pdf")
    #expect(pdfs.map(\.name) == ["Work", "Trip"])
    #expect(pdfs.flatMap(\.items).map(\.name) == ["Report.pdf", "tickets.pdf"])
    #expect(filterShelves([work, trip], query: "nothing").isEmpty)
}
