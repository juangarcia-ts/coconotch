import CocoNotchCore
import FoundationModels
import SwiftUI

extension NotchWidget {
    static let ask = NotchWidget(
        id: "ask",
        title: "Ask",
        systemImage: "sparkles",
        makeView: {
            if #available(macOS 26, *) { AnyView(AskView()) } else { AnyView(EmptyView()) }
        },
        makeSettings: { AnyView(AskSettings()) },
        isAvailable: { getAskUnavailableReason() == nil }
    )
}

private let answerStyleKey = "ask.answerStyle"

private func getAskUnavailableReason() -> AskUnavailableReason? {
    guard #available(macOS 26, *) else { return .olderSystem }
    switch SystemLanguageModel.default.availability {
    case .available: return nil
    case .unavailable(let reason):
        switch reason {
        case .deviceNotEligible: return .deviceNotEligible
        case .appleIntelligenceNotEnabled: return .appleIntelligenceOff
        case .modelNotReady: return .modelNotReady
        @unknown default: return .unknown
        }
    }
}

private struct AskTurn: Identifiable {
    let id = UUID()
    let question: String
    var answer = ""
    var failure: String?
}

/// Lives for the whole app run, so a half-typed question and the chat survive the notch closing.
@available(macOS 26, *)
@Observable private final class AskStore {
    static let shared = AskStore()
    var draft = ""
    private(set) var turns: [AskTurn] = []
    private(set) var note: String?
    private(set) var isResponding = false
    private var session: LanguageModelSession?
    private var task: Task<Void, Never>?

    func send() {
        guard !isResponding, let question = getAskQuestion(draft) else { return }
        draft = ""
        note = nil
        turns.append(AskTurn(question: question))
        isResponding = true
        task = Task {
            await answer(question, canRetry: true)
            isResponding = false
        }
    }

    func stop() {
        task?.cancel()
    }

    func startNewChat() {
        task?.cancel()
        session = nil
        turns = []
        note = nil
    }

    private func answer(_ question: String, canRetry: Bool) async {
        let session = session ?? makeSession()
        self.session = session
        do {
            for try await snapshot in session.streamResponse(to: question) {
                setLastAnswer(snapshot.content)
            }
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize where canRetry {
            self.session = nil
            turns = turns.suffix(1)
            note = askContextResetNote
            await answer(question, canRetry: false)
        } catch LanguageModelSession.GenerationError.guardrailViolation {
            setLastFailure(.guardrail)
        } catch LanguageModelSession.GenerationError.unsupportedLanguageOrLocale {
            setLastFailure(.unsupportedLanguage)
        } catch is CancellationError {
        } catch {
            setLastFailure(.other(error.localizedDescription))
        }
    }

    private func makeSession() -> LanguageModelSession {
        let style = UserDefaults.standard.string(forKey: answerStyleKey).flatMap(AskAnswerStyle.init) ?? .brief
        return LanguageModelSession(instructions: makeAskInstructions(style: style))
    }

    private func setLastAnswer(_ answer: String) {
        guard !turns.isEmpty else { return }
        turns[turns.count - 1].answer = answer
    }

    private func setLastFailure(_ failure: AskFailure) {
        guard !turns.isEmpty else { return }
        turns[turns.count - 1].failure = getAskFailureMessage(failure)
    }
}

@available(macOS 26, *)
private struct AskView: View {
    @Bindable private var store = AskStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.turns.isEmpty {
                Text("Ask a quick question. Answers come from Apple Intelligence on this Mac.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if let note = store.note {
                                Text(note).font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(store.turns) { AskTurnView(turn: $0) }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 200)
                    .onChange(of: store.turns.last?.answer) { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
            HStack {
                TextField("Ask anything…", text: $store.draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(store.send)
                if store.isResponding {
                    Button("Stop", systemImage: "stop.circle.fill", action: store.stop)
                        .help("Stop answering")
                } else {
                    Button("Send", systemImage: "arrow.up.circle.fill", action: store.send)
                        .help("Send")
                        .disabled(getAskQuestion(store.draft) == nil)
                }
                Button("New Chat", systemImage: "square.and.pencil", action: store.startNewChat)
                    .help("New chat")
                    .disabled(store.turns.isEmpty)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
    }
}

private struct AskTurnView: View {
    let turn: AskTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(turn.question)
                .font(.callout.weight(.semibold))
            if let failure = turn.failure {
                Text(failure).foregroundStyle(.orange)
            } else if turn.answer.isEmpty {
                ProgressView().controlSize(.small)
            } else {
                Text(formatAskAnswer(turn.answer))
            }
        }
        .textSelection(.enabled)
    }
}

private struct AskSettings: View {
    @AppStorage(answerStyleKey) private var answerStyle = AskAnswerStyle.brief
    @AppStorage(PreferenceKey.staysOpenWhileTyping) private var staysOpenWhileTyping = true

    var body: some View {
        Form {
            if let reason = getAskUnavailableReason() {
                Section("Unavailable") {
                    Text(getAskUnavailableMessage(reason))
                    Text("The Ask tab stays hidden from the notch until Apple Intelligence is ready.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Picker("Answer length", selection: $answerStyle) {
                    Text("Brief").tag(AskAnswerStyle.brief)
                    Text("Balanced").tag(AskAnswerStyle.balanced)
                    Text("Detailed").tag(AskAnswerStyle.detailed)
                }
                Toggle("Keep the notch open while typing", isOn: $staysOpenWhileTyping)
            } footer: {
                Text(
                    """
                    A new length applies from the next chat. Answers come from Apple Intelligence on this Mac; \
                    nothing is sent online. The typing setting covers every text field in the notch.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
