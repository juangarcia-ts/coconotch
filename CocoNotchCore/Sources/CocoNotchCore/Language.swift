import Foundation

/// The macOS defaults key that holds an app's own language order; it overrides the system order for that app.
public let appLanguagesKey = "AppleLanguages"

/// A language's name in that language, such as "Deutsch" or "日本語", so anyone can find their own.
public func formatLanguageName(_ identifier: String) -> String {
    let locale = Locale(identifier: identifier)
    let name = locale.localizedString(forIdentifier: identifier) ?? identifier
    return name.prefix(1).uppercased(with: locale) + name.dropFirst()
}

/// The languages the app ships, without Xcode's "Base", sorted by their own names.
public func getAppLanguages(localizations: [String]) -> [String] {
    localizations.filter { $0 != "Base" }.sorted {
        formatLanguageName($0).localizedStandardCompare(formatLanguageName($1)) == .orderedAscending
    }
}

/// The language the app runs in for a choice: `chosen`, or nil to follow the system's order. With no match, macOS
/// falls back to the development language, so it goes first.
public func resolveAppLanguage(
    chosen: String?, systemLanguages: [String], available: [String], developmentLanguage: String
) -> String? {
    let candidates = [developmentLanguage] + available.filter { $0 != developmentLanguage }
    return Bundle.preferredLocalizations(from: candidates, forPreferences: chosen.map { [$0] } ?? systemLanguages)
        .first
}

/// Whether the next launch would use another language than the one running now.
public func shouldRestartForLanguage(
    chosen: String?, systemLanguages: [String], available: [String], developmentLanguage: String, running: String?
) -> Bool {
    resolveAppLanguage(
        chosen: chosen, systemLanguages: systemLanguages, available: available, developmentLanguage: developmentLanguage
    ) != running
}
