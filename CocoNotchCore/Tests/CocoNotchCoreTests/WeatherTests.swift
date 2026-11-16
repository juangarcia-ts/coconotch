import CocoNotchCore
import Foundation
import Testing

private let sampleForecast = """
    {"current":{"time":1800000000,"interval":900,"temperature_2m":22.5,"apparent_temperature":23.0,"weather_code":53,
    "is_day":1,"wind_speed_10m":13.9,"relative_humidity_2m":72},
    "hourly":{"time":[1800000000,1800003600,1800007200],"temperature_2m":[23.2,null,20.9],"weather_code":[51,53,2],
    "precipitation_probability":[100,96,null],"is_day":[1,1,0]},
    "daily":{"time":[1799960400,1800046800],"weather_code":[80,51],"temperature_2m_max":[24.5,27.4],
    "temperature_2m_min":[18.4,18.0],"precipitation_probability_max":[100,null]}}
    """

@Test func parsesForecast() throws {
    let report = try parseForecast(Data(sampleForecast.utf8))
    #expect(report.current.temperature == 22.5)
    #expect(report.current.code == 53)
    #expect(report.current.isDay)
    #expect(report.current.humidity == 72)
    // The hour with no temperature is skipped; a missing chance of rain reads as 0.
    #expect(report.hours.map(\.temperature) == [23.2, 20.9])
    #expect(report.hours.last?.isDay == false)
    #expect(report.hours.last?.precipitationProbability == 0)
    #expect(report.hours.first?.time == Date(timeIntervalSince1970: 1_800_000_000))
    #expect(report.days.map(\.high) == [24.5, 27.4])
    #expect(report.days.last?.precipitationProbability == 0)
}

@Test func rejectsBrokenForecast() {
    #expect(throws: (any Error).self) { try parseForecast(Data("{}".utf8)) }
}

@Test func buildsForecastURL() throws {
    let url = try #require(
        makeForecastURL(
            latitude: 52.52, longitude: 13.41, temperatureUnit: .fahrenheit, windSpeedUnit: .mph, dayCount: 5)
    )
    let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    #expect(url.host() == "api.open-meteo.com")
    #expect(values["latitude"] == "52.52")
    #expect(values["temperature_unit"] == "fahrenheit")
    #expect(values["wind_speed_unit"] == "mph")
    #expect(values["forecast_days"] == "5")
    #expect(values["timeformat"] == "unixtime")
}

@Test func parsesGeocoding() throws {
    let data = Data(
        """
        {"results":[{"name":"Berlin","latitude":52.52,"longitude":13.41,"country":"Germany","admin1":"Land Berlin"}]}
        """.utf8)
    #expect(
        try parseGeocoding(data) == [
            WeatherPlace(name: "Berlin", region: "Land Berlin", country: "Germany", latitude: 52.52, longitude: 13.41)
        ])
    #expect(try parseGeocoding(Data("{\"generationtime_ms\":0.1}".utf8)).isEmpty)
    #expect(makeGeocodingURL(query: "  ") == nil)
    #expect(makeGeocodingURL(query: "São Paulo")?.host() == "geocoding-api.open-meteo.com")
}

@Test func formatsPlaceTitle() {
    #expect(
        formatPlaceTitle(WeatherPlace(name: "Lisbon", region: "Lisbon", country: "Portugal", latitude: 0, longitude: 0))
            == "Lisbon, Portugal")
    #expect(
        formatPlaceTitle(WeatherPlace(name: "Porto", region: "Norte", country: nil, latitude: 0, longitude: 0))
            == "Porto, Norte")
}

@Test(arguments: [
    (0, true, "sun.max.fill"), (0, false, "moon.stars.fill"), (2, false, "cloud.moon.fill"), (3, true, "cloud.fill"),
    (53, true, "cloud.drizzle.fill"), (63, true, "cloud.rain.fill"), (65, true, "cloud.heavyrain.fill"),
    (81, true, "cloud.rain.fill"), (75, true, "cloud.snow.fill"), (99, true, "cloud.bolt.rain.fill"),
    (1234, true, "cloud.fill"),
])
func picksWeatherSymbol(code: Int, isDay: Bool, expected: String) {
    #expect(getWeatherSymbol(code: code, isDay: isDay) == expected)
}

@Test func describesWeather() {
    #expect(getWeatherDescription(code: 0) == "Clear")
    #expect(getWeatherDescription(code: 82) == "Heavy showers")
    #expect(getWeatherDescription(code: 1234) == "Unknown")
}

