import CocoNotchCore
import Security
import SwiftUI

extension NotchWidget {
    static let claudeUsage = NotchWidget(
        id: "claudeUsage",
        title: "Claude Code",
        systemImage: "sparkles",
        makeView: { AnyView(ClaudeUsageView()) },
        makeSettings: { AnyView(ClaudeUsageSettings()) },
        makeSummary: { AnyView(ClaudeUsageSummary()) },
        makeSummarySettings: { AnyView(ClaudeUsageSummarySettings()) }
    )
}

// Only set from the Connect button, so the Keychain prompt never appears unasked.
private let isConnectedKey = "claudeUsage.isConnected"
private let hiddenKindsKey = "claudeUsage.hiddenKinds"
private let showsRemainingKey = "claudeUsage.showsRemaining"
private let refreshMinutesKey = "claudeUsage.refreshMinutes"
private let showsHeadsUpKey = "claudeUsage.showsHeadsUp"
private let headsUpThresholdKey = "claudeUsage.headsUpThreshold"
private let summaryCountKey = "claudeUsage.summaryCount"
private let defaultRefreshMinutes = 5
private let defaultHeadsUpThreshold = 80
private let defaultSummaryCount = 2
private let headsUpActivityID = "claudeUsage.headsUp"

private enum CredentialsResult: Sendable {
    case found(ClaudeCredentials)
    case missing
    case denied
}

/// Blocks while macOS asks for permission, so it runs off the main thread. Only the Claude login is kept from the
/// item; the other tokens Claude Code stores there are dropped as soon as it is parsed.
nonisolated private func readClaudeCredentials() -> CredentialsResult {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: claudeCredentialsService,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    switch SecItemCopyMatching(query as CFDictionary, &item) {
    case errSecSuccess:
        guard let data = item as? Data, let credentials = parseClaudeCredentials(data) else { return .missing }
        return .found(credentials)
    case errSecItemNotFound:
        return .missing
    default:
        return .denied
    }
}

/// Loads usage for the whole app, so the Home card and the heads-up work without opening the tab.
@Observable
final class ClaudeUsageStore {
    static let shared = ClaudeUsageStore()

    private(set) var limits: [UsageLimit] = []
    private(set) var problem: ClaudeUsageProblem?
    private(set) var isLoading = false
    private(set) var updatedAt: Date?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                let minutes = UserDefaults.standard.object(forKey: refreshMinutesKey) as? Int ?? defaultRefreshMinutes
                try? await Task.sleep(for: .seconds(minutes * 60))
            }
        }
    }

    /// Opening the tab reloads only numbers older than a minute, so hovering doesn't hit the Keychain and network.
    func refreshIfStale() {
        if isStale(updatedAt: updatedAt, now: .now, maxAge: 60) { refresh() }
    }

    func connect() {
        UserDefaults.standard.set(true, forKey: isConnectedKey)
        refresh()
    }

    func disconnect() {
        UserDefaults.standard.set(false, forKey: isConnectedKey)
        refresh()
    }

    /// Reloads now. Nothing is read or sent while the widget is off or not connected.
    func refresh() {
        let preferences = NotchWidget.getPreferences(
            stored: UserDefaults.standard.string(forKey: PreferenceKey.widgetPreferences) ?? "")
        guard getEnabledWidgetIDs(preferences).contains(NotchWidget.claudeUsage.id),
            UserDefaults.standard.bool(forKey: isConnectedKey)
        else {
            loadTask?.cancel()
            show(.notConnected)
            return
        }
        loadTask?.cancel()
        loadTask = Task { await load() }
    }

    private func show(_ problem: ClaudeUsageProblem) {
        self.problem = problem
        limits = []
        isLoading = false
        updateHeadsUp()
    }

    private func load() async {
        isLoading = true
        defer { if !Task.isCancelled { isLoading = false } }
        let result = await Task.detached { readClaudeCredentials() }.value
        guard !Task.isCancelled else { return }
        switch result {
        case .missing:
            show(.notSignedIn)
        case .denied:
            // The user declined the Keychain prompt; they can connect again from the tab.
            UserDefaults.standard.set(false, forKey: isConnectedKey)
            show(.notConnected)
        case .found(let credentials):
            guard !isClaudeTokenExpired(credentials, now: .now) else {
                show(.loginExpired)
                return
            }
            await fetchUsage(token: credentials.accessToken)
        }
    }

    private func fetchUsage(token: String) async {
        guard let url = claudeUsageURL else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled else { return }
            if let problem = getClaudeUsageProblem(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0) {
                show(problem)
                return
            }
            limits = try parseClaudeUsage(data)
            problem = nil
            updatedAt = .now
        } catch is DecodingError {
            show(.unexpectedResponse)
            return
        } catch {
            guard !Task.isCancelled else { return }
            // Keeps the last numbers through a short outage rather than blanking the widget.
            if limits.isEmpty { problem = .network }
        }
        updateHeadsUp()
    }

    func updateHeadsUp() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: showsHeadsUpKey) as? Bool ?? true,
            let limit = getUsageHeadsUpLimit(
                limits,
                hiddenKinds: decodeIDSet(defaults.string(forKey: hiddenKindsKey) ?? ""),
                threshold: defaults.object(forKey: headsUpThresholdKey) as? Int ?? defaultHeadsUpThreshold
            )
        else {
            ActivityCenter.shared.remove(id: headsUpActivityID)
            return
        }
        ActivityCenter.shared.post(
            NotchActivity(
                id: headsUpActivityID,
                widgetID: NotchWidget.claudeUsage.id,
                priority: getUsagePriority(limit),
                sortDate: limit.resetsAt ?? .distantFuture,
                makeLeading: {
                    AnyView(
                        Label("Claude", systemImage: NotchWidget.claudeUsage.systemImage)
                            .foregroundStyle(.orange)
                    )
                },
                makeTrailing: { AnyView(Text("\(limit.percent)%").monospacedDigit()) },
                makeAlert: { AnyView(UsageHeadsUpAlert(limit: limit)) }
            )
        )
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

