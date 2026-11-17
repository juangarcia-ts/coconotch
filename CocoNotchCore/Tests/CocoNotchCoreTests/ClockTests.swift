import CocoNotchCore
import Foundation
import Testing

private let now = Date(timeIntervalSince1970: 10_000)

@Test func clockBanksTimeAcrossPauses() {
    var clock = RunClock()
    clock.start(at: now)
    clock.pause(at: now + 10)
    #expect(clock.getElapsed(at: now + 100) == 10)
    clock.start(at: now + 100)
    #expect(clock.getElapsed(at: now + 105) == 15)
}

@Test func startingARunningClockKeepsItsStart() {
    var clock = RunClock()
    clock.start(at: now)
    clock.start(at: now + 5)
    #expect(clock.getElapsed(at: now + 10) == 10)
}

@Test func countdownFinishesAfterTheTimeLeft() {
    var clock = RunClock()
    #expect(getFinishDate(clock, duration: 60) == nil)
    clock.start(at: now)
    clock.pause(at: now + 20)
    clock.start(at: now + 50)
    #expect(getFinishDate(clock, duration: 60) == now + 90)
    #expect(getRemaining(clock, duration: 60, at: now + 200) == 0)
}

@Test func formatsClocks() {
    #expect(formatClock(seconds: 0) == "0:00")
    #expect(formatClock(seconds: 245) == "4:05")
    #expect(formatClock(seconds: 3845) == "1:04:05")
    #expect(formatCountdown(1499.2) == "25:00")
    #expect(formatCountdown(0) == "0:00")
}

@Test func everyFourthFocusEarnsALongBreak() {
    #expect(getNextPomodoroPhase(after: .focus, completedFocusCount: 3, longBreakEvery: 4) == .shortBreak)
    #expect(getNextPomodoroPhase(after: .focus, completedFocusCount: 4, longBreakEvery: 4) == .longBreak)
    #expect(getNextPomodoroPhase(after: .longBreak, completedFocusCount: 4, longBreakEvery: 4) == .focus)
    #expect(getNextPomodoroPhase(after: .focus, completedFocusCount: 4, longBreakEvery: 0) == .shortBreak)
}

@Test func splitsLaps() {
    #expect(getLapSplits([10, 25, 27]) == [10, 15, 2])
    #expect(getLapSplits([]) == [])
}