@Test func formatsWeatherValues() {
    #expect(formatTemperature(21.6) == "22°")
    #expect(formatTemperature(-3.4) == "-3°")
    #expect(formatWindSpeed(13.9, unit: .kmh) == "14 km/h")
    #expect(formatWindSpeed(4.2, unit: .ms) == "4 m/s")
    #expect(getDefaultTemperatureUnit(locale: Locale(identifier: "en_US")) == .fahrenheit)
    #expect(getDefaultTemperatureUnit(locale: Locale(identifier: "pt_BR")) == .celsius)
}

@Test func getsUpcomingHours() {
    let now = Date(timeIntervalSince1970: 1_800_001_800)
    let hours = (0..<5).map {
        HourForecast(time: Date(timeIntervalSince1970: 1_800_000_000 + Double($0) * 3600), temperature: 20, code: 0)
    }
    // The hour that started 30 minutes ago is still in progress, so it comes first.
    #expect(getUpcomingHours(hours, now: now, count: 3).map(\.time) == Array(hours.prefix(3).map(\.time)))
    #expect(getUpcomingHours(hours, now: now + 3600, count: 10).count == 4)
}

@Test func placesTemperatureBar() {
    #expect(getTemperatureBar(low: 10, high: 20, rangeLow: 10, rangeHigh: 30) == 0...0.5)
    #expect(getTemperatureBar(low: 15, high: 25, rangeLow: 10, rangeHigh: 30) == 0.25...0.75)
    #expect(getTemperatureBar(low: 5, high: 40, rangeLow: 10, rangeHigh: 30) == 0...1)
    #expect(getTemperatureBar(low: 20, high: 20, rangeLow: 20, rangeHigh: 20) == 0...1)
}

@Test func findsRainHeadsUpHour() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func hour(_ offset: Double, chance: Int) -> HourForecast {
        HourForecast(time: now + offset * 3600, temperature: 20, code: 61, precipitationProbability: chance)
    }
    let hours = [hour(-1, chance: 90), hour(0, chance: 40), hour(1, chance: 80), hour(3, chance: 100)]
    #expect(getRainHeadsUpHour(hours, now: now, threshold: 70, window: 3600)?.time == now + 3600)
    #expect(getRainHeadsUpHour(hours, now: now, threshold: 30, window: 3600)?.time == now)
    #expect(getRainHeadsUpHour(hours, now: now, threshold: 95, window: 3600) == nil)
}

@Test func roundTripsWeatherPlace() {
    let place = WeatherPlace(name: "Berlin", region: nil, country: "Germany", latitude: 52.52, longitude: 13.41)
    #expect(decodeWeatherPlace(encodeWeatherPlace(place)) == place)
    #expect(encodeWeatherPlace(nil) == "")
    #expect(decodeWeatherPlace("") == nil)
}

@Test func picksDefaultWindUnit() {
    #expect(getDefaultWindSpeedUnit(locale: Locale(identifier: "de_DE")) == .kmh)
    #expect(getDefaultWindSpeedUnit(locale: Locale(identifier: "en_US")) == .mph)
    #expect(getDefaultWindSpeedUnit(locale: Locale(identifier: "en_GB")) == .mph)
}

@Test func describesEveryWeatherProblem() {
    for problem in [WeatherProblem.noPlace, .locationNotAsked, .locationDenied, .locationFailed, .network] {
        #expect(!getWeatherProblemMessage(problem).isEmpty)
    }
}

@Test func formatsForecastLabels() {
    let now = Date(timeIntervalSince1970: 1_800_001_800)
    let hourStart = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(formatHourLabel(hourStart, now: now) == "Now")
    #expect(formatHourLabel(hourStart + 3600, now: now) == (hourStart + 3600).formatted(.dateTime.hour()))
    #expect(formatPrecipitation(10) == nil)
    #expect(formatPrecipitation(40) == "40%")

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    #expect(formatDayLabel(now, now: now, calendar: calendar) == "Today")
    #expect(
        formatDayLabel(now + 86_400, now: now, calendar: calendar)
            == (now + 86_400).formatted(.dateTime.weekday(.abbreviated)))

    #expect(isWeatherStale(updatedAt: nil, now: now, maxAge: 600))
    #expect(!isWeatherStale(updatedAt: now - 300, now: now, maxAge: 600))
    #expect(isWeatherStale(updatedAt: now - 900, now: now, maxAge: 600))
}
