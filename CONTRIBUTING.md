# Contributing to Headroom

By taking part you agree to the [code of conduct](CODE_OF_CONDUCT.md).

Thanks for taking a look. Headroom aims to stay small, honest, and cheap to
run, so changes are welcome when they keep it that way. For a larger change,
please open an issue first so we can agree on the approach.

## Project layout

```
Sources/
├── Headroom/          App layer: AppDelegate, Monitor, PanelView, NotchController, HistoryView
├── HeadroomCore/      Testable logic: memory, disk, history, agents, quotas (no AppKit UI)
├── CMemory/           C shim over kernel counters (host_statistics64, proc_pid_rusage, IOPOL)
└── CSQLite/           Module map exposing the system libsqlite3

Tests/HeadroomCoreChecks/  The tests: one Swift Testing target (scripts/check.sh)
scripts/                   Build, sign, test, screenshot, and release scripts
packaging/                 App values for the scripts, Homebrew cask template
docs/                      Screenshots and longer documentation
```

Anything testable goes in `HeadroomCore`. AppKit and SwiftUI wiring stays
in `Headroom`.

## Build

Requirements: macOS 13 or later and Swift 5.9 or later, from Xcode or the
Command Line Tools.

```sh
./scripts/build.sh    # universal release build → dist/Headroom.app
open dist/Headroom.app
```

Quit any running copy of Headroom before launching a new build.

Source builds are signed with a persistent self-signed identity,
"Headroom Local", so macOS remembers Keychain permission across rebuilds.
`scripts/sign.sh` creates it on the first build in its own keychain file
under `~/Library/Application Support/Headroom/signing/`, next to a file
holding that keychain's random password. On each build the script unlocks
that keychain, signs with `codesign --keychain`, and locks it again. It
doesn't read or change your login keychain or your keychain search list.
To build without any keychain, sign ad hoc:
`HEADROOM_SIGN_IDENTITY=- ./scripts/build.sh`. Distribution builds use
Developer ID signing instead; see [docs/releases.md](docs/releases.md).

### Command Line Tools only

On a Mac with only the Command Line Tools, the newest default SDK can fail
to build SwiftUI macros. If the build fails with macro errors, point
`SDKROOT` at an older SDK that the Command Line Tools also install:

```sh
ls /Library/Developer/CommandLineTools/SDKs/
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ./scripts/check.sh
```

Use whichever older SDK version you have.

## Test

| Command | What it runs | Needs |
| --- | --- | --- |
| `./scripts/verify.sh` | Three steps, with timings: every test (`check.sh`), a universal ad-hoc-signed build, and an offline release dry run. It does not run `test-quit.sh`. | Command Line Tools or Xcode |
| `./scripts/verify.sh --quick` | Every test (`check.sh`) and nothing else | Command Line Tools or Xcode |
| `./scripts/check.sh` | Every test: the Swift Testing suites in `Tests/HeadroomCoreChecks`, the package's only test target | Command Line Tools or Xcode |
| `./scripts/test-quit.sh` | A separate manual check. Builds a disposable fixture app, launches it, and checks Quit and Force Quit against it with a debug build of Headroom | Command Line Tools or Xcode, and a logged-in desktop session |

Run `verify.sh` before every push. There's no hosted CI, so this is the
gate, and every test runs every time: there is no Xcode-only suite and
nothing is skipped. `test-quit.sh` is not part of the gate because it
launches apps and can't run unattended; run it by hand when you change Quit
or process handling. It refuses to quit anything whose bundle ID isn't its
dedicated fixture. Keep it that way.

Helpful checks against a built app:

```sh
dist/Headroom.app/Contents/MacOS/Headroom --diagnose      # live readings to stdout
dist/Headroom.app/Contents/MacOS/Headroom --capture       # one sample + regenerate log.md
dist/Headroom.app/Contents/MacOS/Headroom --scan          # run the consumer scan in the terminal
dist/Headroom.app/Contents/MacOS/Headroom --show-panel    # open the panel at launch
dist/Headroom.app/Contents/MacOS/Headroom --show-trends   # open the Trends window at launch
```

`./scripts/screenshots.sh` rebuilds the app (signed ad hoc, so no keychain
is involved) and regenerates the README screenshots from the real views with
demo data. Add `--screenshot-variants` for review-only renders of the bare
panels, light mode, settings, and hover details.

## Invariants

These properties are what make Headroom trustworthy. Pull requests that
break them won't be merged.

1. **Never deletes user files.** No cleanup or "optimize" buttons. Sparkle
   may replace Headroom's own app bundle during an update.
2. **Never quits other apps automatically.** Quit is always user-initiated,
   and Force Quit always asks first. Sparkle may quit and relaunch Headroom
   to install an update.
3. **No folder scans unless the user asks.** Capacity comes from volume
   attributes only. A folder walk starts only from an explicit action (the
   scan button in Trends, or `--scan`), never on a timer or when a window
   opens, and is cancellable, single-threaded, and run at `IOPOL_THROTTLE`.
4. **Local by default.** No telemetry, analytics, or external AI calls.
   Network access is limited to Limits requests that reuse the user's
   existing sign-ins and to Sparkle update checks and downloads. Don't add
   dependencies beyond the pinned Sparkle.
5. **Credentials are read-only.** Never refresh, rotate, or write a
   provider's credentials, never persist tokens, and never trigger an
   interactive Keychain prompt.
6. **Optional features stay off until enabled.** Agents does no scanning
   while it's off, and Limits makes no requests while it's off.
7. **No privileged helper.** No root, and no Accessibility, Screen
   Recording, or Full Disk Access requirement.
8. **Honest readings.** Never infer memory pressure from a RAM percentage.
   Label partial or incomplete readings. Don't add consumer sizes up into
   claims about physical disk usage.
9. **Process safety.** Anything that targets a process must revalidate the
   process ID, bundle path, and launch date. Never act on a stale row.

If a change affects what Headroom reads, stores, or sends, update
[PRIVACY.md](PRIVACY.md) in the same pull request.

## Style

- Swift 5.9+, macOS 13+. Match the surrounding style: compact code, with
  comments only where the reason isn't obvious.
- Do process and file enumeration on the utility queue. Use the main thread
  for view updates only.
- Schema changes need a migration. See `History.swift` (`user_version`,
  `ALTER TABLE`) and test against a real, populated database.
- App icons are cached and `NSWorkspace.runningApplications` is read off the
  main thread. Keep it that way.
- Add tests to `Tests/HeadroomCoreChecks` (Swift Testing) for anything in
  the core target. Don't add an XCTest target: it needs full Xcode, so it
  wouldn't run on a Mac with only the Command Line Tools. Prefer fakes and
  in-memory stores over timing-dependent tests.
- Add a line under **Unreleased** in [CHANGELOG.md](CHANGELOG.md) for
  user-visible changes.

## Good first issues

- Normalize the per-sample `apps` JSON into its own table if history size
  becomes meaningful.
- Store only the top N apps per sample.
- More consumer-scan roots, such as `/opt` or `/private/var/folders`.
- Menu bar mode screenshots and checks on a Mac without a notch.

## License

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE).
