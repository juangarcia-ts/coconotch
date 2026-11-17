import CocoNotchCore
import Foundation
import Testing

@Test func parsesLRCInTimeOrder() {
    let lines = parseLRC("[ar: Miles Davis]\n[00:12.50] So what\n[01:02.00][00:30.00] Again\nno stamp")
    #expect(
        lines == [
            LyricLine(time: 12.5, text: "So what"),
            LyricLine(time: 30, text: "Again"),
            LyricLine(time: 62, text: "Again"),
        ])
}

@Test func prefersSyncedLyricsFromTheSearch() throws {
    let json = """
        [{"syncedLyrics": null, "plainLyrics": "Plain"},
         {"syncedLyrics": "[00:01.00] Timed", "plainLyrics": "Timed"}]
        """
    #expect(try parseLyricsSearch(Data(json.utf8)) == [LyricLine(time: 1, text: "Timed")])
}

@Test func fallsBackToPlainLyrics() throws {
    let json = #"[{"syncedLyrics": null, "plainLyrics": "One\nTwo"}]"#
    #expect(
        try parseLyricsSearch(Data(json.utf8)) == [
            LyricLine(time: nil, text: "One"), LyricLine(time: nil, text: "Two"),
        ])
}

@Test func findsNoLyricsForInstrumentals() throws {
    #expect(try parseLyricsSearch(Data(#"[{"syncedLyrics": null, "plainLyrics": null}]"#.utf8)).isEmpty)
    #expect(try parseLyricsSearch(Data("[]".utf8)).isEmpty)
}

@Test func findsTheLineBeingSung() {
    let lines = [LyricLine(time: 5, text: "a"), LyricLine(time: 10, text: "b")]
    #expect(getCurrentLyricIndex(lines, position: 2) == nil)
    #expect(getCurrentLyricIndex(lines, position: 7) == 0)
    #expect(getCurrentLyricIndex(lines, position: 10) == 1)
    #expect(getCurrentLyricIndex([LyricLine(time: nil, text: "a")], position: 7) == nil)
}

@Test func buildsTheLyricsSearchURL() {
    #expect(
        makeLyricsSearchURL(title: "So What", artist: "Miles Davis")?.absoluteString
            == "https://lrclib.net/api/search?track_name=So%20What&artist_name=Miles%20Davis")
}
