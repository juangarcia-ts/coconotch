import AppKit
import CocoNotchCore
import SwiftUI

let showsMusicKey = "home.showsMusic"

// Listed in the order that wins when neither is playing. Only Spotify's dictionary exposes an artwork URL.
private let players: [(name: String, bundleID: String, artwork: String)] = [
    ("Spotify", "com.spotify.client", "artwork url of t"),
    ("Music", "com.apple.Music", "\"\""),
]

private func runScript(_ source: String) -> String? {
    var error: NSDictionary?
    return NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
}

// Only running players are asked, since telling a closed app anything launches it.
@MainActor private func readNowPlaying() -> NowPlaying? {
    let runningIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    return pickNowPlaying(
        players.filter { runningIDs.contains($0.bundleID) }.compactMap { player in
            let output = runScript(
                """
                tell application "\(player.name)"
                    if player state is stopped then return "stopped"
                    set t to current track
                    return (player state as text) & tab & (name of t) & tab & (artist of t) & tab & \(player.artwork)
                end tell
                """
            )
            return output.flatMap { parseNowPlaying($0, player: player.name) }
        }
    )
}

struct NowPlayingPanel: View {
    @State private var nowPlaying: NowPlaying?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: nowPlaying?.artworkURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "music.note")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.primary.opacity(0.06))
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(nowPlaying?.title ?? "Nothing playing")
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            Text(nowPlaying?.artist ?? "Music or Spotify")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            HStack(spacing: 16) {
                controlButton("Previous", systemImage: "backward.fill", command: "previous track")
                controlButton(
                    nowPlaying?.isPlaying == true ? "Pause" : "Play",
                    systemImage: nowPlaying?.isPlaying == true ? "pause.fill" : "play.fill",
                    command: "playpause"
                )
                controlButton("Next", systemImage: "forward.fill", command: "next track")
            }
            .disabled(nowPlaying == nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        // ponytail: polls once a second while Home is open; switch to the players' distributed notifications if
        // AppleScript cost shows up.
        .task {
            while !Task.isCancelled {
                nowPlaying = readNowPlaying()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func controlButton(_ title: String, systemImage: String, command: String) -> some View {
        Button(title, systemImage: systemImage) {
            guard let player = nowPlaying?.player else { return }
            _ = runScript("tell application \"\(player)\" to \(command)")
            nowPlaying = readNowPlaying()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .help(title)
    }
}
