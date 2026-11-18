import CocoNotchCore
import Testing

@Test func namesEachLanguageInItself() {
    #expect(formatLanguageName("de") == "Deutsch")
    #expect(formatLanguageName("es") == "Español")
    #expect(formatLanguageName("ja") == "日本語")
}

@Test func listsShippedLanguagesWithoutBase() {
    #expect(getAppLanguages(localizations: ["Base", "it", "en", "de"]) == ["de", "en", "it"])
}

@Test func resolvesTheLanguageTheAppRunsIn() {
    // The picker's order, which doesn't start with the development language.
    let available = ["de", "en", "es", "pt-BR"]
    let resolve = { (chosen: String?, system: [String]) in
        resolveAppLanguage(chosen: chosen, systemLanguages: system, available: available, developmentLanguage: "en")
    }
    #expect(resolve("es", ["pt-BR"]) == "es")
    #expect(resolve(nil, ["en-BR", "pt-BR"]) == "en")
    #expect(resolve(nil, ["pt-BR", "en"]) == "pt-BR")
    #expect(resolve(nil, ["ru"]) == "en")
}

@Test func asksForARestartOnlyWhenTheLanguageWouldChange() {
    let shouldRestart = { (chosen: String?, system: [String], running: String) in
        shouldRestartForLanguage(
            chosen: chosen, systemLanguages: system, available: ["de", "en", "es"], developmentLanguage: "en",
            running: running)
    }
    #expect(shouldRestart("es", ["en"], "en"))
    #expect(!shouldRestart("es", ["en"], "es"))
    #expect(!shouldRestart(nil, ["es"], "es"))
    // Running German, back to a system with no shipped language: the next launch is English.
    #expect(shouldRestart(nil, ["ru"], "de"))
}
