import CocoNotchCore
import CoreLocation
import SwiftUI

extension NotchWidget {
    static let weather = NotchWidget(
        id: "weather",
        title: String(localized: "Weather"),
        systemImage: "cloud.sun",
        makeView: { AnyView(WeatherView()) },
        makeSettings: { AnyView(WeatherSettings()) },
        makeSummary: { AnyView(WeatherSummary()) },
        makeSummarySettings: { AnyView(WeatherSummarySettings()) }
    )
}

private let locationModeKey = "weather.locationMode"
private let placeKey = "weather.place"
private let temperatureUnitKey = "weather.temperatureUnit"
private let windSpeedUnitKey = "weather.windSpeedUnit"
private let showsFeelsLikeKey = "weather.showsFeelsLike"
private let showsHumidityKey = "weather.showsHumidity"
private let showsWindKey = "weather.showsWind"
private let showsPrecipitationKey = "weather.showsPrecipitation"
private let showsHourlyKey = "weather.showsHourly"
private let hourCountKey = "weather.hourCount"
private let showsDailyKey = "weather.showsDaily"
private let dayCountKey = "weather.dayCount"
private let refreshMinutesKey = "weather.refreshMinutes"
private let showsRainHeadsUpKey = "weather.showsRainHeadsUp"
private let rainThresholdKey = "weather.rainThreshold"
private let summaryShowsHighLowKey = "weather.summaryShowsHighLow"
private let summaryShowsPlaceKey = "weather.summaryShowsPlace"

private let defaultTemperatureUnit = getDefaultTemperatureUnit(locale: .current)
private let defaultWindSpeedUnit = getDefaultWindSpeedUnit(locale: .current)
private let defaultHourCount = 6
private let defaultDayCount = 5
private let defaultRefreshMinutes = 30
private let defaultRainThreshold = 70
private let rainActivityID = "weather.rain"
// Opening the tab reloads a forecast older than this, so it is never far behind after the Mac wakes.
private let staleAge: TimeInterval = 10 * 60

private func readSetting<Value>(_ key: String, default defaultValue: Value) -> Value {
    UserDefaults.standard.object(forKey: key) as? Value ?? defaultValue
}

private func readEnum<Value: RawRepresentable<String>>(_ key: String, default defaultValue: Value) -> Value {
    UserDefaults.standard.string(forKey: key).flatMap { Value(rawValue: $0) } ?? defaultValue
}

/// Loads the forecast for the whole app, so the Home card and the rain heads-up work without opening the tab.
@Observable
final class WeatherStore: NSObject, CLLocationManagerDelegate {
    static let shared = WeatherStore()

    private(set) var report: WeatherReport?
    private(set) var placeName: String?
    private(set) var problem: WeatherProblem?
    private(set) var isLoading = false
    private var updatedAt: Date?
    @ObservationIgnored private let locationManager = CLLocationManager()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var headsUpTask: Task<Void, Never>?
    // One load at a time: a newer one cancels the last, so a slow older response can't overwrite it.
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadedCoordinate: WeatherCoordinate?
    // CoreLocation reports the status once as soon as the delegate is set; only a real change should reload.
    @ObservationIgnored private var authorizationStatus: CLAuthorizationStatus

