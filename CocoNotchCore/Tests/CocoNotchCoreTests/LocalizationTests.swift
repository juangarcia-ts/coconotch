import Foundation
import Testing

@testable import CocoNotchCore

private func getBundle(_ language: String) throws -> Bundle {
    try #require(Bundle.module.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)))
}

@Test(arguments: [
    ("es", "Hoy"), ("pt-BR", "Hoje"), ("fr", "Aujourd'hui"), ("it", "Oggi"), ("de", "Heute"), ("ja", "今日"),
    ("zh-Hans", "今天"), ("ko", "오늘"),
])
func translatesIntoEveryLanguage(language: String, today: String) throws {
    #expect(try getBundle(language).localizedString(forKey: "Today", value: nil, table: nil) == today)
}

@Test func picksThePluralForTheCount() throws {
    let format = try getBundle("es").localizedString(forKey: "%lld items", value: nil, table: nil)
    let locale = Locale(identifier: "es")
    #expect(String(format: format, locale: locale, 1) == "1 ítem")
    #expect(String(format: format, locale: locale, 3) == "3 ítems")
}

@Test func pluralizesTheFailedCountAfterTheResult() throws {
    let format = try getBundle("es").localizedString(
        forKey: "%@; %lld files couldn't be converted", value: nil, table: nil)
    let locale = Locale(identifier: "es")
    let done = "3 archivos convertidos"
    #expect(String(format: format, locale: locale, done, 1) == "3 archivos convertidos; no se pudo convertir 1 archivo")
    #expect(
        String(format: format, locale: locale, done, 2) == "3 archivos convertidos; no se pudieron convertir 2 archivos"
    )
}
