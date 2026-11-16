import CocoNotchCore
import Testing

@Test(arguments: [("BR", "🇧🇷"), ("us", "🇺🇸"), ("JP", "🇯🇵")])
func makesFlagEmoji(code: String, flag: String) {
    #expect(getFlagEmoji(countryCode: code) == flag)
}

@Test(arguments: ["", "B", "BRA", "B1", "Ü1"])
func rejectsInvalidCountryCodes(code: String) {
    #expect(getFlagEmoji(countryCode: code) == nil)
}

@Test func parsesZoneTab() {
    let contents = """
        # tzdb timezone descriptions
        BR\t-2332-04637\tAmerica/Sao_Paulo\tBrazil (southeast)
        IN\t+2232+08822\tAsia/Kolkata
        malformed line
        """
    #expect(parseZoneTab(contents) == ["America/Sao_Paulo": "BR", "Asia/Kolkata": "IN"])
}
