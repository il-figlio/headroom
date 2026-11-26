# Publishing Headroom

Headroom ships as a universal (Apple Silicon + Intel) app for macOS 13 or later, with Sparkle 2.10.0 embedded (pinned in Package.swift and Package.resolved). Releases and updates are public: anyone can download the DMG, and the app updates itself without a GitHub account or login.

## Where the values live

| File | Holds |
| --- | --- |
| `VERSION` | `MARKETING_VERSION` (CFBundleShortVersionString, tag `v<version>`) and `BUILD_NUMBER` (CFBundleVersion). Sparkle compares the build number, so it must increase with every published build. |
| `packaging/app.env` | App name, executable, bundle ID, minimum macOS, GitHub repo slug, feed URL, Sparkle public key and Keychain account, cask token, tap repo. |
| `Resources/Info.plist.in` | Info.plist template, rendered by `scripts/appconfig.py` during `scripts/build.sh`. |
| `Sources/HeadroomCore/UpdatePolicy.swift` | The feed URL and download allowlist compiled into the app. A Swift Testing check fails if they drift from `packaging/app.env`. |
| `packaging/homebrew/headroom.rb` | Homebrew cask template. The official `headroom` cask is a different app with the same token and the same `/Applications/Headroom.app`; Homebrew tracks installed casks by token, so the template can't declare `conflicts_with` against it (the cask would conflict with itself). |

To reuse this pipeline for another app, copy `VERSION`, `packaging/`, `Resources/Info.plist.in` and the `scripts/` release tools, then edit `packaging/app.env` and the `UpdatePolicy` constants.

## How updates reach users

- **Feed:** `SUFeedURL` is `https://raw.githubusercontent.com/il-figlio/headroom/main/appcast.xml`, the `appcast.xml` committed on `main`. Committing a new feed to `main` is what ships an update.
- **Archive:** each feed item encloses the public release asset `https://github.com/il-figlio/headroom/releases/download/v<version>/Headroom-<version>-universal.zip`. GitHub answers with a 302 redirect to a short-lived signed URL on `release-assets.githubusercontent.com` (older assets use `objects.githubusercontent.com`). Sparkle follows that redirect itself.
- **Trust:** `SURequireSignedFeed` requires the feed to carry Headroom's EdDSA signature, and Sparkle verifies the archive's EdDSA signature (`SUVerifyUpdateBeforeExtraction`) against `SUPublicEDKey` before it extracts anything. On top of that, `UpdatePolicy.allowsArchive` only accepts `https://github.com/il-figlio/headroom/releases/download/v<x.y.z>/<name>.zip`: no other host, repository, path, port, credentials, query or fragment. Sparkle has no delegate hook for redirects, so the storage host is listed in `UpdatePolicy.downloadRedirectHosts` for documentation and tests, not enforced. The signature is what makes the download safe.
- No token, cookie or Authorization header is ever sent. Remote release notes are not fetched: the notes are embedded in the signed feed.

**Why raw.githubusercontent.com and not GitHub Pages:** the installed pre-public builds have this exact URL compiled in (`SUFeedURL` and `feedURLString`). Moving the feed would strand them, as described in the transition section below. Raw files need no Pages site, deploy workflow or extra branch, and the feed is signed, so the CDN never has to be trusted. The cost is about 5 minutes of CDN caching after a push, and the feed is tied to the `main` branch name. Pages becomes worth it only with a custom domain. To switch, ship a build with the new `FEED_URL`, keep publishing to both URLs until older builds have updated, then stop updating the raw file.

## Checks before anything lands

There is no hosted CI. Before pushing to `main` or tagging, run:

```sh
./scripts/verify.sh          # all tests, universal build (ad-hoc signed), release dry run; a few minutes
./scripts/verify.sh --quick  # tests only
```

Every test runs every time. The package has one test target, `Tests/HeadroomCoreChecks` (Swift Testing), which needs only the Command Line Tools, so nothing is skipped on a Mac without Xcode. There are no retries; fix a flaky test instead of retrying it. Each step prints its wall time.

