# Changelog

All notable changes to Headroom are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Headroom uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Versions before
the first public release were private builds and were never published for
download.

## [Unreleased]

### Added
- A short welcome on first launch explaining what Headroom measures, where
  it lives, and the optional features, plus a Settings window (⌘,) and an
  About panel.
- Public updates: Headroom checks a public, signed update feed and no longer
  needs a GitHub login. The download is a notarized DMG, and later updates
  install in place.
- Hover details across the panel: rest on any row, meter, or tile to see
  exactly what it measures.
- Named Claude accounts from Ante: each signed-in account gets its own row
  in Limits, read through the `ante usage` command. Named accounts need the
  Ante CLI at `~/.ante/bin/ante`; while any exist, they replace the Claude
  Code row.
- Claude Code users whose sign-in lives in the login Keychain now see their
  Claude limits. Headroom never shows a Keychain prompt, and **Use Claude
  Code's Keychain sign-in** in Settings → Limits turns Keychain use off.
- Claude's model-specific weekly windows (for example Sonnet or Opus) appear
  alongside the 5-hour and weekly windows when Anthropic reports them.
- When a sign-in changes, Limits notices on its next poll without reading
  the secret to check, even if the previous token still works, so switching
  accounts shows the new account.
- Codex sessions stored in dated folders are now picked up by Agents.

### Changed
- History, the quota cache and the observation log now live in
  `~/Library/Application Support/org.headroom.app`. An unrelated app also
  called Headroom (the `headroom` Homebrew cask) uses
  `~/Library/Application Support/Headroom`, and uninstalling it with `--zap`
  deletes that folder. On first launch Headroom moves its own files out of
  it, the `Archives` folder included, but only when the log there was
  written by this app. An interrupted move is finished on the next launch,
  and the move is skipped while another copy of Headroom is running.
- The disk consumer scan starts only when you press its button in Trends.
  It no longer starts by itself when you open Trends with results more than
  a day old. The first scan can make macOS ask for access to folders such
  as Desktop, Documents, and Downloads; Headroom works without them and
  labels those folders as partial.
- The fill rate and the days-until-full estimate appear once disk readings
  span at least six hours, and are fitted across all of the window's
  samples, so one large download no longer reads as a daily rate.
- The Agents card's tokens and estimated spend for today count only usage
  from the current local day, not the lifetime total of every session that
  was active today.
- The Claude usage request identifies itself as `Headroom`, like the Codex
  request, instead of as the Claude Code CLI, so Headroom no longer runs
  `claude --version`.
- Sizes pick their unit from their size everywhere: under 1 GB in MB, 1 TB or
  more in TB, daily disk rates included ("205 MB/day"), and the Trends charts
  label their axis in the unit that fits the largest value.
