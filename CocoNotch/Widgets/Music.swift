import AppKit
import CocoNotchCore
import SwiftUI

extension NotchWidget {
    static let music = NotchWidget(
        id: "music",
        title: String(localized: "Music"),
        systemImage: "music.note",
        makeView: { AnyView(MusicView()) },
        makeSettings: { AnyView(MusicSettings()) }
    )
}

let showsMusicKey = "home.showsMusic"
private let showsLyricsKey = "music.showsLyrics"
private let showsAlbumKey = "music.showsAlbum"
private let showsProgressKey = "music.showsProgress"
private let showsVolumeKey = "music.showsVolume"
private let showsInNotchKey = "music.showsInNotch"
private let nowPlayingActivityID = "music.nowPlaying"

// Listed in the order that wins when neither is playing. Only Spotify's dictionary has an artwork URL, and it gives
// durations in milliseconds.
private let players: [(name: String, bundleID: String, artwork: String, duration: String, notification: String)] = [
    (
        "Spotify", "com.spotify.client", "artwork url of t", "(duration of t) / 1000",
        "com.spotify.client.PlaybackStateChanged"
    ),
    ("Music", "com.apple.Music", "\"\"", "duration of t", "com.apple.Music.playerInfo"),
]

/// Runs AppleScript off the main thread, one script at a time since `NSAppleScript` isn't thread-safe, so a busy
/// player can't freeze the notch.
private actor ScriptRunner {
    /// The script's text, or nil when it failed; `isDenied` when the user hasn't allowed CocoNotch to control the app.
    func run(_ source: String) -> (output: String?, isDenied: Bool) {
        var error: NSDictionary?
        let output = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
        // -1743 is errAEEventNotPermitted: the Automation permission was denied.
        return (output, error?[NSAppleScript.errorNumber] as? Int == -1743)
    }
}

/// What's playing, for the whole app, so the closed notch can show it too, not just the Music tab.
@Observable
final class MusicStore {
    static let shared = MusicStore()

    private(set) var nowPlaying: NowPlaying?
    /// When `nowPlaying` was read, to count its position on from.
    private(set) var readAt = Date.now
    /// A running player macOS won't let CocoNotch control, so the views can say where to allow it.
    private(set) var deniedPlayer: String?
    private let scriptRunner = ScriptRunner()
    private var isStarted = false

    /// The players announce play, pause and track changes, so the closed notch follows them without polling.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        for player in players {
            DistributedNotificationCenter.default().addObserver(
                forName: .init(player.notification), object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
        }
        // A player that quits doesn't always announce it stopped, which would leave its song in the closed notch.
        let playerIDs = Set(players.map(\.bundleID))
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let id = app?.bundleIdentifier, playerIDs.contains(id) else { return }
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    // Only running players are asked, since telling a closed app anything launches it.
    func refresh() async {
        let runningIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        var tracks: [NowPlaying] = []
        var denied: String?
        for player in players where runningIDs.contains(player.bundleID) {
            // The timeout caps a hung player at a few seconds instead of the default two minutes.
            let result = await scriptRunner.run(
                """
                tell application "\(player.name)"
                    with timeout of 3 seconds
                        if player state is stopped then return "stopped"
                        set t to current track
                        return (player state as text) & tab & (name of t) & tab & (artist of t) & tab ¬
                            & \(player.artwork) & tab & (album of t) & tab & ((player position) as text) & tab ¬
                            & ((\(player.duration)) as text) & tab & ((sound volume) as text)
                    end timeout
                end tell
                """
            )
            if result.isDenied { denied = player.name }
            if let track = result.output.flatMap({ parseNowPlaying($0, player: player.name) }) { tracks.append(track) }
        }
        nowPlaying = pickNowPlaying(tracks)
        deniedPlayer = denied
        readAt = .now
        updateActivity()
    }

    /// Re-reads once a second while a music view is open, since seeking and volume aren't announced.
    func poll() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    func send(_ command: String) {
        guard let player = nowPlaying?.player else { return }
        Task {
            _ = await scriptRunner.run("tell application \"\(player)\" to \(command)")
            await refresh()
        }
    }

    func getPosition(at date: Date) -> Double {
        nowPlaying.map { getPlaybackPosition($0, readAt: readAt, now: date) } ?? 0
    }

    private func updateActivity() {
        let showsInNotch = UserDefaults.standard.object(forKey: showsInNotchKey) as? Bool ?? true
        guard showsInNotch, nowPlaying?.isPlaying == true else {
            ActivityCenter.shared.remove(id: nowPlayingActivityID)
            return
        }
        // The island's views read the store, so it's posted once rather than on every refresh.
        guard ActivityCenter.shared.activities[nowPlayingActivityID] == nil else { return }
        ActivityCenter.shared.post(
            NotchActivity(
                id: nowPlayingActivityID,
                widgetID: NotchWidget.music.id,
                priority: .background,
                sortDate: .distantFuture,
                makeLeading: { AnyView(IslandTrack()) },
                makeTrailing: { AnyView(IslandProgress()) },
                makeCompact: { AnyView(IslandCompact()) }
            )
        )
    }
}

