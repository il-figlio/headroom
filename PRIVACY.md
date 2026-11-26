# Privacy

Headroom is a local utility. It has no account, no analytics, no crash
reporting, and no telemetry. It doesn't send your readings, app list, file
names, or history anywhere. Network access is limited to the two features
described below: **Limits**, if you turn it on, and **update checks**. One
command-line diagnostic, `--check-for-updates`, also contacts GitHub when
you run it; it is described under update checks.

This page lists everything Headroom reads, stores, and sends.

## What stays on your Mac

**Memory, apps, and disk.** Headroom reads kernel memory counters, the list
of running apps with each app's memory footprint, and your startup volume's
free, purgeable, and total space. These readings come from standard macOS
system calls and need no special permission.

**History.** While recording is on (the default), Headroom saves about one
snapshot a minute to a SQLite database in
`~/Library/Application Support/org.headroom.app/`. A snapshot contains
memory and disk figures and the names and memory footprints of running
apps. Events such as pressure changes and the results of Quit requests you
made are stored too. Samples and events older than **30 days** are deleted
automatically, both while Headroom records and each time it opens the
database, which it does at every launch even when recording is paused.
Headroom also writes a readable report, `log.md`, to the same folder and
rewrites it from the current history. You can pause recording from the
Trends window.

**Archives.** When you archive the history from the Trends window, the
database and `log.md` are moved to an `Archives` folder inside the data
folder. Headroom never deletes or prunes an archive; it stays until you
delete it.

**Disk consumer scan.** The scan runs only when you press the scan button
in the Trends window (**Scan consumers** the first time, **Rescan** after
that) or run the app's binary with `--scan`. Headroom never starts it by
itself. It measures the size of a fixed set of folders: the items in your
home folder, the items in `~/Library`, and `/Applications`. It also runs
`/usr/bin/tmutil listlocalsnapshots /` to count Time Machine local
snapshots. Each folder's path and size are stored in the history database,
where they replace the previous scan's results and stay until you scan
again or delete the database. The scan runs at the lowest disk priority and
can be cancelled. Headroom reads folder listings and file sizes; it doesn't
open or read your files' contents.

The first scan can make macOS ask whether Headroom may access folders such
as Desktop, Documents, and Downloads and, on macOS 14 or later, data from
other apps. Headroom works without any of them: if you don't allow a
folder, it isn't read and its row is labeled as a partial reading.

**Preferences.** Settings such as placement, pinned favorites, visible
widgets, and update preferences are stored in the `org.headroom.app`
preferences domain until you delete them. **Open at login** is registered
with macOS as a login item.

## Agents (off by default)

When you turn on the Agents widget, Headroom looks for coding-agent session
transcripts in the folders those tools use, such as `~/.claude`, `~/.codex`,
`~/.openclaw`, `~/.devin`, `~/.gemini`, `~/.cursor`, `~/.codeium`, and
folders under `~/.config` for Goose, opencode, Amp, and Continue.

- Transcripts are opened **read-only**. Headroom never modifies them and
  writes nothing into agent folders.
- Each new line is parsed in memory. Headroom keeps only **metadata**: the
  session ID, the project folder the agent ran in, timestamps, model names,
  token counts, and how many times each tool was used. Message text, prompts,
  code, and tool output are not stored.
- To tell which sessions are still running, Headroom reads the process list
  with `/bin/ps`, which includes each process's command line, and stops
  waiting for it after a time limit. The list is used in memory to match
  agents to their transcripts and isn't stored.
- Session metadata, the transcript file paths, and hourly token totals are
  stored in the local history database. Hourly totals older than 30 days
  are deleted, and a session's row (its project folder and transcript path
  included) is deleted 30 days after the session's last activity.

While Agents is off, none of this happens.

## Limits (off until you turn it on)

On new installs, Limits is off until you turn it on. While it is off,
Headroom reads no sign-ins, runs no command-line tools, and makes no usage
requests. It doesn't look for sign-ins either: Settings doesn't check
whether a sign-in file or Keychain item exists and doesn't list Ante
account names. Turning Limits off forgets any token held in memory and
deletes `quota-cache.json`. When Limits is on, Headroom shows your Codex
and Claude plan usage by reusing sign-ins that are already on your Mac. It
never asks for a password, never creates a sign-in of its own, and never
refreshes, rotates, writes, or copies a provider's token.

Only Codex and Claude are supported. Gemini, Cursor, Copilot, Windsurf, and
other tools are not: showing their usage would mean reading browser
cookies, asking you to sign in again, or refreshing and writing tokens,
which Headroom doesn't do.

