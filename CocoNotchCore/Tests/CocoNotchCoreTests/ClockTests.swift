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

@Test func everyFourthFinishedFocusEarnsALongBreak() {
    let third = advancePomodoro(phase: .focus, focusCount: 2, isFinished: true, longBreakEvery: 4)
    #expect(third.phase == .shortBreak && third.focusCount == 3)
    let fourth = advancePomodoro(phase: .focus, focusCount: 3, isFinished: true, longBreakEvery: 4)
    #expect(fourth.phase == .longBreak && fourth.focusCount == 4)
    let back = advancePomodoro(phase: .longBreak, focusCount: 4, isFinished: true, longBreakEvery: 4)
    #expect(back.phase == .focus && back.focusCount == 4)
    #expect(advancePomodoro(phase: .focus, focusCount: 3, isFinished: true, longBreakEvery: 0).phase == .shortBreak)
}

@Test func skippedFocusIsNotCounted() {
    let skipped = advancePomodoro(phase: .focus, focusCount: 3, isFinished: false, longBreakEvery: 4)
    #expect(skipped.phase == .shortBreak && skipped.focusCount == 3)
    let afterLongBreak = advancePomodoro(phase: .focus, focusCount: 4, isFinished: false, longBreakEvery: 4)
    #expect(afterLongBreak.phase == .shortBreak)
    let skippedBreak = advancePomodoro(phase: .shortBreak, focusCount: 3, isFinished: false, longBreakEvery: 4)
    #expect(skippedBreak.phase == .focus && skippedBreak.focusCount == 3)
}

@Test func splitsLaps() {
    #expect(getLapSplits([10, 25, 27]) == [10, 15, 2])
    #expect(getLapSplits([]) == [])
}
