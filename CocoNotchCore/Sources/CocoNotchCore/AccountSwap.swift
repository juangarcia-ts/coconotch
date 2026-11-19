import Foundation

/// The Keychain item CocoNotch keeps saved logins in, so they're encrypted like the ones they were copied from.
public let savedAccountsService = "CocoNotch-saved-accounts"

/// A login copied aside so it can be put back later. `login` is the provider's own JSON, kept as is.
public struct SavedAccount: Codable, Equatable, Identifiable, Sendable {
    public let provider: AIProvider
    /// Stays the same across token refreshes, so saving an account again replaces its old copy.
    public let id: String
    public let label: String
    /// Claude's `claudeAiOauth` value from the Keychain item, or Codex's whole `auth.json`.
    public let login: Data
    /// Claude's `oauthAccount` value from `~/.claude.json`, which names the account Claude Code shows.
    public let profile: Data?

    public init(provider: AIProvider, id: String, label: String, login: Data, profile: Data?) {
        self.provider = provider
        self.id = id
        self.label = label
        self.login = login
        self.profile = profile
    }
}

/// The JSON value under a top-level key, re-encoded on its own.
public func extractJSONValue(_ data: Data, key: String) -> Data? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let value = object[key],
        !(value is NSNull)
    else { return nil }
    return try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
}

/// The document with one top-level key replaced, leaving every other key as it was.
public func replaceJSONValue(_ data: Data, key: String, with value: Data) -> Data? {
    guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let newValue = try? JSONSerialization.jsonObject(with: value, options: [.fragmentsAllowed])
    else { return nil }
    object[key] = newValue
    return try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
}

private struct ClaudeProfile: Decodable {
    let accountUuid: String
    let organizationUuid: String?
    let emailAddress: String?
    let organizationName: String?
}

/// The active Claude Code login, from its Keychain item and `~/.claude.json`; nil when it isn't signed in.
public func getClaudeAccount(credentials: Data, config: Data) -> SavedAccount? {
    guard let login = extractJSONValue(credentials, key: "claudeAiOauth"),
        let profileData = extractJSONValue(config, key: "oauthAccount"),
        let profile = try? JSONDecoder().decode(ClaudeProfile.self, from: profileData)
    else { return nil }
    // One email can belong to a personal and a team organization, each with its own limits.
    let label = [profile.emailAddress ?? profile.accountUuid, profile.organizationName]
        .compactMap { $0 }
        .joined(separator: " · ")
    return SavedAccount(
        provider: .claude, id: "\(profile.accountUuid)/\(profile.organizationUuid ?? "")", label: label,
        login: login, profile: profileData)
}

private struct CodexAuth: Decodable {
    struct Tokens: Decodable {
        let idToken: String?
        let accountId: String?

        enum CodingKeys: String, CodingKey {
            case idToken = "id_token"
            case accountId = "account_id"
        }
    }

    let apiKey: String?
    let tokens: Tokens?

    enum CodingKeys: String, CodingKey {
        case apiKey = "OPENAI_API_KEY"
        case tokens
    }
}

/// The email claim of a JWT, read without checking its signature since it only labels the account.
func getJWTEmail(_ token: String) -> String? {
    let parts = token.split(separator: ".")
    guard parts.count == 3 else { return nil }
    var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    guard let payload = Data(base64Encoded: base64),
        let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
    else { return nil }
    return claims["email"] as? String
}

/// The active Codex login from `~/.codex/auth.json`: a ChatGPT sign-in or an API key; nil when it has neither.
public func getCodexAccount(auth: Data) -> SavedAccount? {
    guard let parsed = try? JSONDecoder().decode(CodexAuth.self, from: auth) else { return nil }
    if let accountID = parsed.tokens?.accountId {
        let label = parsed.tokens?.idToken.flatMap(getJWTEmail) ?? accountID
        return SavedAccount(provider: .codex, id: accountID, label: label, login: auth, profile: nil)
    }
    guard let apiKey = parsed.apiKey, apiKey.count > 4 else { return nil }
    let suffix = String(apiKey.suffix(4))
    return SavedAccount(
        provider: .codex, id: "key-\(suffix)", label: "\(apiKey.prefix(3))…\(suffix)", login: auth, profile: nil)
}

/// The saved accounts with this one added, or replacing its older copy in place.
public func upsertSavedAccount(_ accounts: [SavedAccount], _ account: SavedAccount) -> [SavedAccount] {
    guard let index = accounts.firstIndex(where: { $0.provider == account.provider && $0.id == account.id }) else {
        return accounts + [account]
    }
    var updated = accounts
    updated[index] = account
    return updated
}
