import Foundation

public struct LyricLine: Equatable, Sendable {
    /// Seconds into the track; nil for lyrics that aren't timed.
    public let time: Double?
    public let text: String

    public init(time: Double?, text: String) {
        self.time = time
        self.text = text
    }
}

public func makeLyricsSearchURL(title: String, artist: String) -> URL? {
    var components = URLComponents(string: "https://lrclib.net/api/search")
    components?.queryItems = [
        URLQueryItem(name: "track_name", value: title),
        URLQueryItem(name: "artist_name", value: artist),
    ]
    return components?.url
}

private struct LyricsResult: Decodable {
    let syncedLyrics: String?
    let plainLyrics: String?
}

/// The best lyrics LRCLIB found: the first timed ones, else the first plain ones; empty when there are none.
public func parseLyricsSearch(_ data: Data) throws -> [LyricLine] {
    let results = try JSONDecoder().decode([LyricsResult].self, from: data)
    if let synced = results.lazy.compactMap(\.syncedLyrics).first(where: { !$0.isEmpty }) {
        return parseLRC(synced)
    }
    let plain = results.lazy.compactMap(\.plainLyrics).first { !$0.isEmpty } ?? ""
    return plain.isEmpty ? [] : plain.components(separatedBy: "\n").map { LyricLine(time: nil, text: $0) }
}

/// Reads "[mm:ss.xx] text" lines, a line with several stamps once per stamp, in time order. Tags like "[ar: …]"
/// carry no time and are dropped.
public func parseLRC(_ text: String) -> [LyricLine] {
    text.components(separatedBy: .newlines).flatMap { line -> [LyricLine] in
        var rest = Substring(line)
        var times: [Double] = []
        while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            let parts = rest[rest.index(after: rest.startIndex)..<close].split(separator: ":")
            if parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]) {
                times.append(minutes * 60 + seconds)
            }
            rest = rest[rest.index(after: close)...]
        }
        let words = rest.trimmingCharacters(in: .whitespaces)
        return times.map { LyricLine(time: $0, text: words) }
    }
    .sorted { ($0.time ?? 0) < ($1.time ?? 0) }
}

/// The line being sung at `position`: the last one that has started. Nil before the first line or for untimed lyrics.
public func getCurrentLyricIndex(_ lines: [LyricLine], position: Double) -> Int? {
    lines.lastIndex { ($0.time ?? .infinity) <= position }
}
