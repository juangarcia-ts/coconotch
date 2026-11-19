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
    #expect(account.label == "me@example.com")
    #expect(try decode(account.login)["refreshToken"] as? String == "r1")
    #expect(try decode(account.profile)["emailAddress"] as? String == "me@example.com")
    #expect(getClaudeAccount(credentials: credentials, config: Data("{\"numStartups\":3}".utf8)) == nil)
    #expect(getClaudeAccount(credentials: Data("{\"mcpOAuth\":{}}".utf8), config: config) == nil)
}

@Test func savingAnAccountAgainReplacesItsOldCopy() {
    let first = SavedAccount(id: "a", label: "A", login: Data("1".utf8), profile: Data())
    let second = SavedAccount(id: "b", label: "B", login: Data("2".utf8), profile: Data())
    let refreshed = SavedAccount(id: "a", label: "A", login: Data("3".utf8), profile: Data())
    let saved = [first, second].reduce([], upsertSavedAccount)
    #expect(upsertSavedAccount(saved, refreshed) == [refreshed, second])
}

@Test func keepsTheAliasWhenTheLoginIsSavedAgain() {
    let work = SavedAccount(id: "a", label: "me@example.com", login: Data("1".utf8), profile: Data())
    let named = setAccountAlias([work], work, alias: "  Work ")
    #expect(named.first?.name == "Work")
    let refreshed = SavedAccount(
        id: "a", label: "me@example.com", login: Data("2".utf8), profile: Data())
    let resaved = upsertSavedAccount(named, refreshed)
    #expect(resaved.first?.alias == "Work")
    #expect(resaved.first?.login == Data("2".utf8))
    #expect(setAccountAlias(resaved, work, alias: " ").first?.name == "me@example.com")
}

@Test func readsKeychainOutputPrintedAsHex() {
    let json = Data("[{\"label\":\"me · Team\"}]".utf8)
    let hex = Data((json.map { String(format: "%02x", $0) }.joined() + "\n").utf8)
    #expect(decodeKeychainOutput(hex) == json)
    #expect(decodeKeychainOutput(Data("{\"a\":1}\n".utf8)) == Data("{\"a\":1}".utf8))
    #expect(decodeKeychainOutput(Data("abc".utf8)) == nil)
    #expect(decodeKeychainOutput(Data("zz".utf8)) == nil)
}

@Test func quotesKeychainValuesForSecurityInput() throws {
    let command = try #require(
        makeKeychainWriteCommand(Data(#"{"a":"q\"b\\c"}"#.utf8), service: "Claude Code-credentials", account: "me"))
    #expect(
        command == #"add-generic-password -U -a "me" -s "Claude Code-credentials" -w "{\"a\":\"q\\\"b\\\\c\"}""# + "\n")
}

@Test func refusesKeychainValuesThatWouldBeCutOff() {
    let long = Data(("{\"a\":\"" + String(repeating: "x", count: 4100) + "\"}").utf8)
    #expect(makeKeychainWriteCommand(long, service: "s", account: "a") == nil)
    #expect(makeKeychainWriteCommand(Data("{\n}".utf8), service: "s", account: "a") == nil)
    #expect(makeKeychainWriteCommand(Data([0xFF]), service: "s", account: "a") == nil)
}

@Test func writesKeychainJSONOnOneLine() throws {
    let replaced = try #require(replaceJSONValue(credentials, key: "claudeAiOauth", with: Data("{\"b\":1}".utf8)))
    #expect(!String(decoding: replaced, as: UTF8.self).contains("\n"))
    let pretty = try #require(replaceJSONValue(config, key: "numStartups", with: Data("4".utf8), isPretty: true))
    #expect(String(decoding: pretty, as: UTF8.self).contains("\n"))
}

@Test(arguments: [false, true])
func tracksWhetherASwitchLeftTheLoginMismatched(wasMismatched: Bool) {
    // A switch that writes both clears it, including the retry after a failure.
    #expect(!isLoginMismatched(wasMismatched: wasMismatched, isConfigWritten: true, isRestored: true))
    // Undone, the old pair is back as it was.
    #expect(isLoginMismatched(wasMismatched: wasMismatched, isConfigWritten: false, isRestored: true) == wasMismatched)
    // Neither finished nor undone.
    #expect(isLoginMismatched(wasMismatched: wasMismatched, isConfigWritten: false, isRestored: false))
}

@Test func savesTheActiveLoginOnRefreshOnlyWhenItBelongs() {
    let saved = [SavedAccount(id: "a", label: "a@example.com", login: Data(), profile: Data())]
    // Already saved: kept current.
    #expect(shouldSaveActiveAccount(saved, activeID: "a", isSigningIn: false, signingInFromID: nil))
    // Never saved and not signing in: left alone.
    #expect(!shouldSaveActiveAccount(saved, activeID: "b", isSigningIn: false, signingInFromID: nil))
    // Signing in from "a": "b" is the new account; still "a" means you haven't signed in yet.
    #expect(shouldSaveActiveAccount(saved, activeID: "b", isSigningIn: true, signingInFromID: "a"))
    #expect(!shouldSaveActiveAccount([], activeID: "a", isSigningIn: true, signingInFromID: "a"))
    // Signing in while signed out: the first login to appear is the new account.
    #expect(shouldSaveActiveAccount([], activeID: "b", isSigningIn: true, signingInFromID: nil))
}

@Test func tellsSignedOutApartFromAnUnreadableLogin() throws {
    let account = try #require(getClaudeAccount(credentials: credentials, config: config))
    #expect(getActiveLogin(credentialsExitCode: 0, credentials: credentials, config: config) == .signedIn(account))
    // Signed out: Claude Code has no Keychain item, or one without its login.
    #expect(getActiveLogin(credentialsExitCode: 44, credentials: nil, config: nil) == .signedOut)
    let noLogin = Data("{\"mcpOAuth\":{}}".utf8)
    #expect(getActiveLogin(credentialsExitCode: 0, credentials: noLogin, config: config) == .signedOut)
    // Unreadable: a locked or refused Keychain, garbled output, or a login whose config can't be read.
    #expect(getActiveLogin(credentialsExitCode: 36, credentials: nil, config: config) == .unreadable)
    #expect(getActiveLogin(credentialsExitCode: 51, credentials: nil, config: config) == .unreadable)
    #expect(getActiveLogin(credentialsExitCode: 0, credentials: Data("nope".utf8), config: config) == .unreadable)
    #expect(getActiveLogin(credentialsExitCode: 0, credentials: credentials, config: nil) == .unreadable)
    #expect(getActiveLogin(credentialsExitCode: 0, credentials: credentials, config: Data("{}".utf8)) == .unreadable)
}
