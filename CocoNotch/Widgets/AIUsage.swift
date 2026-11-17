import CocoNotchCore
import SwiftUI

extension NotchWidget {
    static let aiUsage = NotchWidget(
        id: "aiUsage",
        title: "AI Usage",
        systemImage: "sparkles",
        imageName: "ClaudeLogo",
        makeView: { AnyView(AIUsageView()) },
        makeSettings: { AnyView(AIUsageSettings()) },
        makeSummary: { AnyView(AIUsageSummary()) }
    )
}

private let providerKey = "aiUsage.provider"
private let showsClaudeKey = "aiUsage.showsClaude"
private let showsCodexKey = "aiUsage.showsCodex"
// Only set from the Connect button, so the Keychain prompt never appears unasked.
private let isClaudeConnectedKey = "aiUsage.isClaudeConnected"
private let hiddenKindsKey = "aiUsage.hiddenKinds"
private let showsRemainingKey = "aiUsage.showsRemaining"
private let refreshMinutesKey = "aiUsage.refreshMinutes"
private let showsHeadsUpKey = "aiUsage.showsHeadsUp"
private let headsUpThresholdKey = "aiUsage.headsUpThreshold"
private let showsIdleKey = "aiUsage.showsIdle"
private let showsNotchResetKey = "aiUsage.showsNotchReset"
private let idleShowsFullestKey = "aiUsage.idleShowsFullest"
private let defaultRefreshMinutes = 5
private let defaultHeadsUpThreshold = 80
private let headsUpActivityID = "aiUsage.headsUp"
// The newest session log is read from its end, where the latest snapshot is, so a long session isn't read whole.
nonisolated private let codexLogTailBytes = 512 * 1024

private enum CredentialsResult: Sendable {
    case found(ClaudeCredentials)
    case failed(ClaudeUsageProblem)
}

/// Claude Code reads and writes its login through /usr/bin/security, so the Keychain item already trusts that tool.
/// Reading it the same way needs no permission prompt, and keeps working when CocoNotch is rebuilt, which a direct
/// read wouldn't. Only the Claude login is kept; the item's other tokens are dropped as soon as it is parsed.
nonisolated private func readClaudeCredentials() -> CredentialsResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = ["find-generic-password", "-s", claudeCredentialsService, "-w"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return .failed(.keychainError(-1))
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    if let problem = getCredentialsProblem(exitCode: process.terminationStatus) { return .failed(problem) }
    guard let credentials = parseClaudeCredentials(data) else { return .failed(.notSignedIn) }
    return .found(credentials)
}

/// The newest Codex rate-limit snapshot, from the most recently written session logs. Nothing leaves the Mac.
nonisolated private func readCodexUsage() -> CodexUsage? {
    let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/sessions")
    guard
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey])
    else { return nil }
    let logs = enumerator.compactMap { $0 as? URL }
        .filter { $0.pathExtension == "jsonl" }
        .map { url in
            (
                url,
                (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    ?? .distantPast
            )
        }
        .sorted { $0.1 > $1.1 }
    // A session that hasn't reached a model response yet has no snapshot, so a few older ones are tried too.
    for (url, _) in logs.prefix(5) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(codexLogTailBytes) ? size - UInt64(codexLogTailBytes) : 0)
        guard let data = try? handle.readToEnd(), let usage = parseCodexUsage(String(decoding: data, as: UTF8.self))
        else { continue }
        return usage
    }
    return nil
}

private func readDefault<Value>(_ key: String, default defaultValue: Value) -> Value {
    UserDefaults.standard.object(forKey: key) as? Value ?? defaultValue
}

/// Loads usage for the whole app, so the Home card and the heads-up work without opening the tab.
@Observable
final class AIUsageStore {
    static let shared = AIUsageStore()

    private(set) var claudeLimits: [UsageLimit] = []
    private(set) var claudeProblem: ClaudeUsageProblem?
    private(set) var codexUsage: CodexUsage?
    private(set) var isLoading = false
    private var updatedAt: Date?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    // Picks the next limit once the shown one resets, without waiting for the next fetch.
    @ObservationIgnored private var resetTask: Task<Void, Never>?
    /// The heads-up showing in the closed notch, if any, as a `makeUsageHeadsUpKey`.
    private(set) var headsUpKey: String?
    /// Whose limit the heads-up is about, so the tab offers Dismiss only on that provider.
    private(set) var headsUpProvider: AIProvider?
    @ObservationIgnored private var dismissedHeadsUpKeys: Set<String> = []

