# Third-party notices

## Included software

### Sparkle

Headboard embeds [Sparkle](https://sparkle-project.org) 2.10.0
(<https://github.com/sparkle-project/Sparkle>) to install signed updates.
Sparkle is released under the MIT License, copyright Andy Matuschak and the
other Sparkle contributors. It also includes code from bsdiff, sais-lite,
ed25519, and SUSignatureVerifier under their own permissive licenses.

The full text of all of these licenses is in
[Resources/Sparkle-LICENSE](Resources/Sparkle-LICENSE), which is also
copied into `Headboard.app/Contents/Resources/`.

## Acknowledgements

### CodexBar

[CodexBar](https://github.com/steipete/CodexBar) (MIT, © 2026 Peter
Steinberger) documents how the Codex and Claude usage endpoints behave,
including Claude's per-model weekly windows and detecting Claude Code
Keychain sign-in changes. Some of Headboard's Limits behavior follows that
documentation. Headboard re-implements it independently and includes no
CodexBar code, so no CodexBar license text is reproduced here.
