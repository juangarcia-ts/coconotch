import Foundation

/// A clock that can pause: time banked from earlier runs plus the current run. It is worked out from dates rather than
/// counted in ticks, so it stays exact however often the view redraws and across sleep.
public struct RunClock: Equatable, Sendable {
    public private(set) var banked: TimeInterval = 0
    public private(set) var startedAt: Date?

    public init() {}

    public var isRunning: Bool { startedAt != nil }

    public func getElapsed(at now: Date) -> TimeInterval {
        banked + (startedAt.map { now.timeIntervalSince($0) } ?? 0)
    }

    public mutating func start(at now: Date) {
        if startedAt == nil { startedAt = now }
    }

    public mutating func pause(at now: Date) {
        banked = getElapsed(at: now)
        startedAt = nil
    }
}

public func getRemaining(_ clock: RunClock, duration: TimeInterval, at now: Date) -> TimeInterval {
    max(0, duration - clock.getElapsed(at: now))
}

/// When a running countdown reaches zero; nil while it is paused.
public func getFinishDate(_ clock: RunClock, duration: TimeInterval) -> Date? {
    clock.startedAt.map { $0 + (duration - clock.banked) }
}

/// "4:05", or "1:04:05" from an hour up.
public func formatClock(seconds: Int) -> String {
    let seconds = max(0, seconds)
    let hours = seconds / 3600
    let minutes = seconds / 60 % 60
    let rest = seconds % 60
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, rest)
        : String(format: "%d:%02d", minutes, rest)
}

/// A countdown shows whole seconds rounded up, so it reads 0:00 only once it is done.
public func formatCountdown(_ remaining: TimeInterval) -> String {
    formatClock(seconds: Int(remaining.rounded(.up)))
}

public enum PomodoroPhase: String, Sendable {
    case focus, shortBreak, longBreak
}

/// What follows a finished phase. `completedFocusCount` includes a focus that just finished; every
/// `longBreakEvery`th focus earns the long break.
public func getNextPomodoroPhase(
    after phase: PomodoroPhase, completedFocusCount: Int, longBreakEvery: Int
) -> PomodoroPhase {
    guard phase == .focus else { return .focus }
    return longBreakEvery > 0 && completedFocusCount % longBreakEvery == 0 ? .longBreak : .shortBreak
}

/// Each lap's own time, from the stopwatch readings taken when Lap was pressed.
public func getLapSplits(_ laps: [TimeInterval]) -> [TimeInterval] {
    zip(laps, [0] + laps).map { $0 - $1 }
}