    /// Starts over, so a new refresh interval applies now rather than after the old one runs out.
    func restart() {
        refreshTask?.cancel()
        refreshTask = nil
        start()
    }

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(
                    for: .seconds(readDefault(refreshMinutesKey, default: defaultRefreshMinutes) * 60))
            }
        }
    }

    /// Opening the tab reloads only numbers older than a minute, so hovering doesn't hit the Keychain and network.
    func refreshIfStale() {
        if isStale(updatedAt: updatedAt, now: .now, maxAge: 60) { refresh() }
    }

    func connectClaude() {
        UserDefaults.standard.set(true, forKey: isClaudeConnectedKey)
        refresh()
    }

    func disconnectClaude() {
        UserDefaults.standard.set(false, forKey: isClaudeConnectedKey)
        refresh()
    }

    /// Reloads now. Nothing is read or sent while the widget, or a provider, is off.
    func refresh() {
        loadTask?.cancel()
        let preferences = NotchWidget.getPreferences(
            stored: UserDefaults.standard.string(forKey: PreferenceKey.widgetPreferences) ?? "")
        guard getEnabledWidgetIDs(preferences).contains(NotchWidget.aiUsage.id) else {
            claudeLimits = []
            codexUsage = nil
            updateHeadsUp()
            return
        }
        // Clears the last problem, so the tab shows a spinner while the Keychain prompt and the request run.
        if claudeLimits.isEmpty { claudeProblem = nil }
        loadTask = Task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { if !Task.isCancelled { isLoading = false } }
        if readDefault(showsCodexKey, default: true) {
            codexUsage = await Task.detached { readCodexUsage() }.value
        } else {
            codexUsage = nil
        }
        if !readDefault(showsClaudeKey, default: true) {
            claudeLimits = []
        } else if !UserDefaults.standard.bool(forKey: isClaudeConnectedKey) {
            showClaude(.notConnected)
        } else {
            await loadClaude()
        }
        guard !Task.isCancelled else { return }
        updatedAt = .now
        updateHeadsUp()
    }

    /// A transient problem keeps the last numbers on screen; the rest clear them.
    private func showClaude(_ problem: ClaudeUsageProblem) {
        guard !(isTransientUsageProblem(problem) && !claudeLimits.isEmpty) else { return }
        claudeProblem = problem
        claudeLimits = []
    }

    private func loadClaude() async {
        let result = await Task.detached { readClaudeCredentials() }.value
        guard !Task.isCancelled else { return }
        switch result {
        case .failed(let problem):
            // Only a refusal disconnects; a locked keychain, say while the Mac sleeps, passes on its own.
            if problem == .accessDeclined { UserDefaults.standard.set(false, forKey: isClaudeConnectedKey) }
            showClaude(problem)
        case .found(let credentials):
            guard !isClaudeTokenExpired(credentials, now: .now) else {
                showClaude(.loginExpired)
                return
            }
            await fetchClaudeUsage(token: credentials.accessToken)
        }
    }

    private func fetchClaudeUsage(token: String) async {
        guard let url = claudeUsageURL else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled else { return }
            if let problem = getClaudeUsageProblem(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0) {
                showClaude(problem)
                return
            }
            claudeLimits = try parseClaudeUsage(data)
            claudeProblem = nil
        } catch is DecodingError {
            showClaude(.unexpectedResponse)
        } catch {
            guard !Task.isCancelled else { return }
            showClaude(.network)
        }
    }

    /// The limits to show for a provider: Claude's chosen kinds, or Codex's snapshot with reset windows at zero.
    func getLimits(for provider: AIProvider, now: Date) -> [UsageLimit] {
        switch provider {
        case .claude:
            getVisibleLimits(
                claudeLimits, hiddenKinds: decodeIDSet(UserDefaults.standard.string(forKey: hiddenKindsKey) ?? ""))
        case .codex:
            resetExpiredLimits(codexUsage?.limits ?? [], now: now)
        }
    }

    private func clearHeadsUp() {
        headsUpKey = nil
        headsUpProvider = nil
        ActivityCenter.shared.remove(id: headsUpActivityID)
    }

    func dismissHeadsUp() {
        if let headsUpKey { dismissedHeadsUpKeys.insert(headsUpKey) }
        updateHeadsUp()
    }

    func updateHeadsUp() {
        resetTask?.cancel()
        let now = Date.now
        dismissedHeadsUpKeys = pruneDismissedHeadsUpKeys(dismissedHeadsUpKeys, now: now)
        let shown = getShownProviders(
            showsClaude: readDefault(showsClaudeKey, default: true),
            showsCodex: readDefault(showsCodexKey, default: true)
        )
        let candidates = shown.flatMap { provider in getLimits(for: provider, now: now).map { (provider, $0) } }
        guard let (provider, limit) = getFullestProviderLimit(candidates) else {
            clearHeadsUp()
            return
        }
        let key = makeUsageHeadsUpKey(provider: provider, limit: limit)
        guard
            let priority = getUsageActivityPriority(
                limit,
                showsHeadsUp: readDefault(showsHeadsUpKey, default: true),
                threshold: readDefault(headsUpThresholdKey, default: defaultHeadsUpThreshold),
                isDismissed: dismissedHeadsUpKeys.contains(key),
                showsIdle: readDefault(showsIdleKey, default: true)
            )
        else {
            clearHeadsUp()
            return
        }
        let isHeadsUp = priority > .low
        headsUpKey = isHeadsUp ? key : nil
        headsUpProvider = isHeadsUp ? provider : nil
        let display =
            isHeadsUp
            ? (provider: provider, limit: limit)
            : getIdleProviderLimit(
                candidates, showsFullest: readDefault(idleShowsFullestKey, default: false), now: now)
                ?? (provider: provider, limit: limit)
        postActivity(display.provider, display.limit, priority: priority, isHeadsUp: isHeadsUp)
        if let resetsAt = display.limit.resetsAt, resetsAt > now {
            resetTask = Task { [weak self] in
                guard (try? await Task.sleep(for: .seconds(resetsAt.timeIntervalSince(now)))) != nil else { return }
                self?.updateHeadsUp()
            }
        }
    }

    private func postActivity(_ provider: AIProvider, _ limit: UsageLimit, priority: ActivityPriority, isHeadsUp: Bool)
    {
        ActivityCenter.shared.post(
            NotchActivity(
                id: headsUpActivityID,
                widgetID: NotchWidget.aiUsage.id,
                priority: priority,
                sortDate: limit.resetsAt ?? .distantFuture,
                makeLeading: {
                    AnyView(
                        HStack(spacing: 5) {
                            ProviderLogo(provider: provider, size: 13)
                            Text(getProviderName(provider))
                        }
                    )
                },
                makeTrailing: {
                    AnyView(
                        UsageNotchTrailing(limit: limit, showsReset: readDefault(showsNotchResetKey, default: true))
                    )
                },
                makeAlert: isHeadsUp ? { AnyView(UsageHeadsUpAlert(provider: provider, limit: limit)) } : nil
            )
        )
    }
}