    override init() {
        authorizationStatus = locationManager.authorizationStatus
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// Reloads on the user's interval; `refresh` does nothing while the widget is off.
    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                let minutes = readSetting(refreshMinutesKey, default: defaultRefreshMinutes)
                try? await Task.sleep(for: .seconds(minutes * 60))
            }
        }
        // The forecast is hourly but the heads-up should end when its hour does, so it is re-checked every minute.
        headsUpTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.updateRainHeadsUp()
            }
        }
    }

    private var isWidgetEnabled: Bool {
        let preferences = NotchWidget.getPreferences(
            stored: UserDefaults.standard.string(forKey: PreferenceKey.widgetPreferences) ?? "")
        return getEnabledWidgetIDs(preferences).contains(NotchWidget.weather.id)
    }

    func refreshIfStale() {
        if isStale(updatedAt: updatedAt, now: .now, maxAge: staleAge) { refresh() }
    }

    /// Reloads now. Settings call this when the location or units change.
    func refresh() {
        // Every path in goes through here, so a switched-off widget never asks for location or the network.
        guard isWidgetEnabled else {
            ActivityCenter.shared.remove(id: rainActivityID)
            return
        }
        switch readEnum(locationModeKey, default: WeatherLocationMode.current) {
        case .place:
            guard let place = decodeWeatherPlace(UserDefaults.standard.string(forKey: placeKey) ?? "") else {
                show(.noPlace)
                return
            }
            startLoad(WeatherCoordinate(latitude: place.latitude, longitude: place.longitude), placeName: place.name)
        case .current:
            switch locationManager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                isLoading = true
                locationManager.requestLocation()
            case .notDetermined:
                show(.locationNotAsked)
            default:
                show(.locationDenied)
            }
        }
    }

    /// Only ever called from a button, so the permission prompt never appears out of nowhere.
    func requestLocationAccess() {
        locationManager.requestWhenInUseAuthorization()
    }

    /// Nil when the search failed, so the search can say so instead of showing no matches.
    static func searchPlaces(_ query: String) async -> [WeatherPlace]? {
        guard let url = makeGeocodingURL(query: query) else { return [] }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return try? parseGeocoding(data)
    }

    private func show(_ problem: WeatherProblem) {
        self.problem = problem
        report = nil
        isLoading = false
        updateRainHeadsUp()
    }

    /// Starts a load for `coordinate`. A forecast for somewhere else is cleared first, so it is never shown under
    /// the new place's name, even when the new load fails.
    private func startLoad(_ coordinate: WeatherCoordinate, placeName name: String?) {
        loadTask?.cancel()
        if !isSameWeatherLocation(loadedCoordinate, coordinate) {
            report = nil
            placeName = name
        }
        loadTask = Task { await load(coordinate, placeName: name) }
    }

    private func load(_ coordinate: WeatherCoordinate, placeName name: String?) async {
        guard
            let url = makeForecastURL(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                temperatureUnit: readEnum(temperatureUnitKey, default: defaultTemperatureUnit),
                windSpeedUnit: readEnum(windSpeedUnitKey, default: defaultWindSpeedUnit),
                dayCount: readSetting(dayCountKey, default: defaultDayCount)
            )
        else { return }
        isLoading = true
        // A cancelled load leaves the flag to the load that replaced it.
        defer { if !Task.isCancelled { isLoading = false } }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let parsed = try parseForecast(data)
            guard !Task.isCancelled else { return }
            report = parsed
            placeName = name
            loadedCoordinate = coordinate
            problem = nil
            updatedAt = .now
        } catch {
            guard !Task.isCancelled else { return }
            // Keeps the last forecast on screen; a short outage shouldn't blank the widget.
            if report == nil { problem = .network }
        }
        updateRainHeadsUp()
    }

    private func loadCurrentLocation(_ coordinate: WeatherCoordinate) async {
        let placemarks = try? await CLGeocoder().reverseGeocodeLocation(
            CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
        // The user may have picked a city while the fix or the geocoding was in flight.
        guard !Task.isCancelled, readEnum(locationModeKey, default: WeatherLocationMode.current) == .current else {
            return
        }
        startLoad(coordinate, placeName: placemarks?.first?.locality)
    }

    private func updateRainHeadsUp() {
        guard isWidgetEnabled, readSetting(showsRainHeadsUpKey, default: false), let report,
            let hour = getRainHeadsUpHour(
                report.hours,
                now: .now,
                threshold: readSetting(rainThresholdKey, default: defaultRainThreshold),
                window: 3600
            )
        else {
            ActivityCenter.shared.remove(id: rainActivityID)
            return
        }
        ActivityCenter.shared.post(
            NotchActivity(
                id: rainActivityID,
                widgetID: NotchWidget.weather.id,
                priority: .normal,
                sortDate: hour.time,
                makeLeading: {
                    AnyView(
                        Label("Rain soon", systemImage: "umbrella.fill")
                            .symbolRenderingMode(.multicolor)
                    )
                },
                makeTrailing: { AnyView(Text("\(hour.precipitationProbability)%").monospacedDigit()) }
            )
        )
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            guard status != authorizationStatus else { return }
            authorizationStatus = status
            refresh()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        let location = WeatherCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)
        MainActor.assumeIsolated {
            _ = Task { await loadCurrentLocation(location) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        MainActor.assumeIsolated {
            if report == nil { show(.locationFailed) }
            isLoading = false
        }
    }
}

private struct WeatherView: View {
    @AppStorage(showsFeelsLikeKey) private var showsFeelsLike = true
    @AppStorage(showsHumidityKey) private var showsHumidity = true
    @AppStorage(showsWindKey) private var showsWind = true
    @AppStorage(showsPrecipitationKey) private var showsPrecipitation = true
    @AppStorage(showsHourlyKey) private var showsHourly = true
    @AppStorage(hourCountKey) private var hourCount = defaultHourCount
    @AppStorage(showsDailyKey) private var showsDaily = true
    @AppStorage(windSpeedUnitKey) private var windSpeedUnit = defaultWindSpeedUnit
    @AppStorage(locationModeKey) private var locationMode = WeatherLocationMode.current
    @Environment(\.showSettings) private var showSettings
    private let store = WeatherStore.shared

    var body: some View {
        Group {
            if let report = store.report {
                TimelineView(.everyMinute) { context in
                    HStack(alignment: .top, spacing: 20) {
                        current(report, now: context.date)
                            .frame(width: 170, alignment: .leading)
                        VStack(alignment: .leading, spacing: 12) {
                            if showsHourly {
                                hourly(
                                    getUpcomingHours(report.hours, now: context.date, count: hourCount),
                                    now: context.date)
                            }
                            if showsDaily {
                                daily(report.days, now: context.date)
                            }
                        }
                    }
                }
            } else if let problem = store.problem {
                WeatherProblemView(problem: problem)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            }
        }
        .onAppear { store.refreshIfStale() }
    }

    private func current(_ report: WeatherReport, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // The number leads: SF Symbols carry side padding, so an icon first never lines up with the text below.
            HStack(alignment: .center, spacing: 10) {
                Text(formatTemperature(report.current.temperature))
                    .font(.system(size: 44, weight: .semibold).monospacedDigit())
                Image(systemName: getWeatherSymbol(code: report.current.code, isDay: report.current.isDay))
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 30))
            }
            Text(getWeatherDescription(code: report.current.code))
                .font(.callout.weight(.medium))
            if let today = report.days.first {
                Text("H \(formatTemperature(today.high))  L \(formatTemperature(today.low))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 5) {
                if showsFeelsLike {
                    DetailRow(
                        symbol: "thermometer.medium", label: "Feels like",
                        value: formatTemperature(report.current.apparentTemperature))
                }
                if showsHumidity {
                    DetailRow(symbol: "humidity", label: "Humidity", value: "\(report.current.humidity)%")
                }
                if showsWind {
                    DetailRow(
                        symbol: "wind", label: "Wind",
                        value: formatWindSpeed(report.current.windSpeed, unit: windSpeedUnit))
                }
            }
            .padding(.top, 8)
            if let placeName = store.placeName {
                Button {
                    showSettings(.widget(NotchWidget.weather.id))
                } label: {
                    Label(placeName, systemImage: locationMode == .current ? "location.fill" : "mappin")
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 6)
                .help("Change location in Settings")
            }
        }
    }

    private func hourly(_ hours: [HourForecast], now: Date) -> some View {
        // Its own panel, so its centred columns read as one block instead of misaligning with the daily rows.
        HStack(spacing: 0) {
            ForEach(hours) { hour in
                VStack(spacing: 4) {
                    Text(formatHourLabel(hour.time, now: now))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    Image(systemName: getWeatherSymbol(code: hour.code, isDay: hour.isDay))
                        .symbolRenderingMode(.multicolor)
                        .font(.body)
                        .frame(height: 18)
                    Text(formatTemperature(hour.temperature))
                        .font(.callout.weight(.semibold).monospacedDigit())
                    if showsPrecipitation {
                        Text("\(hour.precipitationProbability)%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.cyan)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private func daily(_ days: [DayForecast], now: Date) -> some View {
        let rangeLow = days.map(\.low).min() ?? 0
        let rangeHigh = days.map(\.high).max() ?? 0
        return VStack(spacing: 4) {
            ForEach(days) { day in
                HStack(spacing: 10) {
                    Text(formatDayLabel(day.date, now: now, calendar: .current))
                        .font(.caption.weight(.medium))
                        // Shrinks a long "Today", like "Aujourd'hui", rather than wrap it and break the row's bar.
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: 44, alignment: .leading)
                    Image(systemName: getWeatherSymbol(code: day.code, isDay: true))
                        .symbolRenderingMode(.multicolor)
                        .frame(width: 22)
                    if showsPrecipitation {
                        Text("\(day.precipitationProbability)%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.cyan)
                            .frame(width: 30, alignment: .leading)
                    }
                    Text(formatTemperature(day.low))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                    TemperatureBar(
                        range: getTemperatureBar(low: day.low, high: day.high, rangeLow: rangeLow, rangeHigh: rangeHigh)
                    )
                    Text(formatTemperature(day.high))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .frame(width: 32, alignment: .leading)
                }
            }
        }
    }
}

/// One line of the current details: a quiet icon and label, with the value aligned on the right.
private struct DetailRow: View {
    let symbol: String
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        GridRow {
            Image(systemName: symbol)
                .foregroundStyle(.tertiary)
                .frame(width: 14)
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .monospacedDigit()
                .gridColumnAlignment(.trailing)
        }
        .font(.caption)
    }
}

/// A day's low-to-high span on the scale of the whole forecast, like the Weather app's bars.
private struct TemperatureBar: View {
    let range: ClosedRange<Double>

    var body: some View {
        GeometryReader { geometry in
            Capsule()
                .fill(Color.primary.opacity(0.12))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.cyan, .yellow, .orange], startPoint: .leading, endPoint: .trailing)
                        )
                        .frame(width: max(geometry.size.width * (range.upperBound - range.lowerBound), 4))
                        .offset(x: geometry.size.width * range.lowerBound)
                }
        }
        .frame(height: 4)
    }
}

