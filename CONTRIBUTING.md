# Contributing to CocoNotch

Thanks for helping. This page covers setting up your Mac, the checks every change has to pass, and how pull requests work.

## Set up

You need macOS 15 or later and Xcode 26 or later.

```sh
git clone https://github.com/juangarcia-ts/coconotch.git
cd coconotch
xcodebuild -project CocoNotch.xcodeproj -scheme CocoNotch -derivedDataPath build build
open build/Build/Products/Debug/CocoNotch.app
```

### Sign your builds (recommended)

Without a certificate, builds are signed "ad hoc". That works, but the signature changes on every build, and macOS forgets privacy permissions such as Calendar access each time. To grant them once and keep them, sign with a free Apple Development certificate:

1. Open **Xcode → Settings → Accounts**, click **+** and add your Apple ID. A free Apple ID is enough.
2. Select your account, click **Manage Certificates…**, then **+ → Apple Development**.
3. Find your team ID, the 10-character code in parentheses:

   ```sh
   security find-identity -v -p codesigning
   ```

4. Create your local signing file and put your team ID in it:

   ```sh
   cp Local.xcconfig.example Local.xcconfig
   ```

`Local.xcconfig` is gitignored, so your team ID stays on your Mac. Rebuild, grant the permissions once, and they stay granted.

## Before you open a pull request

Run the same checks CI runs:

```sh
scripts/check.sh
```

It lints with `swift format`, runs the tests in `CocoNotchCore`, and builds the app with warnings treated as errors.

## How the code is organized

- `CocoNotch/`: the app. Xcode syncs this folder, so new files need no project changes.
- `CocoNotch/Widgets/`: one file per widget.
- `CocoNotchCore/`: a Swift package for logic that can be tested, such as parsing, formatting and calculations. It has no SwiftUI or AppKit code.

Keep views thin: any branch, parse or calculation goes in `CocoNotchCore` as a plain function, with a test in `CocoNotchCore/Tests`.

### Adding a widget

1. Create `CocoNotch/Widgets/YourWidget.swift` with a `static let` on `NotchWidget` (see `Timezones.swift`), including a `makeSettings` tab if it has options.
2. Add it to `NotchWidget.all`. It shows up in **Settings → Widgets**, where people can reorder it or turn it off.

## Pull requests

- Use [Conventional Commits](https://www.conventionalcommits.org) for the PR title, for example `feat: add clipboard widget` or `fix: keep the notch on the main display`. PRs are squash-merged, so the title becomes the commit on `main`, and CI checks it.
- Claude reviews every pull request against the rules in `CLAUDE.md` and ends with a verdict. Address its findings or reply explaining why not.

## Releasing

Push a `vX.Y.Z` tag on `main`. The Release workflow signs CocoNotch with the Developer ID certificate, notarizes it, publishes the zip and the Sparkle appcast as a GitHub Release, and updates the cask in [homebrew-tap](https://github.com/juangarcia-ts/homebrew-tap). It needs these repository secrets: `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`, `APPLE_TEAM_ID`, `APPLE_ID`, `APPLE_APP_PASSWORD`, `SPARKLE_PRIVATE_KEY` and `TAP_TOKEN`.

By contributing, you agree that your work is licensed under [GPL-3.0](LICENSE).
