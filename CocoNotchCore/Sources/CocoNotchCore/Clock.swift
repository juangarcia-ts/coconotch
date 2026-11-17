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

/// "1:05.3", for laps that can be shorter than a second.
public func formatTenths(_ seconds: TimeInterval) -> String {
    let tenths = Int((max(0, seconds) * 10).rounded())
    return "\(formatClock(seconds: tenths / 10)).\(tenths % 10)"
}

/// Seconds from a typed duration: "25" is minutes, "1:30" minutes and seconds, "1:00:00" adds hours, and "1h30m"
/// or "90s" use units. Nil when it isn't one, or isn't between a second and a day.
public func parseDuration(_ text: String) -> Int? {
    let text = text.lowercased().filter { !$0.isWhitespace }
    // Short enough that no number can overflow.
    guard !text.isEmpty, text.count <= 9 else { return nil }
    let seconds: Int
    if text.contains(":") {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).compactMap { Int($0) }
        guard (2...3).contains(parts.count), parts.count == text.filter({ $0 == ":" }).count + 1,
            parts.allSatisfy({ $0 >= 0 })
        else { return nil }
        seconds = parts.reduce(0) { $0 * 60 + $1 }
    } else if let minutes = Int(text) {
        seconds = minutes * 60
    } else {
        let units: [Character: Int] = ["h": 3600, "m": 60, "s": 1]
        var total = 0
        var number = ""
        for character in text {
            if character.isASCII, character.isNumber {
                number.append(character)
            } else {
                guard let value = Int(number), let unit = units[character] else { return nil }
                total += value * unit
                number = ""
            }
        }
        guard number.isEmpty else { return nil }
        seconds = total
    }
    return (1...86_400).contains(seconds) ? seconds : nil
}

public enum PomodoroPhase: String, Sendable {
    case focus, shortBreak, longBreak
}

/// The phase after the current one and the new focus count. Only a finished focus counts, and every
/// `longBreakEvery`th earns the long break; a skipped focus leads to a short break.
public func advancePomodoro(
    phase: PomodoroPhase, focusCount: Int, isFinished: Bool, longBreakEvery: Int
) -> (phase: PomodoroPhase, focusCount: Int) {
    guard phase == .focus else { return (.focus, focusCount) }
    guard isFinished else { return (.shortBreak, focusCount) }
    let count = focusCount + 1
    return (longBreakEvery > 0 && count % longBreakEvery == 0 ? .longBreak : .shortBreak, count)
}

/// Each lap's own time, from the stopwatch readings taken when Lap was pressed.
public func getLapSplits(_ laps: [TimeInterval]) -> [TimeInterval] {
    zip(laps, [0] + laps).map { $0 - $1 }
}