/// The provider's own mark: Claude's in its brand colour, OpenAI's following the text colour.
private struct ProviderLogo: View {
    let provider: AIProvider
    let size: CGFloat

    var body: some View {
        Image(provider == .claude ? "ClaudeLogo" : "OpenAILogo")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private func getUsageColor(_ percent: Int) -> Color {
    switch getUsageLevel(percent) {
    case .comfortable: .accentColor
    case .high: .orange
    case .critical: .red
    }
}

private struct UsageBar: View {
    let percent: Int
    let showsRemaining: Bool

    var body: some View {
        GeometryReader { geometry in
            Capsule()
                .fill(Color.primary.opacity(0.12))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(getUsageColor(percent))
                        .frame(
                            width: geometry.size.width * getUsageBarFraction(percent, showsRemaining: showsRemaining))
                }
        }
        .frame(height: 5)
    }
}

private struct AIUsageView: View {
    @AppStorage(providerKey) private var storedProvider = ""
    @AppStorage(showsClaudeKey) private var showsClaude = true
    @AppStorage(showsCodexKey) private var showsCodex = true
    @AppStorage(hiddenKindsKey) private var storedHiddenKinds = ""
    @AppStorage(showsRemainingKey) private var showsRemaining = false
    private let store = AIUsageStore.shared

    var body: some View {
        let shown = getShownProviders(showsClaude: showsClaude, showsCodex: showsCodex)
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 12) {
                if let provider = resolveProvider(storedProvider, shown: shown) {
                    HStack(spacing: 4) {
                        ForEach(shown) { option in
                            ProviderButton(provider: option, isSelected: option == provider) {
                                storedProvider = option.rawValue
                            }
                        }
                        Spacer()
                        if store.headsUpProvider == provider {
                            Button("Dismiss", systemImage: "bell.slash") { store.dismissHeadsUp() }
                                .buttonStyle(.bordered)
                                .help("Hide this limit's reminder in the closed notch until it resets or runs out")
                        }
                        if provider == .codex,
                            let asOf = formatAsOf(store.codexUsage?.recordedAt, now: context.date, calendar: .current)
                        {
                            Text(asOf)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .help(
                                    "Codex records its limits while you use it, so these are from your last Codex session."
                                )
                        }
                    }
                    content(for: provider, now: context.date)
                } else {
                    Text("Turn on Claude or Codex in Settings → AI Usage.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
            }
            .padding(.horizontal, 10)
        }
        .onAppear { store.refreshIfStale() }
    }