`scripts/test-quit.sh` is not part of this gate. It launches a GUI fixture app and a Headroom binary, so it can't run unattended; run it by hand when Quit or process handling changes.

## Credentials (one-time owner setup)

Everything a release needs stays on the release Mac. Nothing is stored on GitHub.

| What | Where | How |
| --- | --- | --- |
| Developer ID Application certificate and private key | login Keychain | Create it at developer.apple.com (Certificates, +, Developer ID Application) from a certificate signing request, then import it. Back up the `.p12` in a password manager. |
| Notarization credentials | login Keychain, profile `NOTARY_PROFILE` from `packaging/app.env` (`headroom-notary`) | Generate an App Store Connect API key (Users and Access, Integrations, Team Keys, Developer role), then run `xcrun notarytool store-credentials headroom-notary --key AuthKey_<KEYID>.p8 --key-id <KEYID> --issuer <ISSUER-UUID>`. Delete the `.p8` afterwards or keep it in a password manager. |
| Sparkle EdDSA private key | login Keychain, account `org.headroom.app` | Generated 2026-11-24; the public half is `SPARKLE_PUBLIC_ED_KEY` in `packaging/app.env`. Back it up with `generate_keys --account org.headroom.app -x <file>` into a password manager. Losing it means installed copies can't verify updates. Never generate another one for this release stream. |
| Signing identity name | shell | `export HEADROOM_SIGN_IDENTITY='Developer ID Application: <Name> (<TEAMID>)'` (`security find-identity -v -p codesigning`). |

## Cutting a release

```sh
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk   # Command Line Tools-only Macs
# 1. Bump VERSION and write docs/releases/v<version>.md, then:
./scripts/verify.sh
HEADROOM_SIGN_IDENTITY='Developer ID Application: <Name> (<TEAMID>)' ./scripts/build.sh
./scripts/sparkle-tools.sh
```

Notarization uses one of three paths, in this order:

- **API key:** export `HEADROOM_NOTARY_KEY=/path/AuthKey_XXXX.p8`, `HEADROOM_NOTARY_KEY_ID`, `HEADROOM_NOTARY_ISSUER`. `release.py package` notarizes and staples both the app and the DMG.
- **Keychain profile (default):** `release.py package` uses the profile named by `NOTARY_PROFILE` in `packaging/app.env`; `--notary-profile NAME` picks another.
- **Xcode account (no key needed):** `./scripts/notarize-xcode.py upload --team-id <TEAMID>`, then `export` once Apple is done, then `ditto dist/notarized/Headroom.app dist/Headroom.app`. `package` sees the stapled app. The DMG is signed but not notarized on this path, while the app inside it is stapled.

```sh
./scripts/release.py package
./scripts/release.py appcast            # signs with the Keychain key (account org.headroom.app)
./scripts/release.py verify --distribution
# 2. Commit the release (VERSION, notes, changelog) and push main, then tag that commit:
git tag -s v0.9.0 -m 'Headroom 0.9.0'   # signed annotated tag
git push origin v0.9.0
./scripts/release.py publish --verify-tag   # draft release for the pushed tag, via gh
gh release edit v0.9.0 --draft=false --latest --repo il-figlio/headroom
./scripts/release.py promote            # downloads and checks the published ZIP; then commit appcast.xml to main
./scripts/render-cask.py                # dist/releases/v0.9.0/headroom.rb for the tap
```

Outputs go to `dist/releases/v<version>/`: `Headroom-<version>-universal.zip` (Sparkle), `Headroom-<version>.dmg` (people; APFS/ULFO with an Applications link), `appcast.xml`, `SHA256SUMS`, `headroom.rb`.

**The signed tag comes first.** Publishing a draft whose tag doesn't exist makes GitHub create the tag itself, as an unsigned lightweight tag, and a later `git tag -s` then collides with it. So create and push the signed annotated tag before `publish`. `publish --verify-tag` refuses unless the tag on GitHub is an annotated tag, is the same object as the local tag, and passes `git verify-tag`; it warns if the tag isn't on `HEAD`. Without `--verify-tag`, `publish` still prepares the draft against `HEAD` for review, but when the tag is missing or isn't the signed one it ends by telling you not to publish the draft yet.

