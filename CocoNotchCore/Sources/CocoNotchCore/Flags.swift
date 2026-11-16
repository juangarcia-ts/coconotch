/// Turns an ISO 3166 country code such as "BR" into its flag emoji.
public func getFlagEmoji(countryCode: String) -> String? {
    let letters = countryCode.uppercased().unicodeScalars
    guard letters.count == 2, letters.allSatisfy({ ("A"..."Z").contains($0) }) else { return nil }
    // Each regional indicator symbol sits 0x1F1A5 above its ASCII capital letter.
    let indicators = letters.compactMap { Unicode.Scalar($0.value + 0x1F1A5) }
    return String(String.UnicodeScalarView(indicators))
}

/// Parses the tz database's zone.tab (country code, coordinates, identifier per line) into identifier → country code.
public func parseZoneTab(_ contents: String) -> [String: String] {
    var countryCodes: [String: String] = [:]
    for line in contents.split(separator: "\n") where !line.hasPrefix("#") {
        let columns = line.split(separator: "\t")
        guard columns.count >= 3 else { continue }
        countryCodes[String(columns[2])] = String(columns[0])
    }
    return countryCodes
}
