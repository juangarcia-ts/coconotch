import Foundation

public struct NowPlaying: Equatable, Sendable {
    /// The app that plays the track, as AppleScript names it ("Music", "Spotify"), so controls go to it.
    public let player: String
    public let title: String
    public let artist: String
    public let album: String
    public let artworkURL: URL?
    /// Seconds into the track when it was read.
    public let position: Double
    /// Seconds; 0 when the player doesn't say, as with radio streams.
    public let duration: Double
    /// 0–100.
    public let volume: Double
    public let isPlaying: Bool

    public init(
        player: String, title: String, artist: String, album: String = "", artworkURL: URL? = nil,
        position: Double = 0, duration: Double = 0, volume: Double = 0, isPlaying: Bool
    ) {
        self.player = player
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkURL = artworkURL
        self.position = position
        self.duration = duration
        self.volume = volume
        self.isPlaying = isPlaying
    }
}

/// Reads a player script's tab-separated "state, title, artist, artwork URL, album, position, duration, volume";
/// nil when stopped or unreadable.
public func parseNowPlaying(_ output: String, player: String) -> NowPlaying? {
    let fields = output.components(separatedBy: "\t")
    guard fields.count >= 3, fields[0] == "playing" || fields[0] == "paused", !fields[1].isEmpty else { return nil }
    let field = { (index: Int) in fields.count > index ? fields[index] : "" }
    // AppleScript writes reals with the system's decimal separator.
    let number = { (index: Int) in Double(field(index).replacingOccurrences(of: ",", with: ".")) ?? 0 }
    let artwork = URL(string: field(3))
    return NowPlaying(
        player: player,
        title: fields[1],
        artist: fields[2],
        album: field(4),
        artworkURL: artwork?.scheme == nil ? nil : artwork,
        position: number(5),
        duration: number(6),
        volume: number(7),
        isPlaying: fields[0] == "playing"
    )
}

/// A playing track beats a paused one; otherwise the first player in the list wins.
public func pickNowPlaying(_ candidates: [NowPlaying]) -> NowPlaying? {
    candidates.first(where: \.isPlaying) ?? candidates.first
}

/// Where a track is now, counting on from the last read so the lyrics move between polls.
public func getPlaybackPosition(_ nowPlaying: NowPlaying, readAt: Date, now: Date) -> Double {
    guard nowPlaying.isPlaying else { return nowPlaying.position }
    let position = nowPlaying.position + now.timeIntervalSince(readAt)
    return nowPlaying.duration > 0 ? min(position, nowPlaying.duration) : position
}

/// The value under a drag at `x` along a slider `width` points wide, clamped to the range. The knob's center can only
/// travel between half a knob from each end, so that stretch maps to the whole range.
public func getSliderValue(atX x: Double, width: Double, knobSize: Double, range: ClosedRange<Double>) -> Double {
    let travel = width - knobSize
    guard travel > 0 else { return range.lowerBound }
    let fraction = min(max((x - knobSize / 2) / travel, 0), 1)
    return range.lowerBound + fraction * (range.upperBound - range.lowerBound)
}

/// `value` moved by `steps` twentieths of the range, clamped to it.
public func getSteppedSliderValue(_ value: Double, steps: Int, range: ClosedRange<Double>) -> Double {
    let step = (range.upperBound - range.lowerBound) / 20
    return min(max(value + Double(steps) * step, range.lowerBound), range.upperBound)
}

/// How far along the range `value` is, from 0 to 1; 0 for an empty range.
public func getSliderFraction(_ value: Double, range: ClosedRange<Double>) -> Double {
    let span = range.upperBound - range.lowerBound
    guard span > 0 else { return 0 }
    return min(max((value - range.lowerBound) / span, 0), 1)
}