// Kept for the app's lifetime so reopening the notch doesn't fetch the same song again.
private var lyricsCache: [String: [LyricLine]] = [:]

private func loadLyrics(for track: NowPlaying) async -> [LyricLine] {
    let key = "\(track.title)\t\(track.artist)"
    if let cached = lyricsCache[key] { return cached }
    guard let url = makeLyricsSearchURL(title: track.title, artist: track.artist) else { return [] }
    var request = URLRequest(url: url)
    // LRCLIB asks clients to name themselves.
    request.setValue("CocoNotch (https://github.com/juangarcia-ts/coconotch)", forHTTPHeaderField: "User-Agent")
    guard let (data, _) = try? await URLSession.shared.data(for: request) else { return [] }
    let lines = (try? parseLyricsSearch(data)) ?? []
    lyricsCache[key] = lines
    return lines
}

private struct IslandTrack: View {
    var body: some View {
        HStack(spacing: 6) {
            Artwork(url: MusicStore.shared.nowPlaying?.artworkURL, size: 18)
            Text(MusicStore.shared.nowPlaying?.title ?? "")
        }
    }
}

private struct IslandCompact: View {
    var body: some View {
        HStack(spacing: 6) {
            Artwork(url: MusicStore.shared.nowPlaying?.artworkURL, size: 18)
            Image(systemName: "waveform")
                .symbolEffect(.variableColor.iterative, isActive: MusicStore.shared.nowPlaying?.isPlaying == true)
                .foregroundStyle(.secondary)
        }
    }
}

private func formatTrackTime(_ seconds: Double) -> String {
    Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
}

private struct IslandProgress: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let duration = MusicStore.shared.nowPlaying?.duration ?? 0
            let elapsed = formatTrackTime(MusicStore.shared.getPosition(at: context.date))
            // Radio streams have no length, so only the elapsed time shows.
            HStack(spacing: 6) {
                Text(duration > 0 ? "\(elapsed) / \(formatTrackTime(duration))" : elapsed)
                    .monospacedDigit()
                Image(systemName: "waveform")
                    .symbolEffect(.variableColor.iterative, isActive: MusicStore.shared.nowPlaying?.isPlaying == true)
            }
            .foregroundStyle(.secondary)
        }
    }
}

private struct Artwork: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "music.note")
                .font(.system(size: size * 0.4))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.primary.opacity(0.06))
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size / 7))
    }
}

/// A slider that holds its own value while dragged and reports it on release, so the once-a-second refresh doesn't
/// pull the knob back mid-drag and the player gets one command per change.
private struct ReleaseSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let onRelease: (Double) -> Void
    @State private var draggedValue: Double?

    var body: some View {
        Slider(
            value: Binding(get: { draggedValue ?? value }, set: { draggedValue = $0 }),
            in: range
        ) { isEditing in
            guard !isEditing, let draggedValue else { return }
            onRelease(draggedValue)
            self.draggedValue = nil
        }
        .controlSize(.mini)
    }
}

private struct SeekBar: View {
    let track: NowPlaying

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let position = MusicStore.shared.getPosition(at: context.date)
            VStack(spacing: 0) {
                ReleaseSlider(value: position, range: 0...track.duration) {
                    MusicStore.shared.send("set player position to \($0)")
                }
                HStack {
                    Text(formatTrackTime(position))
                    Spacer()
                    Text(formatTrackTime(track.duration))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct PlayerControls: View {
    let nowPlaying: NowPlaying?

    var body: some View {
        HStack(spacing: 16) {
            button("Previous", systemImage: "backward.fill", command: "previous track")
            button(
                nowPlaying?.isPlaying == true ? "Pause" : "Play",
                systemImage: nowPlaying?.isPlaying == true ? "pause.fill" : "play.fill",
                command: "playpause"
            )
            button("Next", systemImage: "forward.fill", command: "next track")
        }
        .disabled(nowPlaying == nil)
    }

    private func button(_ title: LocalizedStringKey, systemImage: String, command: String) -> some View {
        Button(title, systemImage: systemImage) { MusicStore.shared.send(command) }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .help(title)
    }
}

/// macOS asks for Automation only once, so after a "Don't Allow" the only way back is System Settings.
private struct AutomationHint: View {
    let player: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("CocoNotch isn't allowed to control \(player).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Allow in System Settings") { openPrivacySettings("Privacy_Automation") }
                .buttonStyle(.link)
                .font(.caption)
        }
    }
}

struct NowPlayingPanel: View {
    @AppStorage(PreferenceKey.selectedWidget) private var selectedWidgetID = ""