- Disks of 1 TB or more show sizes in TB (for example "1.26 TB free of
  2.00 TB") in the panel, menu bar, Trends, and log.md.
- Limits is opt-in on new installs. While it's off, Headroom reads no
  sign-ins, runs no provider CLI, and makes no usage requests. Existing
  installs keep their current setting.
- With Limits off, Settings no longer looks for sign-ins at all: it doesn't
  check whether one exists and doesn't list Ante account names. Turning
  Limits off also forgets any token held in memory and deletes
  `quota-cache.json`.
- Limits usage requests don't follow redirects.
- New app icon: a white gauge on a black tile with its needle near the low
  end.
- Limits is clearer: the most constrained window is shown first, values are
  labeled "% used", and a reading that couldn't be refreshed is dimmed and
  labeled with when it was fetched.
- Agents is off by default. Turn it on from the panel's widget menu. While
  it's off, Headroom does no agent scanning.
- The Agents card is built around what's running now: project, agent, and
  the live memory of each agent's processes, then today's tokens and
  estimated spend.
- Agents reads the process list with `/bin/ps` and stops waiting for it
  after a time limit.
- Limits never refreshes, writes, or copies provider credentials and never
  asks for Keychain permission. When a sign-in expires, the provider's own
  app or CLI renews it.
- Faster and lighter: memory and disk readings appear before slower history
  and agent work, quiet agent rescans and history writes are several times
  faster, and the `log.md` report is rewritten at most every 15 minutes (or
  when you open it) instead of every minute.

### Removed
- Headroom no longer reads the early prototype's `org.memoryline.app`
  preferences.

### Fixed
- Token counts from agent transcripts are accurate when a line is still
  being written, a read fails, or the file grows during a read. Previously
  such lines could be skipped or counted twice.
- A replaced or restored transcript is no longer counted twice.
- Codex token totals no longer count cached input and reasoning output
  twice.
- A Claude Code message that appears on several transcript lines, or is
  copied into a resumed session's transcript, is counted once.
- Opus 4 and 4.1 usage is shown as unpriced instead of being priced at
  the Opus 4.5 rate.
- Samples, events, hourly agent totals, and agent session rows older than
  30 days are pruned whenever the database is opened, not only while
  recording.
- Stored agent session metadata (project folder and transcript path) is
  deleted 30 days after the session's last activity.
- A Codex usage response with an unexpected field loses only that field or
  window instead of the whole reading, and a response that can't be decoded
  is reported as an unexpected response rather than a network error.
- A failed Ante usage read no longer blanks the account, a hung Ante process
  is stopped after its timeout, and the last good reading survives a failed
  fetch at launch.

## [0.8.0] - 2026-10-15

### Added
- In-app updates with [Sparkle](https://sparkle-project.org): check,
  download, verify, install, and relaunch. Automatic checks and automatic
  installation can each be turned off.
- Universal app for Apple Silicon and Intel, Developer ID signed and
  notarized by Apple.

## [0.7.2] - 2026-10-15

### Added
- The app icon now appears in the menu bar, the collapsed notch, and the
  panel header; the installed version is shown under the panel title.
- **Check for Updates** command.

## [0.7.1] - 2026-10-15

### Added
- First app icon.
- Repository screenshots rendered from the real app views with clearly
  labeled demo data.

## [0.7.0] - 2026-10-14

### Added
- **Limits** card: your Codex and Claude plan usage windows, credit
  balance, plan name, and reset times, read with your existing sign-ins.
  Polled about every 15 minutes, with rate limits respected and the last
  good reading kept on failure.

### Fixed
- Limits rows no longer truncate; the collapsed notch title no longer clips.

## [0.6.1] - 2026-10-14

### Changed
- Gauges replaced by compact bars with a highlighted warning zone. Memory
  and Disk sit side by side.
- The Agents card shows an honest idle state instead of "0 active".

## [0.6.0] - 2026-10-14

### Added
- Customizable panel: show or hide any card from **··· → Widgets** or by
  right-clicking it. The app list always keeps a minimum height.

## [0.5.0] - 2026-10-14

### Added
- Sparklines for memory and disk, an hourly token chart on the Agents card,
  and a proportional memory bar on each app row.

## [0.4.0] - 2026-10-14

### Added
- **Agents**: tracks coding-agent sessions (Claude Code, Codex, OpenClaw,
  and a generic reader for other JSONL transcripts) with tokens, estimated
  cost, and live/stuck/ended health.
- **Favorites dock**: pin apps for one-click switching or launching.

## [0.3.0] - 2026-10-14

### Added
- Disk tracking: free, purgeable, and total space, a 24-hour chart, fill rate,
  and an estimate of days until full.
- On-demand, throttled scan of the largest disk consumers, with Reveal in
  Finder and Copy Path. Headroom never deletes anything.
- History stops writing when less than about 512 MB is free.

### Fixed
- History recording no longer uses a stale memory-pressure reading.

## [0.2.0] - 2026-10-14

### Added
- Local history (30 days), a Trends window with 24-hour charts and
  rules-based recommendations, recording controls, and archiving.
- A generated `log.md` report of daily readings and recent actions.

## [0.1.0] - 2026-10-14

First prototype.

### Added
- Memory pressure in the notch on laptops and the menu bar on other Macs.
- Per-app memory with helper processes grouped under their app.
- Guarded **Quit** and confirmed **Force Quit**.
