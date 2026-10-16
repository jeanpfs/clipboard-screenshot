#!/usr/bin/env bash
# Builds demo.gif from a screen recording (raw.mkv) of the real macOS flow: Cmd+Shift+4, drag over a region, paste.
# The recording is cropped to a Preview window (source) next to a TextEdit window (paste target).
# Run in a directory holding raw.mkv. Needs ffmpeg, gifsicle and ImageMagick.
set -euo pipefail

FONT="${FONT:-/System/Library/Fonts/SFNS.ttf}"
A_FROM=3.0; A_TO=8.2     # caption 1 visible (screenshot being taken)
B_FROM=9.0               # caption 2 visible (paste)
pill() {  # pill <out.png> <text>
  magick -size 960x420 xc:none -font "$FONT" -pointsize 22 -gravity south \
    -fill 'rgba(24,24,37,0.88)' -stroke '#45475a' -strokewidth 1 -draw "roundrectangle 180,356 780,402 23,23" \
    -stroke none -fill '#cdd6f4' -annotate +0+22 "$2" "$1"
}
pill cap1.png "⌘⇧4   saves a screenshot, as always"
pill cap2.png "⌘V   and the image is already on your clipboard"

ffmpeg -v error -y -i raw.mkv -loop 1 -i cap1.png -loop 1 -i cap2.png -filter_complex "
[0:v]scale=960:-2:flags=lanczos,fps=30[v];
[1:v]format=rgba[c1];[2:v]format=rgba[c2];
[v][c1]overlay=enable='between(t,$A_FROM,$A_TO)':shortest=1[v1];
[v1][c2]overlay=enable='gte(t,$B_FROM)':shortest=1[v2];
[v2]split=3[a][b][c];
[a]trim=0.8:2.8,setpts=(PTS-STARTPTS)/2.5[s1];
[b]trim=2.8:13.7,setpts=PTS-STARTPTS[s2];
[c]trim=13.6:13.7,setpts=PTS-STARTPTS,tpad=stop_mode=clone:stop_duration=2.5[s3];
[s1][s2][s3]concat=n=3:v=1:a=0,fps=12,split[x][y];
[x]palettegen=max_colors=256:stats_mode=full[p];[y][p]paletteuse=dither=bayer:bayer_scale=3[out]" \
  -map "[out]" demo-raw.gif
gifsicle -O3 --lossy=25 demo-raw.gif -o demo.gif
echo "wrote $PWD/demo.gif"
