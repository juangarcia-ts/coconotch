import AppKit
import CocoNotchCore
import SwiftUI

extension NotchWidget {
    static let timer = NotchWidget(
        id: "timer",
        title: String(localized: "Timer"),
        systemImage: "timer",
        makeView: { AnyView(TimerView()) },
        makeSettings: { AnyView(TimerSettings()) }
    )
}

enum TimerMode: String, CaseIterable {
    case pomodoro, timer, stopwatch

    var title: String {
        switch self {
        case .pomodoro: String(localized: "Pomodoro")
        case .timer: String(localized: "Timer")
        case .stopwatch: String(localized: "Stopwatch")
        }
    }

    var systemImage: String {
        switch self {
        case .pomodoro: "brain.head.profile"
        case .timer: "timer"
        case .stopwatch: "stopwatch"
        }
    }
}

private let modeKey = "timer.mode"
private let timerSecondsKey = "timer.timerSeconds"
private let focusMinutesKey = "timer.focusMinutes"
private let shortBreakMinutesKey = "timer.shortBreakMinutes"
private let longBreakMinutesKey = "timer.longBreakMinutes"
private let longBreakEveryKey = "timer.longBreakEvery"
private let autoStartsNextKey = "timer.autoStartsNext"
private let playsSoundKey = "timer.playsSound"
private let soundNameKey = "timer.soundName"
private let showsActivityKey = "timer.showsActivity"
private let defaultTimerSeconds = 600
private let defaultFocusMinutes = 25
private let defaultShortBreakMinutes = 5
private let defaultLongBreakMinutes = 15
private let defaultLongBreakEvery = 4
private let defaultSoundName = "Glass"
private let timerPresets = [1, 5, 10, 15, 30, 60]
private let doneActivityID = "timer.done"
private let doneAlertSeconds = 30.0

private func readSetting<T>(_ key: String, default value: T) -> T {
    UserDefaults.standard.object(forKey: key) as? T ?? value
}

private func getTitle(_ phase: PomodoroPhase) -> String {
    switch phase {
    case .focus: String(localized: "Focus")
    case .shortBreak: String(localized: "Short break")
    case .longBreak: String(localized: "Long break")
    }
}

