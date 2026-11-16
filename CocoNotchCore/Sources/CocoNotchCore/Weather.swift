import Foundation

public enum TemperatureUnit: String, CaseIterable, Sendable {
    case celsius
    case fahrenheit
}

/// Raw values are Open-Meteo's `wind_speed_unit` values.
public enum WindSpeedUnit: String, CaseIterable, Sendable {
    case kmh
    case mph
    case ms
    case kn
}

public enum WeatherLocationMode: String, CaseIterable, Sendable {
    case current
    case place
}

public struct WeatherPlace: Codable, Equatable, Identifiable, Sendable {
    public let name: String
    public let region: String?
    public let country: String?
    public let latitude: Double
    public let longitude: Double

    public var id: String { "\(latitude),\(longitude)" }

    public init(name: String, region: String? = nil, country: String? = nil, latitude: Double, longitude: Double) {
        self.name = name
        self.region = region
        self.country = country
        self.latitude = latitude
        self.longitude = longitude
    }
}

public struct CurrentWeather: Equatable, Sendable {
    public let temperature: Double
    public let apparentTemperature: Double
    public let code: Int
    public let isDay: Bool
    public let windSpeed: Double
    public let humidity: Int
}

public struct HourForecast: Equatable, Identifiable, Sendable {
    public let time: Date
    public let temperature: Double
    public let code: Int
    public let isDay: Bool
    public let precipitationProbability: Int

    public var id: Date { time }

    public init(time: Date, temperature: Double, code: Int, isDay: Bool = true, precipitationProbability: Int = 0) {
        self.time = time
        self.temperature = temperature
        self.code = code
        self.isDay = isDay
        self.precipitationProbability = precipitationProbability
    }
}

public struct DayForecast: Equatable, Identifiable, Sendable {
    public let date: Date
    public let code: Int
    public let high: Double
    public let low: Double
    public let precipitationProbability: Int

    public var id: Date { date }
}

public struct WeatherReport: Equatable, Sendable {
    public let current: CurrentWeather
    public let hours: [HourForecast]
    public let days: [DayForecast]
}

/// One request for everything the widget shows: now, the next 24 hours and `dayCount` days, in the user's units.
public func makeForecastURL(
    latitude: Double,
    longitude: Double,
    temperatureUnit: TemperatureUnit,
    windSpeedUnit: WindSpeedUnit,
    dayCount: Int
) -> URL? {
    var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
    components?.queryItems = [
        URLQueryItem(name: "latitude", value: String(latitude)),
        URLQueryItem(name: "longitude", value: String(longitude)),
        URLQueryItem(
            name: "current",
            value: "temperature_2m,apparent_temperature,weather_code,is_day,wind_speed_10m,relative_humidity_2m"
        ),
        URLQueryItem(name: "hourly", value: "temperature_2m,weather_code,precipitation_probability,is_day"),
        URLQueryItem(
            name: "daily",
            value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"
        ),
        URLQueryItem(name: "temperature_unit", value: temperatureUnit.rawValue),
        URLQueryItem(name: "wind_speed_unit", value: windSpeedUnit.rawValue),
        URLQueryItem(name: "timezone", value: "auto"),
        URLQueryItem(name: "timeformat", value: "unixtime"),
        URLQueryItem(name: "forecast_days", value: String(dayCount)),
        URLQueryItem(name: "forecast_hours", value: "24"),
    ]
    return components?.url
}

private struct ForecastResponse: Decodable {
    struct Current: Decodable {
        let temperature: Double
        let apparentTemperature: Double
        let weatherCode: Int
        let isDay: Int
        let windSpeed: Double
        let humidity: Int

        enum CodingKeys: String, CodingKey {
            case temperature = "temperature_2m"
            case apparentTemperature = "apparent_temperature"
            case weatherCode = "weather_code"
            case isDay = "is_day"
            case windSpeed = "wind_speed_10m"
            case humidity = "relative_humidity_2m"
        }
    }

    struct Hourly: Decodable {
        let time: [Int]
        let temperature: [Double?]
        let weatherCode: [Int?]
        let precipitationProbability: [Int?]
        let isDay: [Int?]

        enum CodingKeys: String, CodingKey {
            case time
            case temperature = "temperature_2m"
            case weatherCode = "weather_code"
            case precipitationProbability = "precipitation_probability"
            case isDay = "is_day"
        }
    }

    struct Daily: Decodable {
        let time: [Int]
        let weatherCode: [Int?]
        let high: [Double?]
        let low: [Double?]
        let precipitationProbability: [Int?]

