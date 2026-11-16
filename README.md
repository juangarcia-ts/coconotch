# CocoNotch

A modular widget hub for the MacBook notch and menu bar, focused on the workday.

Hover (or click) the notch to expand it; each widget is a tab. Open **Settings…** from the menu bar icon to change the background, how the notch opens, launch at login, and each widget's options.

## Widgets

- **Time Zones**: your local time plus any cities you add, with country flags, custom labels and a slider to scrub ahead or back.

- **Meetings**: your next meeting with a countdown and a Join button for Meet, Zoom and Teams links, plus the rest of today. Reads every calendar on your Mac (Google, Outlook, iCloud) through macOS Calendar.

Planned: Claude Code usage, now playing, clipboard history.

## Build

Requires macOS 14+ and Xcode 26+.

```sh
xcodebuild -project CocoNotch.xcodeproj -scheme CocoNotch -derivedDataPath build build
open build/Build/Products/Debug/CocoNotch.app
```

Want to contribute? [CONTRIBUTING.md](CONTRIBUTING.md) covers setup, signing your builds so macOS remembers permissions, the checks to run and how pull requests work.

## License

[GPL-3.0](LICENSE)
