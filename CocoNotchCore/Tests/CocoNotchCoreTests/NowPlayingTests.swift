import CocoNotchCore
import Foundation
import Testing

@Test func parsesPlayingTrackWithArtwork() {
    #expect(
        parseNowPlaying("playing\tSo What\tMiles Davis\thttps://i.scdn.co/image/abc", player: "Spotify")
            == NowPlaying(
                player: "Spotify", title: "So What", artist: "Miles Davis",
                artworkURL: URL(string: "https://i.scdn.co/image/abc"), isPlaying: true))
}

@Test func parsesPausedTrackWithoutArtwork() {
    #expect(
        parseNowPlaying("paused\tBlue in Green\tMiles Davis\t", player: "Music")
            == NowPlaying(player: "Music", title: "Blue in Green", artist: "Miles Davis", isPlaying: false))
}

@Test(arguments: ["stopped", "", "playing\t\tNobody", "garbage"])
func rejectsNothingPlaying(output: String) {
    #expect(parseNowPlaying(output, player: "Music") == nil)
}

@Test func prefersThePlayingPlayer() {
    let paused = NowPlaying(player: "Spotify", title: "A", artist: "", isPlaying: false)
    let playing = NowPlaying(player: "Music", title: "B", artist: "", isPlaying: true)
    #expect(pickNowPlaying([paused, playing]) == playing)
    #expect(pickNowPlaying([paused]) == paused)
    #expect(pickNowPlaying([]) == nil)
}