        enum CodingKeys: String, CodingKey {
            case time
            case weatherCode = "weather_code"
            case high = "temperature_2m_max"
            case low = "temperature_2m_min"
            case precipitationProbability = "precipitation_probability_max"
        }
    }

    let current: Current
    let hourly: Hourly
    let daily: Daily
}

/// Reads an Open-Meteo forecast requested by `makeForecastURL`. Hours and days with missing values are skipped.
public func parseForecast(_ data: Data) throws -> WeatherReport {
    let response = try JSONDecoder().decode(ForecastResponse.self, from: data)
    let hourly = response.hourly
    let hours: [HourForecast] = hourly.time.indices.compactMap { index in
        guard let temperature = hourly.temperature[safe: index] ?? nil,
            let code = hourly.weatherCode[safe: index] ?? nil
        else { return nil }
        return HourForecast(
            time: Date(timeIntervalSince1970: TimeInterval(hourly.time[index])),
            temperature: temperature,
            code: code,
            isDay: (hourly.isDay[safe: index] ?? nil) != 0,
            precipitationProbability: (hourly.precipitationProbability[safe: index] ?? nil) ?? 0
        )
    }
    let daily = response.daily
    let days: [DayForecast] = daily.time.indices.compactMap { index in
        guard let code = daily.weatherCode[safe: index] ?? nil,
            let high = daily.high[safe: index] ?? nil,
            let low = daily.low[safe: index] ?? nil
        else { return nil }
        return DayForecast(
            date: Date(timeIntervalSince1970: TimeInterval(daily.time[index])),
            code: code,
            high: high,
            low: low,
            precipitationProbability: (daily.precipitationProbability[safe: index] ?? nil) ?? 0
        )
    }
    let current = response.current
    return WeatherReport(
        current: CurrentWeather(
            temperature: current.temperature,
            apparentTemperature: current.apparentTemperature,
            code: current.weatherCode,
            isDay: current.isDay != 0,
            windSpeed: current.windSpeed,
            humidity: current.humidity
        ),
        hours: hours,
        days: days
    )
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

public func makeGeocodingURL(query: String) -> URL? {
    let query = query.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return nil }
    var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")
    components?.queryItems = [
        URLQueryItem(name: "name", value: query),
        URLQueryItem(name: "count", value: "6"),
        URLQueryItem(name: "format", value: "json"),
    ]
    return components?.url
}

private struct GeocodingResponse: Decodable {
    struct Result: Decodable {
        let name: String
        let admin1: String?
        let country: String?
        let latitude: Double
        let longitude: Double
    }

    // Open-Meteo leaves `results` out entirely when nothing matches.
    let results: [Result]?
}

public func parseGeocoding(_ data: Data) throws -> [WeatherPlace] {
    try JSONDecoder().decode(GeocodingResponse.self, from: data).results?.map {
        WeatherPlace(
            name: $0.name, region: $0.admin1, country: $0.country, latitude: $0.latitude, longitude: $0.longitude)
    } ?? []
}

/// "Lisbon, Lisbon, Portugal" reads oddly, so a region equal to the name is left out.
public func formatPlaceTitle(_ place: WeatherPlace) -> String {
    [place.name, place.region == place.name ? nil : place.region, place.country]
        .compactMap { $0 }
        .joined(separator: ", ")
}

/// An SF Symbol for a WMO weather code, as Open-Meteo reports it.
public func getWeatherSymbol(code: Int, isDay: Bool) -> String {
    switch code {
    case 0: isDay ? "sun.max.fill" : "moon.stars.fill"
    case 1, 2: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
    case 3: "cloud.fill"
    case 45, 48: "cloud.fog.fill"
    case 51...57: "cloud.drizzle.fill"
    case 65, 82: "cloud.heavyrain.fill"
    case 61...67, 80...82: "cloud.rain.fill"
    case 71...77, 85, 86: "cloud.snow.fill"
    case 95...99: "cloud.bolt.rain.fill"
    default: "cloud.fill"
    }
}

public func getWeatherDescription(code: Int) -> String {
    switch code {
    case 0: "Clear"
    case 1: "Mostly clear"
    case 2: "Partly cloudy"
    case 3: "Overcast"
    case 45, 48: "Fog"
    case 51...55: "Drizzle"
    case 56, 57: "Freezing drizzle"
    case 61, 63: "Rain"
    case 65: "Heavy rain"
    case 66, 67: "Freezing rain"
    case 71...77: "Snow"
    case 80, 81: "Showers"
    case 82: "Heavy showers"
    case 85, 86: "Snow showers"
    case 95: "Thunderstorm"
    case 96, 99: "Thunderstorm with hail"
    default: "Unknown"
    }
}

