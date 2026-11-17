import Foundation

public enum AskAnswerStyle: String, CaseIterable, Sendable {
    case brief
    case balanced
    case detailed
}

public enum AskUnavailableReason: Sendable {
    case olderSystem
    case deviceNotEligible
    case appleIntelligenceOff
    case modelNotReady
    case unknown
}

public enum AskFailure: Equatable, Sendable {
    case guardrail
    case unsupportedLanguage
    case other(String)
}

public func makeAskInstructions(style: AskAnswerStyle) -> String {
    let length =
        switch style {
        case .brief: "Answer in one or two sentences."
        case .balanced: "Answer in one short paragraph."
        case .detailed: "Answer in up to three short paragraphs or a short list."
        }
    return """
        You answer quick questions typed into a small panel at the top of a Mac screen. Be direct and accurate. \
        \(length) Use plain text with no headings. If you aren't sure, say so.
        """
}

/// The question to send, or nil when the draft is only whitespace.
public func getAskQuestion(_ draft: String) -> String? {
    let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    return question.isEmpty ? nil : question
}

/// The model often answers in Markdown; bold, italics and code render, anything else shows as typed.
public func formatAskAnswer(_ answer: String) -> AttributedString {
    (try? AttributedString(
        markdown: answer, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(answer)
}

public func getAskUnavailableMessage(_ reason: AskUnavailableReason) -> String {
    switch reason {
    case .olderSystem: "Ask needs macOS 26 or later with Apple Intelligence."
    case .deviceNotEligible: "This Mac can't run Apple Intelligence, so Ask isn't available."
    case .appleIntelligenceOff: "Turn on Apple Intelligence in System Settings → Apple Intelligence & Siri to use Ask."
    case .modelNotReady: "Apple Intelligence is still downloading. Ask shows up in the notch once it's ready."
    case .unknown: "Apple Intelligence isn't available right now."
    }
}

/// Whether System Settings can make Ask work: switching Apple Intelligence on, or watching its download.
public func canFixAskInSettings(_ reason: AskUnavailableReason) -> Bool {
    reason == .appleIntelligenceOff || reason == .modelNotReady
}

public func getAskFailureMessage(_ failure: AskFailure) -> String {
    switch failure {
    case .guardrail: "Apple Intelligence won't answer that. Try asking another way."
    case .unsupportedLanguage: "Apple Intelligence doesn't support this language yet."
    case .other(let description): "Something went wrong: \(description)"
    }
}

public let askContextResetNote = "The chat got too long, so a new one was started."

public struct AskChatTurn: Codable, Equatable, Sendable {
    public let question: String
    public let answer: String

    public init(question: String, answer: String) {
        self.question = question
        self.answer = answer
    }
}

public struct AskChat: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let turns: [AskChatTurn]

    public init(id: UUID, date: Date, turns: [AskChatTurn]) {
        self.id = id
        self.date = date
        self.turns = turns
    }
}

/// Puts the chat first, replacing its older copy, and keeps the newest `limit`. A chat with no turns isn't kept.
public func saveAskChat(_ chat: AskChat, in history: [AskChat], limit: Int) -> [AskChat] {
    let others = history.filter { $0.id != chat.id }
    return Array(((chat.turns.isEmpty ? [] : [chat]) + others).prefix(max(limit, 0)))
}

/// The chat's first question on one line, cut to fit a menu.
public func getAskChatTitle(_ chat: AskChat, maxLength: Int = 50) -> String {
    let question = (chat.turns.first?.question ?? "").split(whereSeparator: \.isNewline).joined(separator: " ")
    return question.count > maxLength ? question.prefix(maxLength - 1) + "…" : question
}

/// "Today", "Yesterday" or "Earlier", for grouping chats in the history menu.
public func getAskChatGroupTitle(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
    if calendar.isDate(date, inSameDayAs: now) { return "Today" }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday)
    {
        return "Yesterday"
    }
    return "Earlier"
}