private struct WeatherProblemView: View {
    let problem: WeatherProblem
    @AppStorage(locationModeKey) private var locationMode = WeatherLocationMode.current
    @AppStorage(placeKey) private var storedPlace = ""
    private let store = WeatherStore.shared

    var body: some View {
        WidgetPrompt(systemImage: NotchWidget.weather.systemImage, message: getWeatherProblemMessage(problem)) {
            switch problem {
            case .locationNotAsked:
                CitySearch(onPick: pick) {
                    Button("Use My Location", systemImage: "location.fill") { store.requestLocationAccess() }
                }
            case .locationDenied:
                CitySearch(onPick: pick) {
                    Button("Open Privacy Settings") { openPrivacySettings("Privacy_LocationServices") }
                }
            case .locationFailed:
                CitySearch(onPick: pick) {
                    Button("Try Again", systemImage: "arrow.clockwise") { store.refresh() }
                }
            case .network:
                Button("Try Again", systemImage: "arrow.clockwise") { store.refresh() }
            case .noPlace:
                CitySearch(onPick: pick) { EmptyView() }
            }
        }
    }

    private func pick(_ place: WeatherPlace) {
        storedPlace = encodeWeatherPlace(place)
        locationMode = .place
        store.refresh()
    }
}

/// The city search in the notch prompt and in Settings, styled like the Clipboard and Shelf search bars.
private struct CitySearch<Accessory: View>: View {
    let onPick: (WeatherPlace) -> Void
    @ViewBuilder var accessory: Accessory
    @State private var query = ""
    @State private var searchedQuery = ""
    @State private var results: [WeatherPlace]? = []
    @State private var selectedID: WeatherPlace.ID?

