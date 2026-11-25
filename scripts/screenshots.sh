#!/bin/zsh
# Rebuild the app and regenerate the README images (docs/scene-laptop.png,
# docs/scene-desktop.png, docs/trends-v2.png) from the real views with demo
# data. Signs ad hoc unless HEADBOARD_SIGN_IDENTITY says otherwise, so it never
# touches a keychain or prompts. The animated tours come from scripts/tour-gifs.sh.
#
#   ./scripts/screenshots.sh [folder] [--screenshot-variants] [--screenshot-scale 2]
set -eu
cd "${0:A:h:h}"
HEADBOARD_SIGN_IDENTITY="${HEADBOARD_SIGN_IDENTITY:--}" "${0:A:h}/build.sh"
folder="$PWD/docs"
if [[ $# -gt 0 && "$1" != --* ]]; then folder="$1"; shift; fi
dist/Headboard.app/Contents/MacOS/Headboard --screenshots "$folder" "$@"
