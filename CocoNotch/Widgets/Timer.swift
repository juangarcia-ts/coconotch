import AppKit
import CocoNotchCore
import SwiftUI

extension NotchWidget {
    static let timer = NotchWidget(
        id: "timer",
        title: "Timer",
        systemImage: "timer",
        makeView: { AnyView(TimerView()) },
        makeSettings: { AnyView(TimerSettings()) }
    )
}

enum TimerMode: String, CaseIterable {
    case pomodoro, timer, stopwatch

    var title: String {
        switch self {
        case .pomodoro: "Pomodoro"
        case .timer: "Timer"
        case .stopwatch: "Stopwatch"
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
private let timerMinutesKey = "timer.timerMinutes"
private let focusMinutesKey = "timer.focusMinutes"
private let shortBreakMinutesKey = "timer.shortBreakMinutes"
private let longBreakMinutesKey = "timer.longBreakMinutes"
private let longBreakEveryKey = "timer.longBreakEvery"
private let autoStartsNextKey = "timer.autoStartsNext"
private let playsSoundKey = "timer.playsSound"
private let soundNameKey = "timer.soundName"
private let showsActivityKey = "timer.showsActivity"
private let defaultTimerMinutes = 10
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
    case .focus: "Focus"
    case .shortBreak: "Short break"
    case .longBreak: "Long break"
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
        let minutes =
            switch mode {
            case .pomodoro:
                switch phase {
                case .focus: readSetting(focusMinutesKey, default: defaultFocusMinutes)
                case .shortBreak: readSetting(shortBreakMinutesKey, default: defaultShortBreakMinutes)
                case .longBreak: readSetting(longBreakMinutesKey, default: defaultLongBreakMinutes)
                }
            case .timer: readSetting(timerMinutesKey, default: defaultTimerMinutes)
            case .stopwatch: 0
            }
        return TimeInterval(minutes * 60)
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
            message = "\(getTitle(finished)) done · \(getTitle(phase)) next"
        } else {
            countdown = RunClock()
            message = "Timer done"
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
    @AppStorage(timerMinutesKey) private var timerMinutes = defaultTimerMinutes
    @AppStorage(longBreakEveryKey) private var longBreakEvery = defaultLongBreakEvery
    private let store = TimerStore.shared

    var body: some View {
        let clock = store.getClock(mode)
        let duration = store.getDuration(mode)
        VStack(spacing: 12) {
            Picker("Mode", selection: $mode) {
                ForEach(TimerMode.allCases, id: \.self) { mode in
                    Label(mode.title, systemImage: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)

            caption(clock: clock)

            ClockText(clock: clock, duration: mode == .stopwatch ? nil : duration)
                .font(.system(size: 44, weight: .semibold, design: .rounded))

            if mode != .stopwatch {
                TimelineView(.periodic(from: clock.startedAt ?? .now, by: 1)) { context in
                    ProgressView(value: min(1, clock.getElapsed(at: context.date) / max(1, duration)))
                        .frame(maxWidth: 240)
                }
            }

            controls(clock: clock)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func caption(clock: RunClock) -> some View {
        switch mode {
        case .pomodoro:
            HStack(spacing: 6) {
                Text(getTitle(store.phase))
                if longBreakEvery > 0 {
                    // One dot per focus in the current round up to the long break.
                    let done = store.focusCount % longBreakEvery
                    ForEach(0..<longBreakEvery, id: \.self) { index in
                        Image(systemName: index < done ? "circle.fill" : "circle")
                            .font(.system(size: 6))
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .timer where !clock.isRunning && clock.banked == 0:
            HStack(spacing: 6) {
                ForEach(timerPresets, id: \.self) { minutes in
                    Button("\(minutes)m") { timerMinutes = minutes }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(minutes == timerMinutes ? .accentColor : nil)
                }
                Stepper("Minutes", value: $timerMinutes, in: 1...720)
                    .labelsHidden()
                    .controlSize(.small)
            }
        case .timer:
            Text("\(timerMinutes) min timer")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .stopwatch:
            let splits = getLapSplits(store.laps)
            HStack(spacing: 12) {
                // The latest laps, newest first.
                ForEach(Array(splits.enumerated().suffix(3).reversed()), id: \.offset) { index, split in
                    Text("Lap \(index + 1)  \(formatClock(seconds: Int(split)))")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(minHeight: 14)
        }
    }

    private func controls(clock: RunClock) -> some View {
        HStack(spacing: 10) {
            Button(clock.isRunning ? "Pause" : "Start", systemImage: clock.isRunning ? "pause.fill" : "play.fill") {
                store.toggle(mode)
            }
            .keyboardShortcut(.space, modifiers: [])
            .buttonStyle(.borderedProminent)
            switch mode {
            case .pomodoro:
                Button("Skip", systemImage: "forward.end.fill") { store.skipPhase() }
                    .help("Go to the next phase")
            case .stopwatch:
                Button("Lap", systemImage: "flag.fill") { store.lap() }
                    .disabled(!clock.isRunning)
            case .timer:
                EmptyView()
            }
            Button("Reset", systemImage: "arrow.counterclockwise") { store.reset(mode) }
                .disabled(!clock.isRunning && clock.banked == 0 && (mode != .pomodoro || store.focusCount == 0))
        }
        .controlSize(.large)
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