`appcast` refuses a signing key whose public half is not `SPARKLE_PUBLIC_ED_KEY`, and `publish` refuses a feed or archive signature that does not verify against that key. Every feed and archive signature is re-checked with an independent Ed25519 verifier (`scripts/ed25519.py`). The only enclosure URL any step accepts is the public release download, the one `UpdatePolicy.allowsArchive` accepts in the app.

`promote` runs after the release is public. It refuses a feed that does not verify, so a dry-run feed can never be promoted. It then downloads the published ZIP anonymously, the way a client would, and refuses unless its length and the enclosure's `sparkle:edSignature` match the downloaded file. `--no-download-check` skips the download and prints a warning; `--from-release` promotes the `appcast.xml` attached to the release instead of the local one.

### Dry run (no secrets, no network)

```sh
HEADROOM_SIGN_IDENTITY=- ./scripts/build.sh     # ad-hoc; never touches Keychain or Application Support
./scripts/sparkle-tools.sh                       # one-time download of the pinned Sparkle tools
./scripts/release.py dry-run
```

This builds the ZIP and DMG and signs an appcast and the ZIP with a throwaway EdDSA key, then runs every check. It confirms the binary is universal, and that Info.plist matches `VERSION` and `app.env` in the app, the extracted ZIP and the DMG. It mounts the DMG read-only to check for `Headroom.app` and the `Applications → /Applications` link. It confirms the feed is well-formed and both signatures verify with the right enclosure URL and length, that `SHA256SUMS` matches, and that the rendered cask passes `ruby -c`. `verify.sh` runs it.

## Transition from the private Headroom builds (0.8.0, build 13 and earlier)

Builds up to 0.8.0 came from the private repository (its full history is in `il-figlio/headroom-private`; the earlier public history is archived as `il-figlio/headroom-archive`). They poll `https://raw.githubusercontent.com/il-figlio/headroom/main/appcast.xml` with a gh token and require a feed signed with an EdDSA key that was rotated on 2026-11-24, so they can't update themselves to 0.9.0 or later.

**On each Mac running Headroom 0.8.0 or earlier, once:** quit Headroom, then install `Headroom-<version>.dmg` from https://github.com/il-figlio/headroom/releases/latest over it (a copy in `~/Applications` should be deleted). On first launch Headroom moves its own files (history, quota cache, log, and the `Archives` folder) from `~/Library/Application Support/Headroom` to `~/Library/Application Support/org.headroom.app`, but only if the `log.md` there was written by this app. A move that was interrupted is finished on the next launch, and the move is skipped while another copy of Headroom is running. An unrelated app, extraheadroom's Headroom, uses the same folder name, so its files and the development `signing/` keychain stay put. Preferences stay in the `org.headroom.app` domain. Every later update is automatic and needs no login.

## Signing notes

- `scripts/sign.sh` signs Sparkle's nested code inside-out (Downloader.xpc, Installer.xpc, Autoupdate, Updater.app, the framework), then the app.
- With a Developer ID identity it signs with hardened runtime and secure timestamps. `HEADROOM_SIGN_KEYCHAIN` selects a specific keychain. `HEADROOM_SIGN_IDENTITY=-` signs ad-hoc.
- With no identity, it keeps the persistent self-signed "Headroom Local" identity for development builds. The identity lives in its own keychain file under `~/Library/Application Support/Headroom/signing/`, which is passed to `codesign --keychain`. The script unlocks that keychain while it runs and locks it again when it exits. It doesn't read or change the keychain search list or the login keychain.
- The Sparkle key is in the publisher's login Keychain under account `org.headroom.app`. Its public half is `SPARKLE_PUBLIC_ED_KEY` in `packaging/app.env`. Back it up outside the repository.
- No private key, certificate or GitHub credential is in the app or the repository.