    var body: some View {
        let nowPlaying = MusicStore.shared.nowPlaying
        VStack(alignment: .leading, spacing: 4) {
            Artwork(url: nowPlaying?.artworkURL, size: 56)
                .padding(.bottom, 2)
            Text(nowPlaying?.title ?? String(localized: "Nothing playing"))
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            if nowPlaying == nil, let player = MusicStore.shared.deniedPlayer {
                AutomationHint(player: player)
            } else {
                Text(nowPlaying?.artist ?? String(localized: "Music or Spotify"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let nowPlaying, nowPlaying.duration > 0 {
                SeekBar(track: nowPlaying)
            }
            PlayerControls(nowPlaying: nowPlaying)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // Stretches to the cards beside it, so the content sits in the middle rather than leaving a gap inside.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture { selectedWidgetID = NotchWidget.music.id }
        .help("Open Music")
        .task { await MusicStore.shared.poll() }
    }
}

private struct MusicView: View {
    @AppStorage(showsLyricsKey) private var showsLyrics = true
    @AppStorage(showsAlbumKey) private var showsAlbum = true
    @AppStorage(showsProgressKey) private var showsProgress = true
    @AppStorage(showsVolumeKey) private var showsVolume = true
    /// Nil while loading.
    @State private var lyrics: [LyricLine]?

    var body: some View {
        let nowPlaying = MusicStore.shared.nowPlaying
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Artwork(url: nowPlaying?.artworkURL, size: 72)
                Text(nowPlaying?.title ?? String(localized: "Nothing playing"))
                    .font(.headline)
                    .lineLimit(2)
                if nowPlaying == nil, let player = MusicStore.shared.deniedPlayer {
                    AutomationHint(player: player)
                } else {
                    Text(nowPlaying?.artist ?? String(localized: "Play something in Music or Spotify."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if showsAlbum, let album = nowPlaying?.album, !album.isEmpty {
                    Text(album)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if showsProgress, let nowPlaying, nowPlaying.duration > 0 {
                    SeekBar(track: nowPlaying)
                }
                HStack(spacing: 12) {
                    PlayerControls(nowPlaying: nowPlaying)
                        .font(.title3)
                    if showsVolume, let nowPlaying {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ReleaseSlider(value: nowPlaying.volume, range: 0...100) {
                            MusicStore.shared.send("set sound volume to \(Int($0))")
                        }
                    }
                }
            }
            .frame(width: 220, alignment: .leading)
            if showsLyrics, let nowPlaying {
                lyricsView(for: nowPlaying)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 190)
        .task { await MusicStore.shared.poll() }
        .task(id: showsLyrics ? nowPlaying.map { "\($0.title)\t\($0.artist)" } : nil) {
            guard showsLyrics, let nowPlaying else { return }
            lyrics = nil
            lyrics = await loadLyrics(for: nowPlaying)
        }
    }

    @ViewBuilder private func lyricsView(for track: NowPlaying) -> some View {
        switch lyrics {
        case nil:
            placeholder("Looking for lyrics…")
        case let lines? where lines.isEmpty:
            placeholder("No lyrics for this song.")
        case let lines?:
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                LyricsList(
                    lines: lines,
                    currentIndex: getCurrentLyricIndex(lines, position: MusicStore.shared.getPosition(at: context.date))
                )
            }
        }
    }

    private func placeholder(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LyricsList: View {
    let lines: [LyricLine]
    let currentIndex: Int?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(lines.indices, id: \.self) { index in
                        line(lines[index], isCurrent: index == currentIndex)
                            .id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 60)
            }
            .scrollIndicators(.never)
            .onChange(of: currentIndex, initial: true) { _, index in
                guard let index else { return }
                withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(index, anchor: .center) }
            }
        }
    }

    @ViewBuilder private func line(_ line: LyricLine, isCurrent: Bool) -> some View {
        let text = Text(line.text.isEmpty ? "♪" : line.text)
            .font(.callout.weight(isCurrent ? .semibold : .regular))
            // Untimed lyrics have no current line, so they read at one level.
            .foregroundStyle(currentIndex == nil || isCurrent ? .primary : .tertiary)
        if let time = line.time {
            Button {
                MusicStore.shared.send("set player position to \(time)")
            } label: {
                text
            }
            .buttonStyle(.plain)
            .help("Play from here")
        } else {
            text
        }
    }
}

private struct MusicSettings: View {
    @AppStorage(showsLyricsKey) private var showsLyrics = true
    @AppStorage(showsAlbumKey) private var showsAlbum = true
    @AppStorage(showsProgressKey) private var showsProgress = true
    @AppStorage(showsVolumeKey) private var showsVolume = true
    @AppStorage(showsInNotchKey) private var showsInNotch = true
    @AppStorage(showsMusicKey) private var showsOnHome = true

    var body: some View {
        Form {
            Section {
                Text("Shows what's playing in Music or Spotify. macOS asks once to let CocoNotch control them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Album", isOn: $showsAlbum)
                Toggle("Progress", isOn: $showsProgress)
                Toggle("Volume", isOn: $showsVolume)
                Toggle("Show on Home", isOn: $showsOnHome)
                Toggle("Show the playing song in the closed notch", isOn: $showsInNotch)
                    .onChange(of: showsInNotch) { Task { await MusicStore.shared.refresh() } }
            }
            Section("Lyrics") {
                Toggle("Show lyrics", isOn: $showsLyrics)
                Text(
                    "Looks up the song's title and artist on LRCLIB. Timed lyrics follow along; click a line to play from there."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
