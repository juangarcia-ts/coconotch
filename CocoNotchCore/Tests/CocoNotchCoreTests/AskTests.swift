import CocoNotchCore
import Foundation
import Testing

@Test(arguments: [("  hi \n", "hi"), ("", nil), (" \n\t ", nil)] as [(String, String?)])
func trimsQuestion(draft: String, expected: String?) {
    #expect(getAskQuestion(draft) == expected)
}

@Test func givesEachStyleItsOwnLength() {
    let instructions = Set(AskAnswerStyle.allCases.map { makeAskInstructions(style: $0) })
    #expect(instructions.count == AskAnswerStyle.allCases.count)
    #expect(makeAskInstructions(style: .brief).contains("one or two sentences"))
}

@Test func rendersInlineMarkdown() {
    let answer = formatAskAnswer("It's **bold**\nand `code`")
    #expect(String(answer.characters) == "It's bold\nand code")
    #expect(answer.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized })
}

@Test func keepsUnparsableTextAsTyped() {
    #expect(String(formatAskAnswer("2 * 3 = 6").characters) == "2 * 3 = 6")
}

@Test func describesOtherFailures() {
    #expect(getAskFailureMessage(.other("Boom")).hasSuffix("Boom"))
}

@Test(
    arguments: [
        (.appleIntelligenceOff, true), (.modelNotReady, true), (.deviceNotEligible, false), (.olderSystem, false),
        (.unknown, false),
    ] as [(AskUnavailableReason, Bool)])
func offersSettingsOnlyWhenTheyHelp(reason: AskUnavailableReason, expected: Bool) {
    #expect(canFixAskInSettings(reason) == expected)
}

private func makeChat(_ question: String, id: UUID = UUID()) -> AskChat {
    AskChat(id: id, date: .now, turns: [AskChatTurn(question: question, answer: "a")])
}

@Test func savesChatFirstWithoutDuplicates() {
    let id = UUID()
    let older = [makeChat("one"), makeChat("old", id: id), makeChat("two")]
    let history = saveAskChat(makeChat("new", id: id), in: older, limit: 10)
    #expect(history.map { getAskChatTitle($0) } == ["new", "one", "two"])
}

@Test func keepsNewestChatsUpToLimit() {
    let history = saveAskChat(makeChat("c"), in: [makeChat("b"), makeChat("a")], limit: 2)
    #expect(history.map { getAskChatTitle($0) } == ["c", "b"])
}

@Test func skipsEmptyChats() {
    let empty = AskChat(id: UUID(), date: .now, turns: [])
    #expect(saveAskChat(empty, in: [makeChat("a")], limit: 5).count == 1)
}

@Test func titlesChatOnOneShortLine() {
    #expect(getAskChatTitle(makeChat("line one\nline two")) == "line one line two")
    #expect(getAskChatTitle(makeChat("abcdefghij"), maxLength: 5) == "abcd…")
}

@Test func groupsChatsByDay() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    let now = Date(timeIntervalSince1970: 1_000_000)
    #expect(getAskChatGroupTitle(now.addingTimeInterval(-60), now: now, calendar: calendar) == "Today")
    #expect(getAskChatGroupTitle(now.addingTimeInterval(-86_400), now: now, calendar: calendar) == "Yesterday")
    #expect(getAskChatGroupTitle(now.addingTimeInterval(-3 * 86_400), now: now, calendar: calendar) == "Earlier")
}
