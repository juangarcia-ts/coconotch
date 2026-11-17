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

@Test func parsesAlbumPositionAndDuration() {
    let track = parseNowPlaying("playing\tSo What\tMiles Davis\t\tKind of Blue\t12,5\t545\t40", player: "Music")
    #expect(track?.album == "Kind of Blue")
    #expect(track?.position == 12.5)
    #expect(track?.duration == 545)
    #expect(track?.volume == 40)
}

@Test func countsPlaybackOnFromTheLastRead() {
    let readAt = Date(timeIntervalSince1970: 0)
    let playing = NowPlaying(player: "Music", title: "A", artist: "", position: 10, duration: 12, isPlaying: true)
    #expect(getPlaybackPosition(playing, readAt: readAt, now: readAt.addingTimeInterval(1.5)) == 11.5)
    #expect(getPlaybackPosition(playing, readAt: readAt, now: readAt.addingTimeInterval(5)) == 12)
    let paused = NowPlaying(player: "Music", title: "A", artist: "", position: 10, isPlaying: false)
    #expect(getPlaybackPosition(paused, readAt: readAt, now: readAt.addingTimeInterval(5)) == 10)
}
