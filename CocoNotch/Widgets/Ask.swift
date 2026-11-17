import CocoNotchCore
import FoundationModels
import SwiftUI

extension NotchWidget {
    static let ask = NotchWidget(
        id: "ask",
        title: "Ask",
        systemImage: "sparkles",
        makeView: {
            // The check runs each time the tab opens, so turning Apple Intelligence on shows the chat right away.
            if #available(macOS 26, *), getAskUnavailableReason() == nil {
                AnyView(AskView())
            } else {
                AnyView(AskUnavailableView())
            }
        },
        makeSettings: { AnyView(AskSettings()) }
    )
}

private let answerStyleKey = "ask.answerStyle"
let showsAskOnHomeKey = "home.showsAsk"

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

// Apple Intelligence's colours, used for Ask's mark and the focused composer.
private let intelligenceGradient = LinearGradient(
    colors: [.orange, .pink, .purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)

@available(macOS 26, *)
private struct AskView: View {
    @Bindable private var store = AskStore.shared

    var body: some View {
        VStack(spacing: 12) {
            if store.turns.isEmpty {
                AskEmptyState()
            } else {
                conversation
            }
            AskComposer(draft: $store.draft, isResponding: store.isResponding, send: store.send, stop: store.stop)
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let note = store.note {
                        Label(note, systemImage: "arrow.counterclockwise")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(store.turns) { AskTurnView(turn: $0) }
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .frame(height: 200)
            .overlay(alignment: .topTrailing) {
                Button(action: store.startNewChat) {
                    Label("New Chat", systemImage: "square.and.pencil")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help("Start a new chat")
            }
            .onChange(of: store.turns.last?.answer) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

private struct AskEmptyState: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(intelligenceGradient)
                .padding(.bottom, 2)
            Text("Ask Apple Intelligence")
                .font(.headline)
            Text("Quick answers, made on this Mac. Nothing leaves it.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }
}

/// The question field with its send button inside, like Messages. Return sends; Shift- or Option-Return adds a line.
private struct AskComposer: View {
    @Binding var draft: String
    let isResponding: Bool
    let send: () -> Void
    let stop: () -> Void
    var showsMark = false
    @FocusState private var isFocused: Bool

    var body: some View {
        let canSend = getAskQuestion(draft) != nil
        HStack(alignment: .bottom, spacing: 8) {
            if showsMark {
                Image(systemName: "sparkles")
                    .foregroundStyle(intelligenceGradient)
                    .padding(.bottom, 5)
            }
            TextField("Ask anything…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(.vertical, 3)
                .focused($isFocused)
                // Option-Return already adds a line; Shift-Return does the same thing at the cursor.
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
                    return .handled
                }
                .onSubmit(send)
            Button(
                isResponding ? "Stop" : "Send", systemImage: isResponding ? "stop.circle.fill" : "arrow.up.circle.fill"
            ) {
                isResponding ? stop() : send()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .font(.system(size: 20))
            .foregroundStyle(isResponding || canSend ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary))
            .disabled(!isResponding && !canSend)
            .help(isResponding ? "Stop answering" : "Send")
        }
        .padding(.leading, 14)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        // A capsule while one line high, a rounded box as lines are added.
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16).strokeBorder(
                isFocused ? AnyShapeStyle(intelligenceGradient) : AnyShapeStyle(Color.primary.opacity(0.12)),
                lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

private let appleIntelligenceSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")

/// A field for Home that always starts a new chat: sending opens the Ask tab, where the answer streams in, or the warning when Apple
/// Intelligence is off, keeping the question for later.
@available(macOS 26, *)
struct AskShortcut: View {
    @Bindable private var store = AskStore.shared
    @AppStorage(PreferenceKey.selectedWidget) private var selectedWidgetID = ""

    var body: some View {
        AskComposer(draft: $store.draft, isResponding: false, send: send, stop: {}, showsMark: true)
            .font(.callout)
    }

    private func send() {
        guard getAskQuestion(store.draft) != nil else { return }
        if getAskUnavailableReason() == nil {
            store.startNewChat()
            store.send()
        }
        selectedWidgetID = NotchWidget.ask.id
    }
}

private struct AskUnavailableView: View {
    var body: some View {
        let reason = getAskUnavailableReason() ?? .unknown
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.tertiary)
            Text("Apple Intelligence is off")
                .font(.headline)
            Text(getAskUnavailableMessage(reason))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if canFixAskInSettings(reason), let appleIntelligenceSettingsURL {
                Button("Open System Settings") { NSWorkspace.shared.open(appleIntelligenceSettingsURL) }
                    .controlSize(.small)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }
}

private struct AskTurnView: View {
    let turn: AskTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(turn.question)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                .padding(.leading, 80)
                .frame(maxWidth: .infinity, alignment: .trailing)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(intelligenceGradient)
                if let failure = turn.failure {
                    Text(failure).foregroundStyle(.orange)
                } else if turn.answer.isEmpty {
                    Text("Thinking…").foregroundStyle(.secondary)
                } else {
                    Text(formatAskAnswer(turn.answer))
                        .lineSpacing(2)
                }
            }
            .padding(.trailing, 40)
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
