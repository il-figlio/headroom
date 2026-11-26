# Public release checklist

A repeatable checklist for taking a private macOS app repository public with
downloadable, self-updating releases. Each section lists the generic steps,
then **Headroom** shows how this repository answers them, as a worked
example. Copy this file into the next app and replace the Headroom answers.

Work through the sections in order. The visibility flip comes last and is
the only step that can't be undone.

## 1. Repository hygiene

- [ ] Internal notes (work logs, progress files, verification records,
      agent transcripts, investigation narratives) live in an ignored
      `.internal/` folder, not in the tracked tree.
- [ ] `.gitignore` covers build output, local databases, signing material,
      `.env` files, and `.internal/`. The root-level names of internal notes
      are ignored too, so a regenerated copy can't be committed.
- [ ] Every image and asset in the tree is referenced by the README, docs,
      scripts, or sources. Remove concept art and superseded screenshots.
- [ ] Screenshots use demo data, not a live machine: no real app lists,
      account usage, file paths, or other windows in the background.
- [ ] No personal absolute paths, machine names, signing team IDs, or
      internal thread or tool names in tracked files.
- [ ] A license file is present and the README states it. Third-party
      licenses ship with the app.
- [ ] Only branches meant to be public exist on the remote. Delete or
      archive work-in-progress branches; a visibility flip publishes every
      branch and tag.

**Headroom:** `log.md`, `PROGRESS.md`, `DEVLOG.md`, and `verification*.json`
moved to `.internal/`. Live-machine screenshots and icon concepts were
removed; the README screenshots come from `--screenshots`, which renders the
real views with labeled demo data. MIT license; Sparkle's license ships in
the app bundle. The public repository has one branch, `main`.

## 2. Documentation set

- [ ] `README.md` for users: one-paragraph description, screenshot,
      Download (Releases link, Homebrew line), Requirements, What it does,
      Privacy summary, Updates, Uninstall (app, data folder, preferences
      domain, anything a source build creates), Build from source, License.
- [ ] Deep technical behavior lives in `docs/` and is linked from the
      README, not inlined.
