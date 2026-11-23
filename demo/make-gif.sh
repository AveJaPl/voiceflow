#!/usr/bin/env bash
# Silent README GIF from the rendered MP4 (two-pass palette keeps the dark UI clean).
set -euo pipefail
cd "$(dirname "$0")"
src=out/demo.mp4
dst=../docs/assets/demo.gif
filters="fps=15,scale=960:-1:flags=lanczos"
ffmpeg -v error -y -i "$src" -vf "$filters,palettegen=max_colors=192:stats_mode=diff" out/palette.png
ffmpeg -v error -y -i "$src" -i out/palette.png \
  -lavfi "$filters [x]; [x][1:v] paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" "$dst"
cp "$src" ../docs/assets/demo.mp4
ls -lh "$dst" ../docs/assets/demo.mp4
