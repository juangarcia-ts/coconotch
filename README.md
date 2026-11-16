# CocoNotch

A modular widget hub for the MacBook notch and menu bar, focused on the workday.

Hover the notch to expand it; each widget is a tab. Widget settings live in the menu bar icon.

## Widgets

- **Time Zones**: your local time plus any cities you add, with a slider to scrub ahead or back.

Planned: meetings, Claude Code usage, now playing, clipboard history.

## Build

Requires Xcode 16 or later and macOS 14+.

```sh
xcodebuild -project CocoNotch.xcodeproj -scheme CocoNotch -derivedDataPath build build
open build/Build/Products/Debug/CocoNotch.app
```

Before opening a PR, run `scripts/check.sh` (lint, tests, build with warnings as errors). CI runs the same script.

## Adding a widget

1. Create `CocoNotch/Widgets/YourWidget.swift` with a `static let` on `NotchWidget` (see `Timezones.swift`).
2. Add it to `NotchWidget.all`.

## License

[GPL-3.0](LICENSE)
