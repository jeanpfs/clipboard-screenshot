#!/usr/bin/env bash
# Records the screen flow behind assets/demo.gif: Cmd+Shift+4, drag over a region, click the paste target, Cmd+V.
#
# Setup: clipboard-screenshot installed; Preview showing a picture at {10,60} size 708x520 and a rich-text TextEdit
# document at {718,60} size 480x520 (points, main display); Terminal needs Accessibility and Screen Recording access.
# Needs ffmpeg, and the mouse helper:  swiftc -O mouse.swift -o mouse
# Usage: record.sh <work-dir>   -> <work-dir>/raw.mkv (then run make-gif.sh in that directory).
# Delete the screenshot this creates in your capture folder afterwards.
set -u
D="${1:?usage: record.sh <work-dir>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
MOUSE="${MOUSE:-$HERE/mouse}"
mkdir -p "$D"
rm -f "$D/raw.mkv"
osascript -e 'tell application "Preview" to activate' >/dev/null; sleep 1
# Screen device index 2 is the first display on most Macs; check with: ffmpeg -f avfoundation -list_devices true -i ""
ffmpeg -v error -y -f avfoundation -framerate 30 -capture_cursor 1 -pixel_format nv12 -i "${SCREEN:-2}:none" \
  -vf "crop=2376:1040:20:120,format=yuv420p" -c:v libx264 -preset ultrafast -crf 16 "$D/raw.mkv" </dev/null &
FF=$!
sleep 2.5
"$MOUSE" move 300 400; sleep 0.8
osascript -e 'tell application "System Events" to key code 21 using {command down, shift down}'
sleep 1.4
"$MOUSE" drag 190 255 650 555 50
sleep 2.5
"$MOUSE" click 950 300; sleep 0.8
osascript -e 'tell application "System Events" to keystroke "v" using {command down}'
sleep 3.5
kill -INT "$FF"; wait "$FF"
