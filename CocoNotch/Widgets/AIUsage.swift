import CocoNotchCore
import Security
import SwiftUI

extension NotchWidget {
    static let aiUsage = NotchWidget(
        id: "aiUsage",
        title: String(localized: "AI Usage"),
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
// Only set from the Enable button, so the Keychain prompt never appears unasked.
private let isClaudeConnectedKey = "aiUsage.isClaudeConnected"
private let hiddenKindsKey = "aiUsage.hiddenKinds"
private let showsRemainingKey = "aiUsage.showsRemaining"
private let refreshMinutesKey = "aiUsage.refreshMinutes"
private let showsHeadsUpKey = "aiUsage.showsHeadsUp"
private let headsUpThresholdKey = "aiUsage.headsUpThreshold"
private let showsIdleKey = "aiUsage.showsIdle"
private let showsNotchResetKey = "aiUsage.showsNotchReset"
private let idleShowsFullestKey = "aiUsage.idleShowsFullest"
private let showsAccountsKey = "aiUsage.showsAccounts"
private let showsNotchAliasKey = "aiUsage.showsNotchAlias"
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
    let (status, data) = runSecurity(["find-generic-password", "-s", claudeCredentialsService, "-w"])
    if let problem = getCredentialsProblem(exitCode: status) { return .failed(problem) }
    guard let credentials = decodeKeychainOutput(data).flatMap(parseClaudeCredentials) else {
        return .failed(.notSignedIn)
    }
    return .found(credentials)
}

/// Runs /usr/bin/security; secrets go in through `input`, so they never show up in the process list.
nonisolated private func runSecurity(_ arguments: [String], input: Data? = nil) -> (status: Int32, output: Data) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = arguments
    let output = Pipe()
    let stdin = Pipe()
    process.standardOutput = output
    process.standardInput = stdin
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return (-1, Data())
    }
    if let input { stdin.fileHandleForWriting.write(input) }
    try? stdin.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, data)
}

nonisolated private func readKeychain(service: String) -> Data? {
    let (status, data) = runSecurity(["find-generic-password", "-s", service, "-a", NSUserName(), "-w"])
    return status == 0 ? decodeKeychainOutput(data) : nil
}

nonisolated private func writeKeychain(_ data: Data, service: String) -> Bool {
    guard let command = makeKeychainWriteCommand(data, service: service, account: NSUserName()) else { return false }
    return runSecurity(["-i"], input: Data(command.utf8)).status == 0
}

nonisolated private let claudeConfigURL = FileManager.default.homeDirectoryForCurrentUser.appending(
    path: ".claude.json")
// Set while the Keychain and ~/.claude.json may name different accounts, and kept across restarts until a switch
// rewrites both, so a mixed pair is never saved over one account's backup.
nonisolated private let isLoginMismatchedKey = "aiUsage.isLoginMismatched"

nonisolated private func readActiveAccount() -> SavedAccount? {
    guard !UserDefaults.standard.bool(forKey: isLoginMismatchedKey),
        let credentials = readKeychain(service: claudeCredentialsService),
        let config = try? Data(contentsOf: claudeConfigURL)
    else { return nil }
    return getClaudeAccount(credentials: credentials, config: config)
}

nonisolated private func activateAccount(_ account: SavedAccount) -> Bool {
    // ponytail: Claude Code may write ~/.claude.json at the same moment; a lock would need its cooperation.
    guard let credentials = readKeychain(service: claudeCredentialsService),
        let config = try? Data(contentsOf: claudeConfigURL),
        let newCredentials = replaceJSONValue(credentials, key: "claudeAiOauth", with: account.login),
        let newConfig = replaceJSONValue(config, key: "oauthAccount", with: account.profile, isPretty: true),
        writeKeychain(newCredentials, service: claudeCredentialsService)
    else { return false }
    let isConfigWritten = (try? newConfig.write(to: claudeConfigURL, options: .atomic)) != nil
    // Puts the old login back when the config can't follow, so the Keychain and ~/.claude.json name the same account.
    let isRestored = isConfigWritten || writeKeychain(credentials, service: claudeCredentialsService)
    let defaults = UserDefaults.standard
    defaults.set(
        isLoginMismatched(
            wasMismatched: defaults.bool(forKey: isLoginMismatchedKey), isConfigWritten: isConfigWritten,
            isRestored: isRestored),
        forKey: isLoginMismatchedKey)
    guard isConfigWritten else { return false }
    // The file holds the login's profile, so it stays readable only by you, as Claude Code leaves it.
    return (try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: claudeConfigURL.path))
        != nil
}

