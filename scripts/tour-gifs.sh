#!/bin/zsh
# Rebuild the README's animated tours (docs/panel-tour.gif, docs/settings-tour.gif)
# from the real views with demo data, like scripts/screenshots.sh. Signs ad hoc
# unless HEADBOARD_SIGN_IDENTITY says otherwise, so it never touches a keychain.
# Needs ffmpeg (brew install ffmpeg); nothing else in the build does.
#
#   ./scripts/tour-gifs.sh
set -eu
cd "${0:A:h:h}"
command -v ffmpeg >/dev/null || { echo "tour-gifs.sh needs ffmpeg (brew install ffmpeg)" >&2; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
HEADBOARD_SIGN_IDENTITY="${HEADBOARD_SIGN_IDENTITY:--}" ./scripts/build.sh >/dev/null
dist/Headboard.app/Contents/MacOS/Headboard --screenshots "$work/renders" --screenshot-variants >/dev/null

# gif <output> <seconds per frame> <render name>...
# Centers every render on one canvas (largest render plus 24 px each side) in
# the renders' own background color, so frames don't jump or show a seam.
gif() {
  local out="$1" seconds="$2"; shift 2
  local frames="$work/frames-${out:t:r}" w=0 h=0 i=0 name
  local -a size
  mkdir -p "$frames"
  for name in "$@"; do
    size=($(sips -g pixelWidth -g pixelHeight "$work/renders/$name.png" | awk '/pixel/ { print $2 }'))
    (( size[1] > w )) && w=$size[1]; (( size[2] > h )) && h=$size[2]
  done
  (( w += 48, h += 48 ))
  for name in "$@"; do
    (( i += 1 ))
    ffmpeg -y -loglevel error -i "$work/renders/$name.png" \
      -vf "pad=$w:$h:(ow-iw)/2:(oh-ih)/2:color=0x16171A" "$frames/$(printf %02d $i).png"
  done
  # One palette for all frames and no dithering keeps UI text and edges crisp.
  # passthrough keeps one GIF frame per render instead of padding to 25 fps.
  ffmpeg -y -loglevel error -framerate "1/$seconds" -i "$frames/%02d.png" \
    -vf "split[a][b];[a]palettegen=stats_mode=full[p];[b][p]paletteuse=dither=none" \
    -fps_mode passthrough -loop 0 "$out"
  echo "Wrote $out (${w}x${h}, $(( $(stat -f%z "$out") / 1024 )) KB)"
}

gif docs/panel-tour.gif 3 menubar-panel-v1 menubar-panel-limits-expanded menubar-panel-agents hover-details-dark
gif docs/settings-tour.gif 2.5 settings-general-dark settings-limits-on-dark settings-history-dark