    @ViewBuilder private func content(for provider: AIProvider, now: Date) -> some View {
        let limits = store.getLimits(for: provider, now: now)
        if !limits.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(limits) { limit in
                    LimitRow(limit: limit, showsRemaining: showsRemaining, now: now)
                }
            }
        } else if provider == .claude, let problem = store.claudeProblem {
            UsageProblemView(problem: problem)
        } else if provider == .codex, !store.isLoading {
            UsageProblemView(problem: .codexNotFound)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
        }
    }
}

private struct ProviderButton: View {
    let provider: AIProvider
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 6) {
                ProviderLogo(provider: provider, size: 14)
                Text(getProviderName(provider))
                    .font(.callout.weight(.medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? Color.primary.opacity(0.15) : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? .primary : .secondary)
    }
}

private struct LimitRow: View {
    let limit: UsageLimit
    let showsRemaining: Bool
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(formatLimitTitle(limit))
                    .font(.callout.weight(.medium))
                Spacer()
                Text(formatUsagePercent(limit.percent, showsRemaining: showsRemaining))
                    .font(.callout.weight(.semibold).monospacedDigit())
            }
            UsageBar(percent: limit.percent, showsRemaining: showsRemaining)
            if let reset = formatResetTime(limit.resetsAt, now: now) {
                Text(reset)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct UsageProblemView: View {
    let problem: ClaudeUsageProblem
    private let store = AIUsageStore.shared

    var body: some View {
        VStack(spacing: 10) {
            Text(getClaudeUsageProblemMessage(problem))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            switch problem {
            case .notConnected, .accessDeclined, .keychainError:
                Button("Connect Claude Code") { store.connectClaude() }
            case .notSignedIn, .loginExpired, .network, .unexpectedResponse, .codexNotFound, .keychainLocked:
                Button("Try Again", systemImage: "arrow.clockwise") { store.refresh() }
            }
        }
        .frame(maxWidth: 380)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

/// The percent in the closed notch, then when the limit resets, ticking each minute.
private struct UsageNotchTrailing: View {
    let limit: UsageLimit
    let showsReset: Bool

    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(
                ["\(limit.percent)%", showsReset ? formatShortResetTime(limit.resetsAt, now: context.date) : nil]
                    .compactMap { $0 }
                    .joined(separator: " · ")
            )
            .monospacedDigit()
        }
    }
}

/// Drops down under the heads-up when it first appears, saying which limit and when it resets.
private struct UsageHeadsUpAlert: View {
    let provider: AIProvider
    let limit: UsageLimit

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(getProviderName(provider)) · \(formatLimitTitle(limit))")
                .font(.title3.bold())
            Text(
                [formatUsagePercent(limit.percent, showsRemaining: false), formatResetTime(limit.resetsAt, now: .now)]
                    .compactMap { $0 }
                    .joined(separator: " · ")
            )
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 16)
    }
}

/// Each shown provider's fullest limit, for the Home tab.
private struct AIUsageSummary: View {
    @AppStorage(showsClaudeKey) private var showsClaude = true
    @AppStorage(showsCodexKey) private var showsCodex = true
    @AppStorage(hiddenKindsKey) private var storedHiddenKinds = ""
    @AppStorage(showsRemainingKey) private var showsRemaining = false
    private let store = AIUsageStore.shared

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 7) {
                ForEach(getShownProviders(showsClaude: showsClaude, showsCodex: showsCodex)) { provider in
                    let fullest = getFullestLimit(store.getLimits(for: provider, now: context.date), hiddenKinds: [])
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            ProviderLogo(provider: provider, size: 11)
                            Text(fullest.map(formatLimitTitle) ?? getProviderName(provider))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            Text(fullest.map { formatUsagePercent($0.percent, showsRemaining: showsRemaining) } ?? "–")
                                .fontWeight(.semibold)
                                .monospacedDigit()
                        }
                        .font(.caption)
                        UsageBar(percent: fullest?.percent ?? 0, showsRemaining: showsRemaining)
                    }
                }
            }
        }
    }
}