    var body: some View {
        // The notch caps a widget at about 290pt, so four matches is all that fits under the prompt.
        let shown = Array((results ?? []).prefix(4))
        let selected = shown.first { $0.id == selectedID } ?? shown.first
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search for a city", text: $query)
                        .textFieldStyle(.plain)
                        // Return waits for the search to catch up, so it never picks a match for older text.
                        .onSubmit { if searchedQuery == query { selected.map(pick) } }
                        .onKeyPress(.downArrow) { select(offset: 1, in: shown, from: selected) }
                        .onKeyPress(.upArrow) { select(offset: -1, in: shown, from: selected) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                accessory
            }
            VStack(spacing: 2) {
                ForEach(shown) { place in
                    CityRow(place: place, isSelected: place.id == selected?.id)
                        .onHover { if $0 { selectedID = place.id } }
                        .onTapGesture { pick(place) }
                }
            }
            if let note = getCitySearchNote(query: query, searchedQuery: searchedQuery, results: results) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .animation(.easeOut(duration: 0.15), value: shown)
        .task(id: query) {
            // Waits for a pause in typing, so each keystroke doesn't send a search.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let found = await WeatherStore.searchPlaces(query)
            // A newer query cancels this one; its aborted request must not show as a failed search.
            guard !Task.isCancelled else { return }
            results = found
            searchedQuery = query
        }
    }