// CocoNotch's own item, so it goes through the Security framework: no line limit, and no process to see the value.
nonisolated private func makeSavedAccountsQuery() -> [String: Any] {
    [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: savedAccountsService,
        kSecAttrAccount as String: NSUserName(),
    ]
}

/// nil when the list can't be read, so a locked Keychain is never taken for an empty list and overwritten.
nonisolated private func readSavedAccounts() -> [SavedAccount]? {
    var query = makeSavedAccountsQuery()
    query[kSecReturnData as String] = true
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return [] }
    guard status == errSecSuccess, let data = result as? Data else { return nil }
    return try? JSONDecoder().decode([SavedAccount].self, from: data)
}

nonisolated private func writeSavedAccounts(_ accounts: [SavedAccount]) -> Bool {
    guard let data = try? JSONEncoder().encode(accounts) else { return false }
    let query = makeSavedAccountsQuery()
    let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    guard status == errSecItemNotFound else { return status == errSecSuccess }
    var item = query
    item[kSecValueData as String] = data
    return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
}

private struct AccountSnapshot: Sendable {
    let version: Int
    let accounts: [SavedAccount]
    let activeID: String?
    let didChange: Bool
}

/// Runs every change to the saved accounts one at a time, each on a fresh read, so two quick changes can't overwrite
/// each other. The version lets the store skip a result that a later change has already replaced.
private actor AccountVault {
    static let shared = AccountVault()
    private var version = 0

    func update(_ change: @Sendable (_ saved: [SavedAccount], _ active: SavedAccount?) -> [SavedAccount])
        -> AccountSnapshot?
    {
        guard let saved = readSavedAccounts() else { return nil }
        let active = readActiveAccount()
        let updated = change(saved, active)
        guard updated == saved || writeSavedAccounts(updated) else { return nil }
        version += 1
        return AccountSnapshot(version: version, accounts: updated, activeID: active?.id, didChange: updated != saved)
    }

    /// Saves the active login first: its refresh token has rotated since it was saved, and the old one no longer works.
    func switchTo(_ id: String) -> AccountSnapshot? {
        guard let saved = readSavedAccounts() else { return nil }
        let active = readActiveAccount()
        let updated = active.map { upsertSavedAccount(saved, $0) } ?? saved
        // The copy just read, not the one the menu showed, whose token may have rotated since.
        guard let target = updated.first(where: { $0.id == id }), writeSavedAccounts(updated),
            active?.id == id || activateAccount(target)
        else { return nil }
        version += 1
        return AccountSnapshot(version: version, accounts: updated, activeID: id, didChange: true)
    }
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
    /// Whose limit the heads-up is about, so the tab offers Dismiss only on that provider.
    private(set) var headsUpProvider: AIProvider?
    @ObservationIgnored private var dismissedHeadsUps: [String: UsageLimit] = [:]
    private(set) var savedAccounts: [SavedAccount] = []
    private(set) var activeAccountID: String?
    private(set) var isAccountSwitchFailed = false
    @ObservationIgnored private var isAddingAccount = false
    @ObservationIgnored private var accountsVersion = 0

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
        // Before usage, so signing in to another account clears the old numbers rather than the new ones.
        if readDefault(showsAccountsKey, default: true) { await loadAccounts() }
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

    /// Claude Code's login is read only once its usage is on and enabled, so the Keychain is never touched unasked.
    private func loadAccounts() async {
        guard readDefault(showsClaudeKey, default: true), UserDefaults.standard.bool(forKey: isClaudeConnectedKey)
        else { return }
        let isAdding = isAddingAccount
        let snapshot = await AccountVault.shared.update { saved, active in
            // After Add Account, the login you make next is saved without a trip back to the menu.
            guard isAdding, let active, !saved.contains(where: { $0.id == active.id }) else { return saved }
            return upsertSavedAccount(saved, active)
        }
        guard let snapshot else { return }
        if snapshot.didChange { isAddingAccount = false }
        publish(snapshot)
    }

    /// Shows the newest result, so one change finishing after a later one can't bring back the older list.
    private func publish(_ snapshot: AccountSnapshot) {
        guard snapshot.version > accountsVersion else { return }
        accountsVersion = snapshot.version
        savedAccounts = snapshot.accounts
        // Another account's numbers would otherwise stay up under this one's name until a fetch succeeds.
        if activeAccountID != nil, snapshot.activeID != activeAccountID {
            claudeLimits = []
            claudeProblem = nil
        }
        activeAccountID = snapshot.activeID
        updateHeadsUp()
    }

    /// nil means the change failed, which the menu says.
    @discardableResult private func report(_ snapshot: AccountSnapshot?) -> Bool {
        isAccountSwitchFailed = snapshot == nil
        guard let snapshot else { return false }
        publish(snapshot)
        return true
    }

    /// Saves the current login, then opens Terminal to sign in to another one.
    func addAccount() {
        Task {
            // Signing in replaces the current login, so Terminal opens only once a copy of it is safely saved.
            guard await saveActiveAccount() else { return }
            isAddingAccount = true
            let script = FileManager.default.temporaryDirectory.appending(path: "claude-login.command")
            // A login shell, so `claude` is on the PATH the way it is in your own terminal.
            guard (try? Data("#!/bin/zsh -l\nclaude /login\n".utf8).write(to: script)) != nil,
                (try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)) != nil
            else { return }
            NSWorkspace.shared.open(script)
        }
    }

    func reloadAccounts() {
        Task {
            await loadAccounts()
            updateHeadsUp()
        }
    }

    func setAlias(_ alias: String, for account: SavedAccount) {
        guard setAccountAlias(savedAccounts, account, alias: alias) != savedAccounts else { return }
        Task { report(await AccountVault.shared.update { saved, _ in setAccountAlias(saved, account, alias: alias) }) }
    }

    func rememberActiveAccount() {
        Task { await saveActiveAccount() }
    }

    @discardableResult private func saveActiveAccount() async -> Bool {
        let snapshot = await AccountVault.shared.update { saved, active in
            active.map { upsertSavedAccount(saved, $0) } ?? saved
        }
        return report(snapshot?.activeID == nil ? nil : snapshot)
    }

    func switchAccount(to account: SavedAccount) {
        let id = account.id
        Task { if report(await AccountVault.shared.switchTo(id)) { refresh() } }
    }

    func forgetAccount(_ account: SavedAccount) {
        let id = account.id
        Task { report(await AccountVault.shared.update { saved, _ in saved.filter { $0.id != id } }) }
    }

    /// The limits to show for a provider, with reset windows at zero: Claude's chosen kinds, or Codex's snapshot.
    func getLimits(for provider: AIProvider, now: Date, showsHidden: Bool = false) -> [UsageLimit] {
        switch provider {
        case .claude:
            getVisibleLimits(
                resetExpiredLimits(claudeLimits, now: now),
                hiddenKinds: showsHidden ? [] : decodeIDSet(UserDefaults.standard.string(forKey: hiddenKindsKey) ?? ""))
        case .codex:
            resetExpiredLimits(codexUsage?.limits ?? [], now: now)
        }
    }

    private func clearHeadsUp() {
        headsUpProvider = nil
        ActivityCenter.shared.remove(id: headsUpActivityID)
    }

    /// Silences every limit over the threshold, not just the fullest, so another one overtaking it doesn't alert again.
    func dismissHeadsUp() {
        let due = getDueUsageHeadsUps(getCandidates(now: .now), threshold: getThreshold())
        dismissedHeadsUps = mergeDismissedHeadsUps(dismissedHeadsUps, due)
        updateHeadsUp()
    }

    private func getCandidates(now: Date, showsHidden: Bool = false) -> [(provider: AIProvider, limit: UsageLimit)] {
        let shown = getShownProviders(
            showsClaude: readDefault(showsClaudeKey, default: true),
            showsCodex: readDefault(showsCodexKey, default: true)
        )
        return shown.flatMap { provider in
            getLimits(for: provider, now: now, showsHidden: showsHidden).map { (provider, $0) }
        }
    }

    private func getThreshold() -> Int {
        readDefault(headsUpThresholdKey, default: defaultHeadsUpThreshold)
    }

    func updateHeadsUp() {
        resetTask?.cancel()
        let now = Date.now
        let candidates = getCandidates(now: now)
        // Hidden limits count, so hiding one and showing it again doesn't bring its dismissed heads-up back.
        let due = getDueUsageHeadsUps(getCandidates(now: now, showsHidden: true), threshold: getThreshold())
        dismissedHeadsUps = pruneDismissedHeadsUps(dismissedHeadsUps, due: due, now: now)
        guard let (provider, limit) = getHeadsUpProviderLimit(candidates, dismissed: dismissedHeadsUps) else {
            clearHeadsUp()
            return
        }
        guard
            let priority = getUsageActivityPriority(
                limit,
                showsHeadsUp: readDefault(showsHeadsUpKey, default: true),
                threshold: getThreshold(),
                isDismissed: isUsageHeadsUpDismissed(provider: provider, limit: limit, dismissed: dismissedHeadsUps),
                showsIdle: readDefault(showsIdleKey, default: true)
            )
        else {
            clearHeadsUp()
            return
        }
        let isHeadsUp = priority > .low
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
        let alias =
            provider == .claude && readDefault(showsNotchAliasKey, default: true)
            ? savedAccounts.first { $0.id == activeAccountID }?.alias : nil
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
                            Text(alias ?? getProviderName(provider))
                        }
                    )
                },
                makeTrailing: {
                    AnyView(
                        UsageNotchTrailing(limit: limit, showsReset: readDefault(showsNotchResetKey, default: true))
                    )
                },
                makeCompact: {
                    AnyView(
                        HStack(spacing: 5) {
                            ProviderLogo(provider: provider, size: 13)
                            UsageNotchTrailing(limit: limit, showsReset: readDefault(showsNotchResetKey, default: true))
                        }
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
    @AppStorage(showsAccountsKey) private var showsAccounts = true
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
                        if showsAccounts && provider == .claude { AccountMenu() }
                        if store.headsUpProvider == provider {
                            Button("Dismiss", systemImage: "bell.slash") { store.dismissHeadsUp() }
                                .buttonStyle(.bordered)
                                .help("Hide until usage drops below the threshold and climbs back, or runs out")
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

/// Switches Claude Code's login between the saved ones.
private struct AccountMenu: View {
    @AppStorage(isClaudeConnectedKey) private var isClaudeConnected = false
    @Environment(\.showSettings) private var showSettings
    private let store = AIUsageStore.shared

    var body: some View {
        let saved = store.savedAccounts
        let activeID = store.activeAccountID
        Menu {
            if store.isAccountSwitchFailed {
                Text("Couldn't change accounts. Check that you're signed in, then try again.")
            }
            ForEach(saved) { account in
                Toggle(
                    account.name,
                    isOn: Binding(
                        get: { account.id == activeID },
                        set: { _ in if account.id != activeID { store.switchAccount(to: account) } }
                    ))
            }
            if !saved.isEmpty { Divider() }
            Button("Add Account…") { store.addAccount() }
            if saved.contains(where: { $0.id == activeID }) {
                Button("Set Alias…") { showSettings(.widget(NotchWidget.aiUsage.id)) }
            } else {
                Button("Remember Current Account") { store.rememberActiveAccount() }
                    .disabled(activeID == nil)
            }
            if !saved.isEmpty {
                Menu("Forget") {
                    ForEach(saved) { account in
                        Button(account.name) { store.forgetAccount(account) }
                    }
                }
            }
        } label: {
            // Drawn by hand: a borderless menu pads its label, so it wouldn't line up with the bars below.
            HStack(spacing: 4) {
                Image(systemName: "person.crop.circle")
                Text(saved.first { $0.id == activeID }?.name ?? String(localized: "Accounts"))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .font(.callout.weight(.medium))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!isClaudeConnected)
        .help("Switch which account Claude Code signs in with. Running sessions keep theirs until restarted.")
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
        WidgetPrompt(systemImage: NotchWidget.aiUsage.systemImage, message: getClaudeUsageProblemMessage(problem)) {
            switch problem {
            case .notConnected, .accessDeclined, .keychainError:
                Button("Enable Claude Code Usage") { store.connectClaude() }
            case .notSignedIn, .loginExpired, .network, .unexpectedResponse, .codexNotFound, .keychainLocked:
                Button("Try Again", systemImage: "arrow.clockwise") { store.refresh() }
            }
        }
        // The provider tabs above already space the stack, so the prompt's own top padding would double it.
        .padding(.top, -12)
    }
}

/// The percent in the closed notch, then when the limit resets, ticking each minute.
private struct UsageNotchTrailing: View {
    let limit: UsageLimit
    let showsReset: Bool

    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(formatUsageNotchLabel(limit, showsReset: showsReset, now: context.date))
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

/// Claude Code's saved logins, renamed like Time Zones: the name is plain text until you double-click it or use ✎.
private struct ClaudeAccountsSection: View {
    @AppStorage(showsAccountsKey) private var showsAccounts = true
    @AppStorage(showsNotchAliasKey) private var showsNotchAlias = true
    @State private var editingID: String?
    @State private var aliasDraft = ""
    @FocusState private var focusedAliasID: String?
    private let store = AIUsageStore.shared

    var body: some View {
        Section {
            Toggle("Show the account switcher", isOn: $showsAccounts)
            if showsAccounts {
                ForEach(store.savedAccounts) { account in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            if editingID == account.id {
                                TextField("Alias", text: $aliasDraft, prompt: Text(account.label))
                                    .textFieldStyle(.roundedBorder)
                                    .labelsHidden()
                                    .focused($focusedAliasID, equals: account.id)
                                    .onSubmit { finishEditing() }
                                    .onAppear { focusedAliasID = account.id }
                            } else {
                                Text(account.name)
                                    .onTapGesture(count: 2) { startEditing(account) }
                            }
                            // Names the real account, which an alias would otherwise hide.
                            if account.alias != nil {
                                Text(account.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                        Spacer()
                        Button("Rename", systemImage: "pencil") { startEditing(account) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Set an alias; leave it empty to use the email")
                        Button("Forget", systemImage: "minus.circle") { store.forgetAccount(account) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                }
                Toggle("Show the alias in the closed notch", isOn: $showsNotchAlias)
            }
        } header: {
            Text("Claude Code Accounts")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    "Remember the account you're signed in with, sign in to another with claude /login, and remember that one too. Then switch between them from the AI Usage tab. Saved logins stay in your Keychain. Sessions already running keep their account until you restart them."
                )
                Text("Double-click a name or use ✎ to give it an alias.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .onChange(of: focusedAliasID) { lost, gained in
            if gained == nil, lost == editingID { finishEditing() }
        }
        .onDisappear { finishEditing() }
    }

    private func startEditing(_ account: SavedAccount) {
        finishEditing()
        aliasDraft = account.alias ?? ""
        editingID = account.id
    }

    // Saved when editing ends, not per keystroke, since each save rewrites the Keychain item.
    private func finishEditing() {
        if let account = store.savedAccounts.first(where: { $0.id == editingID }) {
            store.setAlias(aliasDraft, for: account)
        }
        editingID = nil
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
    @AppStorage(showsAccountsKey) private var showsAccounts = true
    @AppStorage(showsNotchAliasKey) private var showsNotchAlias = true
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
                LabeledContent("Read Claude Code's login") {
                    if isClaudeConnected {
                        Button("Disable") { store.disconnectClaude() }
                    } else {
                        Button("Enable") { store.connectClaude() }
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
            ClaudeAccountsSection()
                .disabled(!showsClaude || !isClaudeConnected)
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
                    "Codex records its limits in its session logs while you use it. CocoNotch reads the end of your latest logs in ~/.codex/sessions, keeps only those numbers, and sends nothing anywhere."
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
        .onChange(of: showsAccounts) { store.refresh() }
        .onChange(of: showsNotchAlias) { store.updateHeadsUp() }
        .onAppear { if showsAccounts { store.reloadAccounts() } }
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
