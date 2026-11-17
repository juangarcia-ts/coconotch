import CocoNotchCore
import Testing

@Test func movesSelection() {
    let ids = ["a", "b", "c"]
    #expect(getMovedSelection(in: ids, from: "a", by: 1) == "b")
    #expect(getMovedSelection(in: ids, from: "a", by: -1) == "a")
    #expect(getMovedSelection(in: ids, from: "c", by: 1) == "c")
    #expect(getMovedSelection(in: ids, from: "x", by: 1) == nil)
    #expect(getMovedSelection(in: ids, from: nil, by: 1) == nil)
    #expect(getMovedSelection(in: [String](), from: "a", by: 1) == nil)
}