- [ ] `CHANGELOG.md` in [Keep a Changelog](https://keepachangelog.com/)
      form, with an **Unreleased** section.
- [ ] `PRIVACY.md`: what is read, stored, sent, and to whom (section 3).
- [ ] `SECURITY.md`: private reporting channel and supported versions.
- [ ] `CONTRIBUTING.md`: build, test, the project's invariants, style.
- [ ] `.github/ISSUE_TEMPLATE/` (bug report, feature request, a `config.yml`
      that routes security reports privately) and
      `.github/pull_request_template.md` with the invariants checklist.
- [ ] Every relative Markdown link resolves (see the check below).

**Headroom:** [README](../README.md), [how it works](how-it-works.md),
[CHANGELOG](../CHANGELOG.md), [PRIVACY](../PRIVACY.md),
[SECURITY](../SECURITY.md), [CONTRIBUTING](../CONTRIBUTING.md). The bug
template asks for the Headroom and macOS versions, Mac model and chip, and
notch or menu bar placement.

Link check (run from the repository root):

```sh
python3 - <<'EOF'
import pathlib, re, subprocess, sys
bad = 0
files = subprocess.run(["git", "ls-files", "*.md"], capture_output=True, text=True).stdout.split()
for name in files:
    md = pathlib.Path(name)
    text = re.sub(r"```.*?```", "", md.read_text(), flags=re.S)
    for link in re.findall(r'\]\(([^)\s]+)\)|src="([^"]+)"', text):
        target = (link[0] or link[1]).split("#")[0]
        if not target or re.match(r"[a-z]+:", target):
            continue
        if not (md.parent / target).exists():
            print(f"{md}: missing {target}"); bad += 1
sys.exit(1 if bad else 0)
EOF
```

## 3. Privacy review

Read the code, not the old docs. For each item, record the answer in
`PRIVACY.md`.

- [ ] Every file and folder the app reads outside its own container, and
      whether it only reads.
- [ ] Every Keychain item it reads or writes, and whether it can prompt.
- [ ] Every network destination, what each request contains, and when it
      happens. Mark unofficial or undocumented endpoints as such.
- [ ] Every external process it runs (`ps`, CLIs) and with what arguments.
- [ ] What is stored locally, where, and for how long.
- [ ] Telemetry, analytics, and crash reporting: none, or exactly what.
- [ ] Optional features that touch personal data are off by default, and
      "off" means no reads and no requests.
- [ ] The update check: what it sends, and that any system profile is off.

**Headroom:** no telemetry. History is local SQLite in
`~/Library/Application Support/org.headroom.app/`, with samples and events
older than 30 days deleted. The disk consumer scan runs only when asked,
and runs `tmutil` to count local snapshots. Agents is off by default; when
on, it reads transcripts read-only, keeps only metadata, and lists
processes with `/bin/ps`. Limits is opt-in on new installs; it reads
existing Codex, Claude Code, and Ante sign-ins (including Claude Code's
Keychain item, read without prompts and switchable off), calls the
providers' unofficial usage endpoints, or runs `ante usage`. Sparkle checks
daily with its system profile disabled, and a command-line diagnostic can
ask GitHub's public releases API for the newest release.

## 4. History scan

Flipping visibility publishes every commit on every branch, not only the
current tree. Scan before deciding how to publish.

- [ ] List every remote branch and tag (`gh api repos/OWNER/REPO/branches`,
      `.../tags`), not only the local ones.
- [ ] Scan full history: `git log -p --all > history.patch`, then search it
      for private keys (`-----BEGIN`), token prefixes (`sk-`, `ghp_`,
      `gho_`, `github_pat_`, `xox`, `AKIA`), JWTs (`eyJ`), `accessToken`,
      `refresh_token`, passwords, `.p12`, `.p8`, `.pem`, `.keychain` files,
      email addresses, `/Users/` paths, team IDs, host names (`.local`,
      `.ts.net`, private IP ranges).
- [ ] Look at every image ever committed, not only current ones:
      `git log --all --format=%h --name-only -- '*.png'`, then
      `git show <commit>:<path>`.
- [ ] List large blobs: `git rev-list --objects --all | git cat-file
      --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)'`.
- [ ] Classify each finding: **real secret** (rotate it now, then publish
      fresh history), **mildly sensitive** (decide), or **benign**.
- [ ] Decide: flip as-is, or publish a fresh history.

Flip as-is only when the scan is clean and the history reads well in public.
Otherwise publish a fresh history: keep the private repository as the
archive (rename it), create the public repository under the final name, and
push a single squashed initial commit from the cleaned tree, authored with
a GitHub `noreply` address. Force-pushing an orphan branch in place is the
fallback; GitHub can keep old commits reachable by SHA until its caches are
purged, so a new repository is cleaner.

**Headroom:** the scan found no real secrets, and the decision was to
publish a fresh history: the public repository starts from a new initial
commit of the cleaned tree, and the earlier history is kept in a separate
private archive.

## 5. Versioning from a single source

- [ ] The marketing version and build number are defined in exactly one
      place, and the build, release script, appcast, and tag all read it.
- [ ] The build number only increases. Never reuse one.
- [ ] Tags are `vX.Y.Z` and match the marketing version.
- [ ] The changelog's **Unreleased** section becomes the release notes.

**Headroom:** the marketing version and build number live in `VERSION`.
`scripts/build.sh`, `scripts/release.py`, the appcast, the cask, and the
`v<version>` tag all read it.

## 6. Signed and notarized artifacts

- [ ] Developer ID Application certificate, with its private key backed up
      outside the repository.
- [ ] Hardened runtime and secure timestamps; nested frameworks and helpers
      signed inside out.
- [ ] Notarized and stapled; `spctl --assess` accepts the app.
- [ ] Universal binary (Apple Silicon and Intel) if the app supports both.
- [ ] Downloadable archive plus a SHA-256 checksum file.
- [ ] Local builds use a separate identity and are clearly not for
      distribution.

**Headroom:** universal, Developer ID signed with hardened runtime, and
notarized. The download is a DMG; a ZIP of the same app is the update
archive. Source builds sign with a self-signed "Headroom Local" identity
kept in its own keychain file. See [releases.md](releases.md).

## 7. Public update feed

- [ ] The feed URL needs no authentication and is pinned in the app.
- [ ] The feed and archives are signed (Sparkle EdDSA). The private key is
      backed up and never in the repository; the public key is in the app.
- [ ] The app requires a signed feed and verifies archives before
      extracting them.
- [ ] Release notes are embedded in the signed feed, not fetched remotely.
- [ ] Sparkle's system profile is off.
- [ ] Users can turn off automatic checks and automatic installation.
- [ ] Existing installs on the old (private) feed have a path to the new one.

**Headroom:** Sparkle 2, pinned. Signed feed required, archive verification
before extraction, system profile off, remote release notes off. Builds up
to 0.8.0 read a private feed through the GitHub CLI login and can't update
themselves; installing the first public DMG once moves them to the
unauthenticated public feed.

## 8. Local verification and release (no hosted CI)

No GitHub Actions and no other hosted CI. A hosted run spends minutes on
queueing and setup before it checks anything, and signing a macOS app there
would mean storing private keys on GitHub. The app is verified and released
on the release Mac instead.

- [ ] One script runs every automated check: `scripts/verify.sh` (all
      tests, universal build, release dry run), printing each step's wall
      time. No skips, no retries; fix flaky tests instead. The tests must
      run with the tools the release Mac has.
- [ ] Checks that need a logged-in GUI session are listed separately as
      manual checks, not silently left out of the script.
- [ ] Run it before every push to `main` and before every tag.
- [ ] Actions disabled in the repository settings, and no `.github/workflows/`.
- [ ] Signing material stays in the release Mac's login Keychain (Developer ID
      certificate, notarytool profile, Sparkle key), backed up in a password
      manager. Nothing is stored as a GitHub secret.