private struct ClaudeUsageView: View {
    @AppStorage(hiddenKindsKey) private var storedHiddenKinds = ""
    @AppStorage(showsRemainingKey) private var showsRemaining = false
    private let store = ClaudeUsageStore.shared

    var body: some View {
        Group {
            if !store.limits.isEmpty {
                TimelineView(.everyMinute) { context in
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(getVisibleLimits(store.limits, hiddenKinds: decodeIDSet(storedHiddenKinds))) { limit in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(formatLimitTitle(limit))
                                        .font(.callout.weight(.medium))
                                    Spacer()
                                    Text(formatUsagePercent(limit.percent, showsRemaining: showsRemaining))
                                        .font(.callout.weight(.semibold).monospacedDigit())
                                }
                                UsageBar(percent: limit.percent, showsRemaining: showsRemaining)
                                if let reset = formatResetTime(limit.resetsAt, now: context.date) {
                                    Text(reset)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                }
            } else if let problem = store.problem {
                ClaudeUsageProblemView(problem: problem)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            }
        }
        .onAppear { store.refreshIfStale() }
    }
}

private struct ClaudeUsageProblemView: View {
    let problem: ClaudeUsageProblem
    private let store = ClaudeUsageStore.shared

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: NotchWidget.claudeUsage.systemImage)
                .font(.title)
                .foregroundStyle(.secondary)
            Text(getClaudeUsageProblemMessage(problem))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            switch problem {
            case .notConnected:
                Button("Connect Claude Code") { store.connect() }
            case .notSignedIn, .loginExpired, .network, .unexpectedResponse:
                Button("Try Again", systemImage: "arrow.clockwise") { store.refresh() }
            }
        }
        .frame(maxWidth: 380)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}

/// Drops down under the heads-up when it first appears, saying which limit and when it resets.
private struct UsageHeadsUpAlert: View {
    let limit: UsageLimit

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(formatLimitTitle(limit))
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

/// The first few shown limits, for the Home tab.
private struct ClaudeUsageSummary: View {
    @AppStorage(hiddenKindsKey) private var storedHiddenKinds = ""
    @AppStorage(showsRemainingKey) private var showsRemaining = false
    @AppStorage(summaryCountKey) private var summaryCount = defaultSummaryCount
    private let store = ClaudeUsageStore.shared

    var body: some View {
        if store.limits.isEmpty {
            Text(store.problem.map(getClaudeUsageProblemMessage) ?? "Loading usage…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(
                    getVisibleLimits(store.limits, hiddenKinds: decodeIDSet(storedHiddenKinds)).prefix(summaryCount)
                ) { limit in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(formatLimitTitle(limit))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            Text(formatUsagePercent(limit.percent, showsRemaining: showsRemaining))
                                .fontWeight(.semibold)
                                .monospacedDigit()
                        }
                        .font(.caption)
                        UsageBar(percent: limit.percent, showsRemaining: showsRemaining)
                    }
                }
            }
        }
    }
}

private struct ClaudeUsageSummarySettings: View {
    @AppStorage(summaryCountKey) private var summaryCount = defaultSummaryCount

    var body: some View {
        Picker("Limits shown", selection: $summaryCount) {
            ForEach(1...3, id: \.self) { Text("\($0)").tag($0) }
        }
    }
}

private struct ClaudeUsageSettings: View {
    @AppStorage(isConnectedKey) private var isConnected = false
    @AppStorage(hiddenKindsKey) private var storedHiddenKinds = ""
    @AppStorage(showsRemainingKey) private var showsRemaining = false
    @AppStorage(refreshMinutesKey) private var refreshMinutes = defaultRefreshMinutes
    @AppStorage(showsHeadsUpKey) private var showsHeadsUp = true
    @AppStorage(headsUpThresholdKey) private var headsUpThreshold = defaultHeadsUpThreshold
    private let store = ClaudeUsageStore.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Claude Code login") {
                    if isConnected {
                        Button("Disconnect") { store.disconnect() }
                    } else {
                        Button("Connect") { store.connect() }
                    }
                }
            } footer: {
                Text(
                    "CocoNotch reads only Claude Code's access token from the Keychain and sends it only to api.anthropic.com. It never refreshes your login, so Claude Code stays signed in. The usage service isn't documented and may change."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section("Limits") {
                Toggle("Current session", isOn: makeVisibilityBinding(for: "session"))
                Toggle("Weekly · all models", isOn: makeVisibilityBinding(for: "weekly_all"))
                Toggle("Weekly · per model", isOn: makeVisibilityBinding(for: "weekly_scoped"))
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
            }
        }
        .formStyle(.grouped)
        .onChange(of: storedHiddenKinds) { store.updateHeadsUp() }
        .onChange(of: showsHeadsUp) { store.updateHeadsUp() }
        .onChange(of: headsUpThreshold) { store.updateHeadsUp() }
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
