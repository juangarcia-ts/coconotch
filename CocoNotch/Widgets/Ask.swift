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
private let keepsHistoryKey = "ask.keepsHistory"
private let historySizeKey = "ask.historySize"
private let defaultHistorySize = 20
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

private func readSetting<Value>(_ key: String, default defaultValue: Value) -> Value {
    UserDefaults.standard.object(forKey: key) as? Value ?? defaultValue
}

/// Lives for the whole app run, so a half-typed question and the chat survive the notch closing.
@available(macOS 26, *)
@Observable private final class AskStore {
    static let shared = AskStore()
    var draft = ""
    private(set) var turns: [AskTurn] = []
    private(set) var note: String?
    private(set) var isResponding = false
    private(set) var history: [AskChat] = []
    private var chatID = UUID()
    private var session: LanguageModelSession?
    private var task: Task<Void, Never>?
    private let directory = URL.applicationSupportDirectory.appending(path: "CocoNotch/Ask")
    private var historyURL: URL { directory.appending(path: "history.json") }

    init() {
        if let data = try? Data(contentsOf: historyURL) {
            history = (try? JSONDecoder().decode([AskChat].self, from: data)) ?? []
        }
    }

    func send() {
        guard !isResponding, let question = getAskQuestion(draft) else { return }
        draft = ""
        note = nil
        turns.append(AskTurn(question: question))
        isResponding = true
        task = Task {
            await answer(question, canRetry: true)
            // Stopping or switching chats already settled the state; a cancelled task must not touch the new chat.
            guard !Task.isCancelled else { return }
            isResponding = false
            saveChat()
        }
    }

    func stop() {
        task?.cancel()
        isResponding = false
        saveChat()
    }

    func startNewChat() {
        task?.cancel()
        isResponding = false
        session = nil
        turns = []
        note = nil
        chatID = UUID()
    }

    /// Reopens a saved chat; the session is rebuilt from it, so follow-ups know what was said.
    func open(_ chat: AskChat) {
        startNewChat()
        chatID = chat.id
        turns = chat.turns.map { AskTurn(question: $0.question, answer: $0.answer) }
        session = LanguageModelSession(transcript: makeTranscript(chat.turns))
    }

    func clearHistory() {
        history = []
        try? FileManager.default.removeItem(at: historyURL)
    }

    private func saveChat() {
        guard readSetting(keepsHistoryKey, default: true) else { return }
        let answered = turns.filter { $0.failure == nil && !$0.answer.isEmpty }
        let chat = AskChat(
            id: chatID, date: .now, turns: answered.map { AskChatTurn(question: $0.question, answer: $0.answer) })
        history = saveAskChat(chat, in: history, limit: readSetting(historySizeKey, default: defaultHistorySize))
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(history) { try? data.write(to: historyURL) }
    }

    private func makeTranscript(_ turns: [AskChatTurn]) -> Transcript {
        let instructions = Transcript.Instructions(
            segments: [.text(.init(content: makeInstructions()))], toolDefinitions: [])
        return Transcript(
            entries: [.instructions(instructions)]
                + turns.flatMap { turn -> [Transcript.Entry] in
                    [
                        .prompt(Transcript.Prompt(segments: [.text(.init(content: turn.question))])),
                        .response(Transcript.Response(assetIDs: [], segments: [.text(.init(content: turn.answer))])),
                    ]
                })
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
        LanguageModelSession(instructions: makeInstructions())
    }

    private func makeInstructions() -> String {
        makeAskInstructions(style: AskAnswerStyle(rawValue: readSetting(answerStyleKey, default: "")) ?? .brief)
    }

    private func setLastAnswer(_ answer: String) {
        guard !Task.isCancelled, !turns.isEmpty else { return }
        turns[turns.count - 1].answer = answer
    }

    private func setLastFailure(_ failure: AskFailure) {
        guard !Task.isCancelled, !turns.isEmpty else { return }
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
        VStack(spacing: 10) {
            if store.turns.isEmpty {
                // The header floats here, so a History button doesn't push the empty state down.
                AskEmptyState()
                    .overlay(alignment: .topTrailing) { header }
            } else {
                header
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
            .frame(height: 180)
            .onChange(of: store.turns.last?.answer) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

@available(macOS 26, *)
extension AskView {
    private var header: some View {
        HStack(spacing: 6) {
            Spacer()
            if !store.history.isEmpty {
                Menu {
                    let now = Date.now
                    let groups = Dictionary(grouping: store.history) { getAskChatGroupTitle($0.date, now: now) }
                    ForEach(["Today", "Yesterday", "Earlier"], id: \.self) { title in
                        if let chats = groups[title] {
                            Section(title) {
                                ForEach(chats) { chat in
                                    Button(getAskChatTitle(chat)) { store.open(chat) }
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Clear History", role: .destructive, action: store.clearHistory)
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                        .modifier(AskPill())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Open a past chat")
            }
            if !store.turns.isEmpty {
                Button(action: store.startNewChat) {
                    Label("New Chat", systemImage: "square.and.pencil")
                        .modifier(AskPill())
                }
                .buttonStyle(.plain)
                .help("Start a new chat")
            }
        }
    }
}

private struct AskPill: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.07), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            .contentShape(Capsule())
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
    // One line of the field with its padding, so the mark and button sit level with the last line.
    private let lineHeight: CGFloat = 22

    var body: some View {
        let canSend = getAskQuestion(draft) != nil
        HStack(alignment: .bottom, spacing: 8) {
            if showsMark {
                Image(systemName: "sparkles")
                    .foregroundStyle(intelligenceGradient)
                    .frame(height: lineHeight)
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
            .frame(height: lineHeight)
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

/// A field for Home that always starts a new chat: sending opens the Ask tab, where the answer streams in, or the
/// warning when Apple Intelligence is off, keeping the question for later.
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
        WidgetPrompt(systemImage: NotchWidget.ask.systemImage, message: getAskUnavailableMessage(reason)) {
            if canFixAskInSettings(reason), let appleIntelligenceSettingsURL {
                Button("Open System Settings") { NSWorkspace.shared.open(appleIntelligenceSettingsURL) }
            }
        }
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
    @AppStorage(keepsHistoryKey) private var keepsHistory = true
    @AppStorage(historySizeKey) private var historySize = defaultHistorySize

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
            Section("History") {
                Toggle("Keep past chats", isOn: $keepsHistory)
                Picker("Chats to keep", selection: $historySize) {
                    ForEach([10, 20, 50, 100], id: \.self) { Text("\($0)").tag($0) }
                }
                .disabled(!keepsHistory)
                if #available(macOS 26, *) {
                    Button("Clear History", role: .destructive) { AskStore.shared.clearHistory() }
                        .disabled(AskStore.shared.history.isEmpty)
                }
                Text("Chats are saved on this Mac only. A smaller limit applies from the next saved chat.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
