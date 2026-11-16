# CocoNotch

macOS notch + menu bar widget hub. SwiftUI, Swift 6 strict concurrency, macOS 14+. GPL-3.0.

## Layout

- `CocoNotch/`: the app. Xcode syncs this folder, so new files need no project edits.
- `CocoNotch/Widgets/`: one file per widget, registered in `NotchWidget.all`. A widget's settings go in its `makeSettings` tab.
- `CocoNotch/Settings/`: the Settings window and the app-wide preference keys.
- `CocoNotchCore/`: Swift package with all logic that can be tested (parsing, formatting, calculations). No SwiftUI or AppKit.

## Rules

- Keep views thin. Any branch, parse or calculation goes in `CocoNotchCore` as a plain function, with a Swift Testing test in `CocoNotchCore/Tests`.
- No force unwraps, `try!` or implicitly unwrapped optionals (the linter enforces this).
- Reuse what exists before adding a helper; no new dependencies without asking.
- `scripts/check.sh` must pass before a task is done. It runs lint, tests and the build, with warnings as errors.

## Git

- Conventional commits (`feat:`, `fix:`, `test:`, `refactor:`, `build:`, `ci:`, `docs:`, `chore:`).
- Work on a branch and open a PR; `main` only changes through squash-merged PRs, so the PR title must be conventional too.
