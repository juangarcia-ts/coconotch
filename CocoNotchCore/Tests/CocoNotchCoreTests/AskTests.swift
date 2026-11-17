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
