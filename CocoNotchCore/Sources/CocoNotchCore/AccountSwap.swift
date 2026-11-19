import Foundation

/// The Keychain item CocoNotch keeps saved logins in, so they're encrypted like the ones they were copied from.
public let savedAccountsService = "CocoNotch Saved Accounts"

/// A Claude Code login copied aside so it can be put back later, in Claude Code's own JSON.
public struct SavedAccount: Codable, Equatable, Identifiable, Sendable {
    /// Stays the same across token refreshes, so saving an account again replaces its old copy.
    public let id: String
    public let label: String
    /// The `claudeAiOauth` value from Claude Code's Keychain item.
    public let login: Data
    /// The `oauthAccount` value from `~/.claude.json`, which names the account Claude Code shows.
    public let profile: Data
    /// A name you pick, like "Work", shown instead of the email.
    public var alias: String?

    public var name: String { alias ?? label }

    public init(id: String, label: String, login: Data, profile: Data, alias: String? = nil) {
        self.id = id
        self.label = label
        self.login = login
        self.profile = profile
        self.alias = alias
    }
}

/// What `security find-generic-password -w` printed, as the stored bytes: it prints hex instead of text when the item
/// holds anything outside ASCII, like the "·" in a saved label. Stored items are always JSON, which hex never starts as.
public func decodeKeychainOutput(_ output: Data) -> Data? {
    let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("{") || text.hasPrefix("[") { return Data(text.utf8) }
    guard text.count.isMultiple(of: 2) else { return nil }
    var bytes = Data()
    var index = text.startIndex
    while index < text.endIndex {
        let next = text.index(index, offsetBy: 2)
        guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
        bytes.append(byte)
        index = next
    }
    return bytes
}

/// The JSON value under a top-level key, re-encoded on its own.
public func extractJSONValue(_ data: Data, key: String) -> Data? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let value = object[key],
        !(value is NSNull)
    else { return nil }
    return try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
}

/// The document with one top-level key replaced, leaving every other key as it was. Compact unless `isPretty`, since a
/// Keychain value must fit on one `security -i` line.
public func replaceJSONValue(_ data: Data, key: String, with value: Data, isPretty: Bool = false) -> Data? {
    guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let newValue = try? JSONSerialization.jsonObject(with: value, options: [.fragmentsAllowed])
    else { return nil }
    object[key] = newValue
    return try? JSONSerialization.data(
        withJSONObject: object, options: isPretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys])
}

