import Foundation

public struct NowPlaying: Equatable, Sendable {
    /// The app that plays the track, as AppleScript names it ("Music", "Spotify"), so controls go to it.
    public let player: String
    public let title: String
    public let artist: String
    public let artworkURL: URL?
    public let isPlaying: Bool

    public init(player: String, title: String, artist: String, artworkURL: URL? = nil, isPlaying: Bool) {
        self.player = player
        self.title = title
        self.artist = artist
        self.artworkURL = artworkURL
        self.isPlaying = isPlaying
    }
}

/// Reads a player script's tab-separated "state, title, artist, artwork URL"; nil when stopped or unreadable.
public func parseNowPlaying(_ output: String, player: String) -> NowPlaying? {
    let fields = output.components(separatedBy: "\t")
    guard fields.count >= 3, fields[0] == "playing" || fields[0] == "paused", !fields[1].isEmpty else { return nil }
    let artwork = fields.count > 3 ? URL(string: fields[3]) : nil
    return NowPlaying(
        player: player,
        title: fields[1],
        artist: fields[2],
        artworkURL: artwork?.scheme == nil ? nil : artwork,
        isPlaying: fields[0] == "playing"
    )
}

/// A playing track beats a paused one; otherwise the first player in the list wins.
public func pickNowPlaying(_ candidates: [NowPlaying]) -> NowPlaying? {
    candidates.first(where: \.isPlaying) ?? candidates.first
}
