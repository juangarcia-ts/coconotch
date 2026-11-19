import Foundation
import Testing

@testable import CocoNotchCore

private let credentials = Data(
    """
    {"claudeAiOauth":{"accessToken":"a1","refreshToken":"r1"},"mcpOAuth":{"server":{"accessToken":"keep"}}}
    """.utf8)

private let config = Data(
    """
    {"numStartups":3,"oauthAccount":{"accountUuid":"acc","organizationUuid":"org",
    "emailAddress":"me@example.com","organizationName":"Team"}}
    """.utf8)

private func decode(_ data: Data?) throws -> [String: Any] {
    let data = try #require(data)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test func swapsOnlyTheClaudeLoginAndKeepsOtherTokens() throws {
    let other = Data("{\"accessToken\":\"a2\",\"refreshToken\":\"r2\"}".utf8)
    let swapped = try decode(replaceJSONValue(credentials, key: "claudeAiOauth", with: other))
    #expect((swapped["claudeAiOauth"] as? [String: String])?["accessToken"] == "a2")
    #expect((swapped["mcpOAuth"] as? [String: [String: String]])?["server"]?["accessToken"] == "keep")
    #expect(replaceJSONValue(Data("not json".utf8), key: "k", with: other) == nil)
}

@Test func readsTheActiveClaudeAccount() throws {
    let account = try #require(getClaudeAccount(credentials: credentials, config: config))
    #expect(account.id == "acc/org")
    #expect(account.label == "me@example.com · Team")
    #expect(try decode(account.login)["refreshToken"] as? String == "r1")
    #expect(try decode(account.profile)["emailAddress"] as? String == "me@example.com")
    #expect(getClaudeAccount(credentials: credentials, config: Data("{\"numStartups\":3}".utf8)) == nil)
    #expect(getClaudeAccount(credentials: Data("{\"mcpOAuth\":{}}".utf8), config: config) == nil)
}

@Test func labelsCodexSignInsByEmailAndKeysBySuffix() throws {
    let payload = Data("{\"email\":\"me@example.com\"}".utf8).base64EncodedString()
        .replacingOccurrences(of: "=", with: "")
    let signIn = Data("{\"tokens\":{\"id_token\":\"h.\(payload).s\",\"account_id\":\"acct-1\"}}".utf8)
    let account = try #require(getCodexAccount(auth: signIn))
    #expect(account.id == "acct-1")
    #expect(account.label == "me@example.com")
    #expect(account.login == signIn)

    let key = try #require(getCodexAccount(auth: Data("{\"OPENAI_API_KEY\":\"sk-abcdef1234\"}".utf8)))
    #expect(key.id == "key-1234")
    #expect(key.label == "sk-…1234")
    #expect(getCodexAccount(auth: Data("{\"OPENAI_API_KEY\":null,\"tokens\":null}".utf8)) == nil)
}

@Test func savingAnAccountAgainReplacesItsOldCopy() {
    let first = SavedAccount(provider: .claude, id: "a", label: "A", login: Data("1".utf8), profile: nil)
    let second = SavedAccount(provider: .claude, id: "b", label: "B", login: Data("2".utf8), profile: nil)
    let refreshed = SavedAccount(provider: .claude, id: "a", label: "A", login: Data("3".utf8), profile: nil)
    let codex = SavedAccount(provider: .codex, id: "a", label: "A", login: Data("4".utf8), profile: nil)
    let saved = [first, second, codex].reduce([], upsertSavedAccount)
    #expect(upsertSavedAccount(saved, refreshed) == [refreshed, second, codex])
}