| Provider | What Headroom reads | Where it connects |
| --- | --- | --- |
| Codex (ChatGPT plan) | `~/.codex/auth.json`, written by the Codex CLI, opened read-only: the access token and account ID | `https://chatgpt.com/backend-api/wham/usage` |
| Claude (Claude Code sign-in, file) | `~/.claude/.credentials.json`, if it exists: the access token, its expiry, and the plan name | `https://api.anthropic.com/api/oauth/usage` |
| Claude (Claude Code sign-in, Keychain) | If that file doesn't exist, the `Claude Code-credentials` item in your login Keychain. Headroom checks that the item exists and when it last changed without reading its contents, and reads the token only to make the usage request. It never shows a Keychain prompt. Turn this off with **Use Claude Code's Keychain sign-in** in Settings → Limits (on by default) | `https://api.anthropic.com/api/oauth/usage` |
| Claude (Ante single sign-in) | `~/.ante/auth/credentials/oauth/anthropic.json`, Ante's original single-file sign-in, if it exists | `https://api.anthropic.com/api/oauth/usage` |
| Claude accounts in Ante (for example Personal and Work) | Requires the Ante CLI at `~/.ante/bin/ante`. Headroom lists only the **file names** in `~/.ante/auth/credentials/oauth/anthropic/`, which are the account names. The files themselves aren't opened | No direct connection. Headroom runs `~/.ante/bin/ante usage anthropic/<account> --json`, stops it after 20 seconds, and Ante fetches the usage itself |

Details:

- Each request sends only your sign-in token (and, for Codex, your account
  ID) to the provider that issued it, to ask for your own usage. Nothing
  about your Mac or your other readings is included.
- Both the Codex and the Claude requests identify themselves as `Headroom`.
- Usage requests don't follow redirects, so a token is sent only to the
  address in the table.
- The Keychain is never read in a way that can prompt you: if macOS would
  need to ask for permission, the read fails and Limits shows that Claude
  usage is unavailable. With **Use Claude Code's Keychain sign-in** turned
  off, Headroom doesn't touch the Keychain at all.
- When a sign-in changes (for example, after Claude Code renews it or you
  sign in to a different account), Headroom notices from the file's or
  Keychain item's modification time, without reading the secret to check.
  It notices on the next poll even if the previous token still works, so
  Limits then shows the new account.
- While any named Ante account exists, Headroom shows those accounts and
  doesn't show Claude Code's own sign-in as a separate row. Settings →
  Limits says when this is the case.
- Tokens are held in memory only. They are never written to disk, logged,
  or cached by the network layer. Ante and the providers' own CLIs may
  renew their own sign-ins; Headroom never does.
- The latest readings (plan name, usage percentages, reset times, account
  names, and credit balance) are saved to `quota-cache.json` in Headroom's
  data folder so they show instantly after relaunch. No tokens are saved.
  The file is deleted when you turn Limits off.
- Polling happens about every 15 minutes and when you open the panel, and
  stops while a provider asks Headroom to back off (rate limits are
  honored).
- If no sign-in exists, Headroom makes no Limits requests.

**These endpoints are unofficial.** They are the private, undocumented
endpoints the providers' own apps use, not public APIs. They can change or
stop working at any time without notice, and using them is subject to each
provider's terms. If one changes, Limits shows an error for that provider;
nothing else is affected.

## Update checks

Headroom uses [Sparkle](https://sparkle-project.org) for updates. By
default it checks once a day. You can turn off automatic checks and
automatic installation in Headroom's settings, and still check manually.

- An update check downloads Headroom's update feed (`appcast.xml`) from
  GitHub. If a newer version is listed, Headroom downloads the update
  archive from the project's GitHub Releases.
- These are ordinary HTTPS requests. GitHub can see your IP address and a
  user agent that names Headroom and its version, as with any download.
- Sparkle's optional system profile is disabled, so no hardware, macOS
  version, or usage details are sent.
- The feed and the update archive are both signed. Headroom refuses an
  update whose signature doesn't match the key built into the app, and
  checks the signature before unpacking.
- Release notes are embedded in the signed feed; Headroom doesn't load them
  from another site.
- Running the app's binary with `--check-for-updates` is a diagnostic: it
  asks GitHub's public releases API
  (`https://api.github.com/repos/il-figlio/headroom/releases`) for this
  project's release list, anonymously, prints the newest stable release
  tag, and exits. Nothing else in Headroom uses that address, and Headroom
  never runs the diagnostic by itself.

## Permissions

Headroom needs no Accessibility, Screen Recording, Full Disk Access, or
administrator permission. It doesn't install a helper and doesn't run as
root.

The only permission requests Headroom can cause come from the disk consumer
scan, and only after you start it: macOS may ask about folders such as
Desktop, Documents, and Downloads and, on macOS 14 or later, about other
apps' data. You can decline every one of them. Headroom keeps working and
labels the folders it couldn't read as partial.

## Removing your data

Quit Headroom, then delete `~/Library/Application Support/org.headroom.app/` and run
`defaults delete org.headroom.app`. See
[Uninstall](README.md#uninstall) for the full steps.

## Questions

Open an issue on GitHub. To report a security problem, follow
[SECURITY.md](SECURITY.md).