private func listSystemSounds() -> [String] {
    let files = (try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? []
    return files.map { ($0 as NSString).deletingPathExtension }.sorted()
}

/// Owns the three clocks for the whole app, so they keep running with the notch closed and show there as activities.
@Observable
final class TimerStore {
    static let shared = TimerStore()

    private(set) var pomodoro = RunClock()
    private(set) var phase = PomodoroPhase.focus
    /// Focus sessions finished since the last reset, for the long-break count and the dots under the clock.
    private(set) var focusCount = 0
    private(set) var countdown = RunClock()
    private(set) var stopwatch = RunClock()
    /// Stopwatch readings when Lap was pressed, oldest first.
    private(set) var laps: [TimeInterval] = []
    private var finishTasks: [TimerMode: Task<Void, Never>] = [:]
    private var doneTask: Task<Void, Never>?
    private var plannedKey = ""

    /// Durations and the notch toggle can change mid-run, so settings writes re-plan the finish and the activities.
    func start() {
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.getPlanKey() != self.plannedKey else { return }
                self.update()
            }
        }
    }

    /// The settings a plan depends on, so writes to unrelated defaults don't re-plan.
    private func getPlanKey() -> String {
        "\(TimerMode.allCases.map(getDuration)) \(readSetting(showsActivityKey, default: true))"
    }

    func getDuration(_ mode: TimerMode) -> TimeInterval {
        switch mode {
        case .pomodoro:
            let minutes =
                switch phase {
                case .focus: readSetting(focusMinutesKey, default: defaultFocusMinutes)
                case .shortBreak: readSetting(shortBreakMinutesKey, default: defaultShortBreakMinutes)
                case .longBreak: readSetting(longBreakMinutesKey, default: defaultLongBreakMinutes)
                }
            return TimeInterval(minutes * 60)
        case .timer: return TimeInterval(readSetting(timerSecondsKey, default: defaultTimerSeconds))
        case .stopwatch: return 0
        }
    }

    func getClock(_ mode: TimerMode) -> RunClock {
        switch mode {
        case .pomodoro: pomodoro
        case .timer: countdown
        case .stopwatch: stopwatch
        }
    }

    private func setClock(_ mode: TimerMode, _ clock: RunClock) {
        switch mode {
        case .pomodoro: pomodoro = clock
        case .timer: countdown = clock
        case .stopwatch: stopwatch = clock
        }
    }

    func toggle(_ mode: TimerMode) {
        var clock = getClock(mode)
        if clock.isRunning { clock.pause(at: .now) } else { clock.start(at: .now) }
        setClock(mode, clock)
        update()
    }

    func reset(_ mode: TimerMode) {
        setClock(mode, RunClock())
        if mode == .pomodoro {
            phase = .focus
            focusCount = 0
        }
        if mode == .stopwatch { laps = [] }
        update()
    }

    func lap() {
        laps.append(stopwatch.getElapsed(at: .now))
    }

    private func advancePhase(isFinished: Bool) {
        (phase, focusCount) = advancePomodoro(
            phase: phase, focusCount: focusCount, isFinished: isFinished,
            longBreakEvery: readSetting(longBreakEveryKey, default: defaultLongBreakEvery))
    }

    /// Moves on to the next phase without counting the current one as done.
    func skipPhase() {
        advancePhase(isFinished: false)
        let wasRunning = pomodoro.isRunning
        pomodoro = RunClock()
        if wasRunning { pomodoro.start(at: .now) }
        update()
    }

    private func finish(_ mode: TimerMode) {
        let message: String
        if mode == .pomodoro {
            let finished = phase
            advancePhase(isFinished: true)
            pomodoro = RunClock()
            if readSetting(autoStartsNextKey, default: false) { pomodoro.start(at: .now) }
            message = String(localized: "\(getTitle(finished)) done · \(getTitle(phase)) next")
        } else {
            countdown = RunClock()
            message = String(localized: "Timer done")
        }
        if readSetting(playsSoundKey, default: true) {
            NSSound(named: NSSound.Name(readSetting(soundNameKey, default: defaultSoundName)))?.play()
        }
        postDone(message, mode: mode)
        update()
    }

    private func postDone(_ message: String, mode: TimerMode) {
        ActivityCenter.shared.post(
            NotchActivity(
                id: doneActivityID,
                widgetID: NotchWidget.timer.id,
                priority: .urgent,
                sortDate: .now,
                makeLeading: { AnyView(Label(message, systemImage: "checkmark.circle.fill")) },
                makeTrailing: { AnyView(Image(systemName: mode.systemImage)) },
                makeAlert: { AnyView(Text(message)) }
            )
        )
        doneTask?.cancel()
        doneTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(doneAlertSeconds))
            guard !Task.isCancelled else { return }
            ActivityCenter.shared.remove(id: doneActivityID)
            self?.doneTask = nil
        }
    }

    /// Re-plans each countdown's finish and re-posts every clock's activity.
    private func update() {
        plannedKey = getPlanKey()
        let showsActivity = readSetting(showsActivityKey, default: true)
        for mode in TimerMode.allCases {
            let clock = getClock(mode)
            let duration = getDuration(mode)
            finishTasks[mode]?.cancel()
            finishTasks[mode] = nil
            if mode != .stopwatch, let finishDate = getFinishDate(clock, duration: duration) {
                finishTasks[mode] = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(max(0, finishDate.timeIntervalSinceNow)))
                    guard !Task.isCancelled else { return }
                    self?.finish(mode)
                }
            }
            postActivity(mode, clock: clock, duration: duration, isShown: showsActivity)
        }
    }

    private func postActivity(_ mode: TimerMode, clock: RunClock, duration: TimeInterval, isShown: Bool) {
        let id = "timer.\(mode.rawValue)"
        let isStarted = clock.isRunning || clock.getElapsed(at: .now) > 0
        guard isShown, isStarted else {
            ActivityCenter.shared.remove(id: id)
            return
        }
        let title = mode == .pomodoro ? getTitle(phase) : mode.title
        ActivityCenter.shared.post(
            NotchActivity(
                id: id,
                widgetID: NotchWidget.timer.id,
                // A paused clock only fills the notch when nothing else wants it.
                priority: clock.isRunning ? .normal : .low,
                sortDate: clock.startedAt ?? .distantFuture,
                makeLeading: {
                    AnyView(Label(title, systemImage: clock.isRunning ? mode.systemImage : "pause.fill"))
                },
                makeTrailing: {
                    AnyView(ClockText(clock: clock, duration: mode == .stopwatch ? nil : duration))
                }
            )
        )
    }
}

/// The time on a clock, redrawn every second while it runs; `duration` makes it count down.
private struct ClockText: View {
    let clock: RunClock
    let duration: TimeInterval?

