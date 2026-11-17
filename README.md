# CocoNotch

A modular widget hub for the MacBook notch and menu bar, focused on the workday.

Hover (or click) the notch to expand it; each widget is a tab, and ⌘1…⌘0, then ⌥⌘1…⌥⌘0, switch between them once the notch has focus. Shortcuts you record in Settings open the notch, or a single widget, from any app. The closed notch shows live activities, like a meeting about to start or the song that's playing.

Open **Settings…** (⌘,) from the menu bar icon:

- **General**: open on hover or click, which displays show the notch, live activities and launch at login.
- **Shortcuts**: a system-wide shortcut to open or close the notch (⌥⌘N by default), one per widget, and the ⌘1… tab shortcuts (visible, hidden or off).
- **Appearance**: solid or blurred background, its color and opacity, and the notch size.
- **Widgets**: switch widgets on or off, drag to reorder them and pick which widget's activity the closed notch shows first, plus a tab with each widget's options.

## Widgets

- **Home**: always the first tab, with compact cards from the other widgets you pick, what's playing and a quick Ask field.

- **Time Zones**: your local time plus any cities you add, with country flags, custom labels and a slider to scrub ahead or back.

- **Meetings**: your next meeting with a countdown and a Join button for Meet, Zoom and Teams links, plus the rest of today. Reads every calendar on your Mac (Google, Outlook, iCloud) through macOS Calendar. Choose which calendars to show, hide all-day or declined events and get a heads-up before a meeting starts. When nothing else is in the closed notch, it shows your next meeting today (you can turn this off).

- **Weather**: current conditions with hourly and daily forecasts from [Open-Meteo](https://open-meteo.com), for your location or a city you pick, in °C or °F.

- **AI Usage**: how much of your Claude Code and Codex limits you've used, with a heads-up in the closed notch when one gets close. Reads the login Claude Code keeps in your Keychain (only after you click Connect) and Codex's local session logs.

- **Music**: what's playing in Music or Spotify, with playback and volume controls, synced lyrics from [LRCLIB](https://lrclib.net) and the current song in the closed notch.

- **System**: CPU, memory, disk and battery, with graphs of the last minute and a low battery heads-up.

- **Clipboard**: a searchable history of copied text and images, with pinned items and apps to ignore. Click an item to copy it back, or to paste it straight into the app you're in.

- **Shelf**: drop files, links or text on the notch, open or closed, and drag them back out later. Files stay put when the original moves, with Quick Look, AirDrop and Share.

- **Convert**: drop images, videos or PDFs to convert them: images between HEIC, JPEG, PNG, TIFF, GIF and BMP; PDF pages to images, or images and PDFs combined into one PDF; videos to MP4, MOV, audio or a GIF.

- **Ask**: quick answers from Apple Intelligence, made on your Mac so nothing leaves it, with past chats kept if you want them.

- **Camera**: a mirrored preview from any camera, to check how you look before a call.

## Permissions

macOS asks for each one the first time a widget needs it:

- **Calendars** for Meetings.
- **Location** for Weather, unless you pick a city.
- **Automation** for Music, to read and control Music or Spotify.
- **Accessibility** for Clipboard, only if you turn on pasting into the current app.
- **Camera** for Camera.

Ask needs macOS 26 with Apple Intelligence turned on.

## Build

Requires macOS 15+ and Xcode 26+.

```sh
xcodebuild -project CocoNotch.xcodeproj -scheme CocoNotch -derivedDataPath build build
open build/Build/Products/Debug/CocoNotch.app
```

Want to contribute? [CONTRIBUTING.md](CONTRIBUTING.md) covers setup, signing your builds so macOS remembers permissions, the checks to run and how pull requests work.

## License

[GPL-3.0](LICENSE)