private struct AIUsageSettings: View {
    @AppStorage(showsClaudeKey) private var showsClaude = true
    @AppStorage(showsCodexKey) private var showsCodex = true
    @AppStorage(isClaudeConnectedKey) private var isClaudeConnected = false
    @AppStorage(hiddenKindsKey) private var storedHiddenKinds = ""
    @AppStorage(showsRemainingKey) private var showsRemaining = false
    @AppStorage(refreshMinutesKey) private var refreshMinutes = defaultRefreshMinutes
    @AppStorage(showsHeadsUpKey) private var showsHeadsUp = true
    @AppStorage(headsUpThresholdKey) private var headsUpThreshold = defaultHeadsUpThreshold
    @AppStorage(showsIdleKey) private var showsIdle = true
    @AppStorage(showsNotchResetKey) private var showsNotchReset = true
    @AppStorage(idleShowsFullestKey) private var idleShowsFullest = false
    private let store = AIUsageStore.shared

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $showsClaude) {
                    Label {
                        Text("Show Claude Code")
                    } icon: {
                        ProviderLogo(provider: .claude, size: 14)
                    }
                }
                LabeledContent("Claude Code login") {
                    if isClaudeConnected {
                        Button("Disconnect") { store.disconnectClaude() }
                    } else {
                        Button("Connect") { store.connectClaude() }
                    }
                }
                .disabled(!showsClaude)
                Toggle("Current session", isOn: makeVisibilityBinding(for: "session"))
                Toggle("Weekly · all models", isOn: makeVisibilityBinding(for: "weekly_all"))
                Toggle("Weekly · per model", isOn: makeVisibilityBinding(for: "weekly_scoped"))
            } header: {
                Text("Claude")
            } footer: {
                Text(
                    "CocoNotch reads only Claude Code's access token from the Keychain and sends it only to api.anthropic.com. It never refreshes your login, so Claude Code stays signed in. The usage service isn't documented and may change."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section {
                Toggle(isOn: $showsCodex) {
                    Label {
                        Text("Show Codex")
                    } icon: {
                        ProviderLogo(provider: .codex, size: 14)
                    }
                }
            } header: {
                Text("Codex")
            } footer: {
                Text(
                    "Codex records its limits in its session logs while you use it. CocoNotch reads only those numbers from ~/.codex/sessions, nothing else, and sends nothing anywhere."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section("Display") {
                Picker("Show usage as", selection: $showsRemaining) {
                    Text("Percent used").tag(false)
                    Text("Percent left").tag(true)
                }
                Picker("Refresh every", selection: $refreshMinutes) {
                    ForEach([1, 5, 15], id: \.self) { Text("\($0) min").tag($0) }
                }
            }
            Section("Heads-up") {
                Toggle("Show a heads-up in the closed notch near a limit", isOn: $showsHeadsUp)
                Picker("When a limit reaches", selection: $headsUpThreshold) {
                    ForEach([50, 75, 80, 90, 95], id: \.self) { Text("\($0)%").tag($0) }
                }
                .disabled(!showsHeadsUp)
                Toggle("Show usage in the closed notch when nothing else is", isOn: $showsIdle)
                Picker("Then show", selection: $idleShowsFullest) {
                    Text("The next limit to reset").tag(false)
                    Text("The fullest limit").tag(true)
                }
                .disabled(!showsIdle)
                Toggle("Show when the limit resets in the closed notch", isOn: $showsNotchReset)
            }
        }
        .formStyle(.grouped)
        .onChange(of: showsClaude) { store.refresh() }
        .onChange(of: showsCodex) { store.refresh() }
        .onChange(of: refreshMinutes) { store.restart() }
        .onChange(of: storedHiddenKinds) { store.updateHeadsUp() }
        .onChange(of: showsHeadsUp) { store.updateHeadsUp() }
        .onChange(of: headsUpThreshold) { store.updateHeadsUp() }
        .onChange(of: showsIdle) { store.updateHeadsUp() }
        .onChange(of: showsNotchReset) { store.updateHeadsUp() }
        .onChange(of: idleShowsFullest) { store.updateHeadsUp() }
    }

    // Stores hidden kinds rather than shown ones, so limits Claude adds later appear by default.
    private func makeVisibilityBinding(for kind: String) -> Binding<Bool> {
        Binding(
            get: { !decodeIDSet(storedHiddenKinds).contains(kind) },
            set: { isVisible in
                var hiddenKinds = decodeIDSet(storedHiddenKinds)
                if isVisible {
                    hiddenKinds.remove(kind)
                } else {
                    hiddenKinds.insert(kind)
                }
                storedHiddenKinds = encodeIDSet(hiddenKinds)
            }
        )
    }
}