    var body: some View {
        TimelineView(.periodic(from: clock.startedAt ?? .now, by: 1)) { context in
            Text(getText(at: context.date))
                .monospacedDigit()
        }
    }

    private func getText(at date: Date) -> String {
        guard let duration else { return formatClock(seconds: Int(clock.getElapsed(at: date))) }
        return formatCountdown(getRemaining(clock, duration: duration, at: date))
    }
}

private struct TimerView: View {
    @AppStorage(modeKey) private var mode = TimerMode.pomodoro
    @AppStorage(timerSecondsKey) private var timerSeconds = defaultTimerSeconds
    @AppStorage(longBreakEveryKey) private var longBreakEvery = defaultLongBreakEvery
    private let store = TimerStore.shared

    var body: some View {
        let clock = store.getClock(mode)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                ForEach(TimerMode.allCases, id: \.self) { item in
                    Chip(title: item.title, systemImage: item.systemImage, isSelected: item == mode) { mode = item }
                }
            }
            HStack(alignment: .top, spacing: 8) {
                clockTile(clock: clock, duration: store.getDuration(mode))
                if mode == .stopwatch, !store.laps.isEmpty {
                    // Sized by the clock tile; the list scrolls inside it rather than growing the notch.
                    Color.clear
                        .frame(width: 220)
                        .frame(maxHeight: .infinity)
                        .overlay { LapList(laps: store.laps) }
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            // Lets the lap tile stretch to the clock tile's height, like the System tiles.
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
    }

    private func clockTile(clock: RunClock, duration: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                mode == .pomodoro ? getTitle(store.phase) : mode.title,
                systemImage: clock.isRunning || mode == .stopwatch ? mode.systemImage : "pause.fill"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            HStack(alignment: .center) {
                Group {
                    if mode == .timer, !clock.isRunning, clock.banked == 0 {
                        DurationField(seconds: $timerSeconds) { store.toggle(.timer) }
                    } else {
                        ClockText(clock: clock, duration: mode == .stopwatch ? nil : duration)
                    }
                }
                .font(.system(size: 44, weight: .semibold))
                Spacer()
                controls(clock: clock)
            }
            if mode != .stopwatch {
                TimelineView(.periodic(from: clock.startedAt ?? .now, by: 1)) { context in
                    ProgressView(value: min(1, clock.getElapsed(at: context.date) / max(1, duration)))
                        .progressViewStyle(.linear)
                }
            }
            detail(clock: clock, duration: duration)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(minHeight: 22)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func detail(clock: RunClock, duration: TimeInterval) -> some View {
        let finish = getFinishDate(clock, duration: duration).map {
            String(localized: "Ends at \($0.formatted(date: .omitted, time: .shortened))")
        }
        switch mode {
        case .pomodoro:
            HStack(spacing: 6) {
                if longBreakEvery > 0 {
                    // One dot per finished focus in this round; a skipped one doesn't fill a dot.
                    let done = store.focusCount % longBreakEvery
                    HStack(spacing: 3) {
                        ForEach(0..<longBreakEvery, id: \.self) { index in
                            Image(systemName: index < done ? "circle.fill" : "circle")
                                .font(.system(size: 6))
                        }
                    }
                    Text("\(done) of \(longBreakEvery) before the long break")
                } else {
                    Text("\(store.focusCount) focus sessions finished")
                }
                Spacer()
                if let finish { Text(finish) }
            }
        case .timer where !clock.isRunning && clock.banked == 0:
            HStack(spacing: 2) {
                ForEach(timerPresets, id: \.self) { minutes in
                    Chip(title: "\(minutes)m", font: .caption.weight(.medium), isSelected: minutes * 60 == timerSeconds)
                    {
                        timerSeconds = minutes * 60
                    }
                }
                Spacer()
                Text("Click the time to type one")
            }
        case .timer:
            Text(finish ?? String(localized: "Paused · \(formatClock(seconds: timerSeconds)) timer"))
        case .stopwatch:
            Text(store.laps.isEmpty ? "Lap marks a split" : "\(store.laps.count) laps")
        }
    }

    private func controls(clock: RunClock) -> some View {
        HStack(spacing: 16) {
            iconButton(clock.isRunning ? "Pause" : "Start", systemImage: clock.isRunning ? "pause.fill" : "play.fill") {
                store.toggle(mode)
            }
            .keyboardShortcut(.space, modifiers: [])
            switch mode {
            case .pomodoro:
                iconButton("Skip to the next phase", systemImage: "forward.end.fill") { store.skipPhase() }
            case .stopwatch:
                iconButton("Lap", systemImage: "flag.fill") { store.lap() }
                    .disabled(!clock.isRunning)
            case .timer:
                EmptyView()
            }
            iconButton("Reset", systemImage: "arrow.counterclockwise") { store.reset(mode) }
                .disabled(!clock.isRunning && clock.banked == 0 && (mode != .pomodoro || store.focusCount == 0))
        }
        .font(.title2)
    }

    private func iconButton(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View
    {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .help(title)
    }
}

/// The idle timer's length, typed over the clock: Return sets it and starts, clicking away only sets it.
private struct DurationField: View {
    @Binding var seconds: Int
    let start: () -> Void
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("Duration", text: $text)
            .textFieldStyle(.plain)
            .monospacedDigit()
            .focused($isFocused)
            .frame(maxWidth: 240, alignment: .leading)
            .onSubmit { if commit() { start() } }
            .onChange(of: isFocused) { _, isFocused in if !isFocused { commit() } }
            .onChange(of: seconds, initial: true) { text = formatClock(seconds: seconds) }
            .help("Type a time like 25, 1:30 or 1h30m, then press Return to start")
    }

    /// Keeps a time that parses and puts back the last good one otherwise.
    @discardableResult
    private func commit() -> Bool {
        let parsed = parseDuration(text)
        if let parsed { seconds = parsed }
        text = formatClock(seconds: seconds)
        return parsed != nil
    }
}

/// Every lap, newest first: its own time, then the stopwatch reading when it was marked.
private struct LapList: View {
    let laps: [TimeInterval]

    var body: some View {
        let splits = getLapSplits(laps)
        VStack(alignment: .leading, spacing: 6) {
            Label("Laps", systemImage: "flag")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(splits.indices.reversed(), id: \.self) { index in
                        HStack {
                            Text("Lap \(index + 1)")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(formatTenths(splits[index]))
                            Text(formatTenths(laps[index]))
                                .foregroundStyle(.tertiary)
                                .frame(width: 58, alignment: .trailing)
                        }
                    }
                }
                .font(.caption.monospacedDigit())
            }
            .scrollIndicators(.never)
        }
        .padding(12)
    }
}

