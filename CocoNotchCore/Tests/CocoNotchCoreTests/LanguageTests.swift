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
    let available = ["en", "es", "pt-BR"]
    #expect(resolveAppLanguage(chosen: "es", systemLanguages: ["pt-BR"], available: available) == "es")
    #expect(resolveAppLanguage(chosen: nil, systemLanguages: ["en-BR", "pt-BR"], available: available) == "en")
    #expect(resolveAppLanguage(chosen: nil, systemLanguages: ["pt-BR", "en"], available: available) == "pt-BR")
    #expect(resolveAppLanguage(chosen: nil, systemLanguages: ["ru"], available: available) == "en")
}