- [ ] The release script refuses to overwrite a published release, and the
      appcast is committed only after the release assets exist and the
      published archive has been downloaded and checked against it.
- [ ] The release tag is a signed annotated tag, pushed before the release
      is created, so the host never creates an unsigned tag for it.

**Headroom:** `./scripts/verify.sh` runs the one Swift Testing target, a
universal ad-hoc build, and an offline release dry run in a few minutes,
most of it the build, with only the Command Line Tools installed.
`scripts/test-quit.sh` is the manual check: it launches a fixture app and a
Headroom binary. Releases: [releases.md](releases.md).

## 9. Homebrew cask

- [ ] A tap repository (`OWNER/homebrew-tap`) with `Casks/APP.rb`.
- [ ] The cask points at the versioned release archive with its SHA-256,
      declares the minimum macOS version, and uses `auto_updates true` when
      the app updates itself.
- [ ] A `zap` stanza lists the app's data folder and preferences.
- [ ] If another cask installs an app at the same path, the cask declares
      it with `conflicts_with`.
- [ ] A documented release step bumps the cask (`scripts/render-cask.py`).
- [ ] Mark the README's Homebrew line "coming soon" until the tap works.

**Headroom:** `brew install --cask il-figlio/tap/headroom`, marked coming
soon in the README. The `zap` stanza removes
`~/Library/Application Support/org.headroom.app` and the `org.headroom.app`
preferences, caches, and saved state. The official `headroom` cask is a
different app that also installs `/Applications/Headroom.app`, so the cask
declares `conflicts_with cask: "headroom"`.

## 10. Clean-machine QA

Test on a Mac (or a fresh macOS user account) that has never run the app or
its development builds.

- [ ] Download from the Releases page in a browser, open the disk image,
      drag the app to Applications, and open it: Gatekeeper accepts it
      without warnings.
- [ ] First launch: onboarding appears, optional features are off, and no
      Keychain, network, or permission prompts appear unexpectedly.
- [ ] Every main feature works with no developer tools installed.
- [ ] An update from the previous public release installs and relaunches.
- [ ] Uninstall steps in the README remove everything.
- [ ] Intel and Apple Silicon, and the oldest supported macOS, if possible.

**Headroom:** check both notch and menu bar placement, Agents and Limits
off on first launch, Limits off means no requests, and an update from the
first public build to the next.

## 11. Flip visibility

- [ ] Sections 1 to 10 are done, and the history decision in section 4 has
      been carried out.
- [ ] Repository settings: private vulnerability reporting on, issues on,
      wiki and projects off unless used, description, website, and topics
      set, default branch protected.
- [ ] Leftover draft releases are deleted or published deliberately.
- [ ] Flip to public (or push the fresh public repository).
- [ ] From a signed-out browser: README images load, the Releases link
      works, the feed URL returns the signed appcast, and the Security tab
      offers private reporting.
- [ ] Announce only after the signed-out checks pass.

**Headroom:** the public repository was created with a fresh history, so
it has no releases from the private builds. Its only draft is the first
public release, which is published once the checks above pass.