    private func pick(_ place: WeatherPlace) {
        onPick(place)
        query = ""
    }

    private func select(offset: Int, in places: [WeatherPlace], from selected: WeatherPlace?) -> KeyPress.Result {
        guard let id = getMovedSelection(in: places.map(\.id), from: selected?.id, by: offset) else { return .ignored }
        selectedID = id
        return .handled
    }
}

private struct CityRow: View {
    let place: WeatherPlace
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "mappin.and.ellipse")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(place.name)
                .lineLimit(1)
                .layoutPriority(1)
            if let region = formatPlaceRegion(place) {
                Text(region)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "return")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .opacity(isSelected ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(isSelected ? 0.14 : 0), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// The current conditions, for the Home tab.
private struct WeatherSummary: View {
    @AppStorage(summaryShowsHighLowKey) private var showsHighLow = true
    @AppStorage(summaryShowsPlaceKey) private var showsPlace = true
    private let store = WeatherStore.shared

    var body: some View {
        if let report = store.report {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(formatTemperature(report.current.temperature))
                        .font(.title2.weight(.semibold).monospacedDigit())
                    Image(systemName: getWeatherSymbol(code: report.current.code, isDay: report.current.isDay))
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 18))
                }
                HStack(spacing: 6) {
                    Text(getWeatherDescription(code: report.current.code))
                        .font(.caption.weight(.medium))
                    if showsHighLow, let today = report.days.first {
                        Text("H \(formatTemperature(today.high))  L \(formatTemperature(today.low))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                if showsPlace, let placeName = store.placeName {
                    Text(placeName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        } else {
            SummaryMessage(store.problem.map(getWeatherProblemMessage) ?? String(localized: "Loading the forecast…"))
        }
    }
}

private struct WeatherSummarySettings: View {
    @AppStorage(summaryShowsHighLowKey) private var showsHighLow = true
    @AppStorage(summaryShowsPlaceKey) private var showsPlace = true

    var body: some View {
        Toggle("Show today's high and low", isOn: $showsHighLow)
        Toggle("Show the place", isOn: $showsPlace)
    }
}

private struct WeatherSettings: View {
    @AppStorage(locationModeKey) private var locationMode = WeatherLocationMode.current
    @AppStorage(placeKey) private var storedPlace = ""
    @AppStorage(temperatureUnitKey) private var temperatureUnit = defaultTemperatureUnit
    @AppStorage(windSpeedUnitKey) private var windSpeedUnit = defaultWindSpeedUnit
    @AppStorage(showsFeelsLikeKey) private var showsFeelsLike = true
    @AppStorage(showsHumidityKey) private var showsHumidity = true
    @AppStorage(showsWindKey) private var showsWind = true
    @AppStorage(showsPrecipitationKey) private var showsPrecipitation = true
    @AppStorage(showsHourlyKey) private var showsHourly = true
    @AppStorage(hourCountKey) private var hourCount = defaultHourCount
    @AppStorage(showsDailyKey) private var showsDaily = true
    @AppStorage(dayCountKey) private var dayCount = defaultDayCount
    @AppStorage(refreshMinutesKey) private var refreshMinutes = defaultRefreshMinutes
    @AppStorage(showsRainHeadsUpKey) private var showsRainHeadsUp = false
    @AppStorage(rainThresholdKey) private var rainThreshold = defaultRainThreshold
    private let store = WeatherStore.shared

    var body: some View {
        Form {
            Section("Location") {
                Picker("Show the weather for", selection: $locationMode) {
                    Text("My current location").tag(WeatherLocationMode.current)
                    Text("A city").tag(WeatherLocationMode.place)
                }
                if locationMode == .current {
                    if store.problem == .locationNotAsked || store.problem == .locationDenied {
                        Text(getWeatherProblemMessage(store.problem ?? .locationNotAsked))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Use My Location", systemImage: "location.fill") { store.requestLocationAccess() }
                    }
                } else {
                    if let place = decodeWeatherPlace(storedPlace) {
                        LabeledContent("City", value: formatPlaceTitle(place))
                    }
                    CitySearch(onPick: { storedPlace = encodeWeatherPlace($0) }) { EmptyView() }
                }
            }
            Section("Units") {
                Picker("Temperature", selection: $temperatureUnit) {
                    Text("Celsius (°C)").tag(TemperatureUnit.celsius)
                    Text("Fahrenheit (°F)").tag(TemperatureUnit.fahrenheit)
                }
                Picker("Wind speed", selection: $windSpeedUnit) {
                    ForEach(WindSpeedUnit.allCases, id: \.self) { unit in
                        Text(getWindSpeedUnitLabel(unit)).tag(unit)
                    }
                }
            }
            Section("Details") {
                Toggle("Feels like", isOn: $showsFeelsLike)
                Toggle("Humidity", isOn: $showsHumidity)
                Toggle("Wind", isOn: $showsWind)
                Toggle("Chance of rain", isOn: $showsPrecipitation)
            }
            Section("Forecast") {
                Toggle("Hourly forecast", isOn: $showsHourly)
                Picker("Hours", selection: $hourCount) {
                    ForEach(4...8, id: \.self) { Text("\($0)").tag($0) }
                }
                .disabled(!showsHourly)
                Toggle("Daily forecast", isOn: $showsDaily)
                Picker("Days", selection: $dayCount) {
                    ForEach(3...7, id: \.self) { Text("\($0)").tag($0) }
                }
                .disabled(!showsDaily)
            }
            Section("Updates") {
                Picker("Refresh every", selection: $refreshMinutes) {
                    ForEach([15, 30, 60], id: \.self) { Text("\($0) minutes").tag($0) }
                }
            }
            Section("Rain heads-up") {
                Toggle(
                    "Show a heads-up in the closed notch when rain is likely within the hour", isOn: $showsRainHeadsUp)
                Picker("When the chance of rain reaches", selection: $rainThreshold) {
                    ForEach([50, 70, 90], id: \.self) { Text("\($0)%").tag($0) }
                }
                .disabled(!showsRainHeadsUp)
            }
        }
        .formStyle(.grouped)
        .onChange(of: locationMode) { store.refresh() }
        .onChange(of: storedPlace) { store.refresh() }
        .onChange(of: temperatureUnit) { store.refresh() }
        .onChange(of: windSpeedUnit) { store.refresh() }
        .onChange(of: dayCount) { store.refresh() }
        .onChange(of: showsRainHeadsUp) { store.refresh() }
        .onChange(of: rainThreshold) { store.refresh() }
    }
}