/// Rounded, with a degree sign and no unit, as weather apps show it: "21°".
public func formatTemperature(_ value: Double) -> String {
    "\(Int(value.rounded()))°"
}

public func getWindSpeedUnitLabel(_ unit: WindSpeedUnit) -> String {
    switch unit {
    case .kmh: "km/h"
    case .mph: "mph"
    case .ms: "m/s"
    case .kn: "kn"
    }
}

public func formatWindSpeed(_ value: Double, unit: WindSpeedUnit) -> String {
    "\(Int(value.rounded())) \(getWindSpeedUnitLabel(unit))"
}

public func getDefaultTemperatureUnit(locale: Locale) -> TemperatureUnit {
    locale.measurementSystem == .us ? .fahrenheit : .celsius
}

public func getDefaultWindSpeedUnit(locale: Locale) -> WindSpeedUnit {
    locale.measurementSystem == .metric ? .kmh : .mph
}

/// The hours still to come, starting with the one in progress.
public func getUpcomingHours(_ hours: [HourForecast], now: Date, count: Int) -> [HourForecast] {
    Array(hours.filter { $0.time.addingTimeInterval(3600) > now }.prefix(count))
}

/// Where a day's low-to-high bar starts and ends, as fractions of the whole forecast's range.
public func getTemperatureBar(low: Double, high: Double, rangeLow: Double, rangeHigh: Double) -> ClosedRange<Double> {
    let span = rangeHigh - rangeLow
    guard span > 0 else { return 0...1 }
    let start = min(max((low - rangeLow) / span, 0), 1)
    let end = min(max((high - rangeLow) / span, 0), 1)
    return start...max(start, end)
}

/// The first hour within `window` whose chance of rain reaches `threshold` percent, for the rain heads-up.
public func getRainHeadsUpHour(
    _ hours: [HourForecast],
    now: Date,
    threshold: Int,
    window: TimeInterval
) -> HourForecast? {
    hours.first { hour in
        hour.time.addingTimeInterval(3600) > now
            && hour.time <= now.addingTimeInterval(window)
            && hour.precipitationProbability >= threshold
    }
}

public func encodeWeatherPlace(_ place: WeatherPlace?) -> String {
    guard let place, let data = try? JSONEncoder().encode(place) else { return "" }
    return String(decoding: data, as: UTF8.self)
}

public func decodeWeatherPlace(_ stored: String) -> WeatherPlace? {
    try? JSONDecoder().decode(WeatherPlace.self, from: Data(stored.utf8))
}

/// Why there is no forecast to show.
public enum WeatherProblem: Equatable, Sendable {
    case noPlace
    case locationNotAsked
    case locationDenied
    case locationFailed
    case network
}

public func getWeatherProblemMessage(_ problem: WeatherProblem) -> String {
    switch problem {
    case .noPlace: "Choose a city in Settings → Weather."
    case .locationNotAsked: "See the weather where you are, or choose a city in Settings → Weather."
    case .locationDenied: "CocoNotch can't use your location. Allow it in System Settings, or choose a city."
    case .locationFailed: "Your location couldn't be found. Try again, or choose a city in Settings → Weather."
    case .network: "The forecast couldn't be loaded. Check your connection and try again."
    }
}

/// "Now" for the hour in progress, otherwise the hour in the user's format.
public func formatHourLabel(_ time: Date, now: Date) -> String {
    time <= now && now < time.addingTimeInterval(3600) ? "Now" : time.formatted(.dateTime.hour())
}

/// "Today" for today, otherwise the short weekday.
public func formatDayLabel(_ date: Date, now: Date, calendar: Calendar) -> String {
    calendar.isDate(date, inSameDayAs: now) ? "Today" : date.formatted(.dateTime.weekday(.abbreviated))
}

public func isWeatherStale(updatedAt: Date?, now: Date, maxAge: TimeInterval) -> Bool {
    updatedAt.map { now.timeIntervalSince($0) > maxAge } ?? true
}

public struct WeatherCoordinate: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// Whether two points share a forecast. GPS fixes wander a little between reads, so anything within about 5 km
/// counts as the same place, and the widget keeps showing the last forecast while it reloads.
public func isSameWeatherLocation(_ old: WeatherCoordinate?, _ new: WeatherCoordinate) -> Bool {
    guard let old else { return false }
    return abs(old.latitude - new.latitude) < 0.05 && abs(old.longitude - new.longitude) < 0.05
}