/// The `security -i` line that stores `value` as a generic password, quoted so it never appears in the process list;
/// nil when it can't go whole, since that input reads 4096 bytes a line and runs anything past it as another command.
public func makeKeychainWriteCommand(_ value: Data, service: String, account: String) -> String? {
    guard let text = String(data: value, encoding: .utf8), !text.contains(where: \.isNewline) else { return nil }
    let quote = { (string: String) in
        "\"" + string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    let command = "add-generic-password -U -a \(quote(account)) -s \(quote(service)) -w \(quote(text))\n"
    return command.utf8.count < 4096 ? command : nil
}

private struct ClaudeProfile: Decodable {
    let accountUuid: String
    let organizationUuid: String?
    let emailAddress: String?
}

/// The active Claude Code login, from its Keychain item and `~/.claude.json`; nil when it isn't signed in.
public func getClaudeAccount(credentials: Data, config: Data) -> SavedAccount? {
    guard let login = extractJSONValue(credentials, key: "claudeAiOauth"),
        let profileData = extractJSONValue(config, key: "oauthAccount"),
        let profile = try? JSONDecoder().decode(ClaudeProfile.self, from: profileData)
    else { return nil }
    let label = profile.emailAddress ?? profile.accountUuid
    // One email can belong to a personal and a team organization, each with its own limits, so the id keeps both.
    return SavedAccount(
        id: "\(profile.accountUuid)/\(profile.organizationUuid ?? "")", label: label, login: login, profile: profileData
    )
}

/// The active Claude Code login, as far as keeping a copy of it before it's replaced goes.
public enum ActiveLogin: Equatable, Sendable {
    case signedIn(SavedAccount)
    /// Nothing to keep, so it's safe to replace.
    case signedOut
    /// A login may be there but couldn't be read, so it must not be replaced unsaved.
    case unreadable

    public var account: SavedAccount? {
        if case .signedIn(let account) = self { account } else { nil }
    }
}

/// Reads the active login from `security find-generic-password`'s exit code and output, and `~/.claude.json`. Only a
/// missing Keychain item (44) or one without a Claude login counts as signed out; anything else unreadable is unknown.
public func getActiveLogin(credentialsExitCode: Int32, credentials: Data?, config: Data?) -> ActiveLogin {
    if credentialsExitCode == 44 { return .signedOut }
    guard credentialsExitCode == 0, let credentials,
        (try? JSONSerialization.jsonObject(with: credentials)) is [String: Any]
    else { return .unreadable }
    guard extractJSONValue(credentials, key: "claudeAiOauth") != nil else { return .signedOut }
    // A login is there, so failing to name it from the config is unknown, not signed out.
    return config.flatMap { getClaudeAccount(credentials: credentials, config: $0) }.map(ActiveLogin.signedIn)
        ?? .unreadable
}

private func getJSONObject(_ data: Data?, key: String) -> NSObject? {
    data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?[key] as? NSObject
}

/// Whether two reads of Claude Code's Keychain item and `~/.claude.json` found the same login and profile. Signing in
/// writes the two separately, so a read between them would pair one account's tokens with another's profile.
public func isSameLogin(credentials: Data?, credentialsAgain: Data?, config: Data?, configAgain: Data?) -> Bool {
    getJSONObject(credentials, key: "claudeAiOauth") == getJSONObject(credentialsAgain, key: "claudeAiOauth")
        && getJSONObject(config, key: "oauthAccount") == getJSONObject(configAgain, key: "oauthAccount")
}

/// Whether the Keychain and `~/.claude.json` may name different accounts after a switch, which writes the Keychain
/// first: writing both fixes it, undoing the Keychain write leaves things as they were, and failing both causes it.
public func isLoginMismatched(wasMismatched: Bool, isConfigWritten: Bool, isRestored: Bool) -> Bool {
    if isConfigWritten { return false }
    return isRestored ? wasMismatched : true
}

/// Whether a refresh saves the active login on its own: only while signing in to another account, and only one that's
/// neither `signingInFromID` (nil when signed out) nor already saved. A refresh can catch `claude /login` halfway, with
/// one account's tokens under the other's profile, so it never writes over a copy that was already saved.
public func shouldSaveActiveAccount(
    _ saved: [SavedAccount], activeID: String, isSigningIn: Bool, signingInFromID: String?
) -> Bool {
    isSigningIn && activeID != signingInFromID && !saved.contains { $0.id == activeID }
}

/// The saved accounts with this one added, or replacing its older copy in place.
public func upsertSavedAccount(_ accounts: [SavedAccount], _ account: SavedAccount) -> [SavedAccount] {
    guard let index = accounts.firstIndex(where: { $0.id == account.id }) else {
        return accounts + [account]
    }
    var updated = accounts
    updated[index] = account
    // A login read fresh from Claude Code has no alias, so the one already given is kept.
    updated[index].alias = account.alias ?? accounts[index].alias
    return updated
}

/// The saved accounts with one renamed; a blank alias goes back to the email.
public func setAccountAlias(_ accounts: [SavedAccount], _ account: SavedAccount, alias: String) -> [SavedAccount] {
    let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
    return accounts.map { saved in
        guard saved.id == account.id else { return saved }
        var renamed = saved
        renamed.alias = trimmed.isEmpty ? nil : trimmed
        return renamed
    }
}