/// A selectable capsule, like the provider switcher in AI Usage.
private struct Chip: View {
    let title: String
    var systemImage: String?
    var font = Font.callout.weight(.medium)
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(font)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? Color.primary.opacity(0.15) : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? .primary : .secondary)
    }
}

private struct TimerSettings: View {
    @AppStorage(focusMinutesKey) private var focusMinutes = defaultFocusMinutes
    @AppStorage(shortBreakMinutesKey) private var shortBreakMinutes = defaultShortBreakMinutes
    @AppStorage(longBreakMinutesKey) private var longBreakMinutes = defaultLongBreakMinutes
    @AppStorage(longBreakEveryKey) private var longBreakEvery = defaultLongBreakEvery
    @AppStorage(autoStartsNextKey) private var autoStartsNext = false
    @AppStorage(playsSoundKey) private var playsSound = true
    @AppStorage(soundNameKey) private var soundName = defaultSoundName
    @AppStorage(showsActivityKey) private var showsActivity = true
    @State private var sounds: [String] = []

    var body: some View {
        Form {
            Section("Pomodoro") {
                Stepper("Focus: \(focusMinutes) min", value: $focusMinutes, in: 1...180)
                Stepper("Short break: \(shortBreakMinutes) min", value: $shortBreakMinutes, in: 1...60)
                Stepper("Long break: \(longBreakMinutes) min", value: $longBreakMinutes, in: 1...120)
                Picker("Long break after", selection: $longBreakEvery) {
                    Text("Never").tag(0)
                    ForEach(2...8, id: \.self) { Text("\($0) focus sessions").tag($0) }
                }
                Toggle("Start the next phase on its own", isOn: $autoStartsNext)
            }
            Section("When time is up") {
                Toggle("Play a sound", isOn: $playsSound)
                Picker("Sound", selection: $soundName) {
                    ForEach(sounds, id: \.self) { Text($0).tag($0) }
                }
                .disabled(!playsSound)
                .onChange(of: soundName) { NSSound(named: NSSound.Name(soundName))?.play() }
            }
            Section("Closed notch") {
                Toggle("Show running clocks", isOn: $showsActivity)
            }
        }
        .formStyle(.grouped)
        .onAppear { sounds = listSystemSounds() }
    }
}
