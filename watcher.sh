#!/bin/zsh
# clipboard-screenshot — copy new screenshots to the clipboard.
# Triggered by launchd WatchPaths (FS event). Zero deps: zsh + osascript + launchd.
#
# Race: WatchPaths can fire before the new PNG is fully written.
# We only copy when mtime > last success so the previous shot is never re-pasted.

set -euo pipefail
setopt NULL_GLOB EXTENDED_GLOB
unsetopt NOMATCH

SUPPORT_DIR="${CLIPBOARD_SCREENSHOT_HOME:-$HOME/Library/Application Support/com.stevederico.clipboard-screenshot}"
mkdir -p "$SUPPORT_DIR"
STATE_FILE="$SUPPORT_DIR/last-processed"
MTIME_FILE="$SUPPORT_DIR/last-mtime"
LOG_FILE="$SUPPORT_DIR/watcher.log"
LOCK_DIR="$SUPPORT_DIR/watcher.lock"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# Overlapping fires: wait for the in-flight run (it may still be waiting for the new PNG)
got_lock=0
for _ in {1..60}; do
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    got_lock=1
    break
  fi
  # Stale lock (>20s) — steal
  if [[ -d "$LOCK_DIR" ]]; then
    lock_age=$(( $(date +%s) - $(stat -f %m "$LOCK_DIR" 2>/dev/null || echo 0) ))
    if (( lock_age > 20 )); then
      rmdir "$LOCK_DIR" 2>/dev/null || true
      continue
    fi
  fi
  sleep 0.05
done
(( got_lock )) || exit 0
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM

# Resolve where the system actually saves screenshots.
#
# macOS Sequoia split this preference per capture mode. The interactive UI behind
# Cmd+Shift+3/4 reads `location-screenshot`; the legacy `location` key is only
# honoured by the `screencapture` CLI. Reading `location` alone made the agent
# watch a folder the UI never writes to, so interactive captures never fired and
# the clipboard kept serving the previously copied image.
get_ss_location() {
  local loc
  loc=$(defaults read com.apple.screencapture location-screenshot 2>/dev/null) \
    || loc=$(defaults read com.apple.screencapture location 2>/dev/null) \
    || loc="$HOME/Desktop"
  loc=${loc/#\~/$HOME}
  loc=${loc%/}
  [[ -d "$loc" ]] && echo "$loc" || echo "$HOME/Desktop"
}

# True only for a real screenshot file sitting *directly* in the watch dir.
# mdfind -onlyin is recursive: Desktop/projects/**/Screenshot* would otherwise win
# (and "screenshots" dirs match case-insensitive Screenshot*).
is_shot_in_dir() {
  local f="$1" dir="$2" base parent
  [[ -n "$f" && -f "$f" ]] || return 1
  parent=$(dirname -- "$f")
  [[ "$parent" == "$dir" ]] || return 1
  base=${f:t}
  [[ "$base" == Screenshot* || "$base" == Screen\ Shot* ]] || return 1
  [[ "$base" == *.png || "$base" == *.jpg || "$base" == *.jpeg || "$base" == *.heic ]] || return 1
  return 0
}

# Pick newest Screenshot* by mtime (watch dir only — not nested project copies).
#
# Cost ordering matters: this runs once per retry attempt, up to max_attempts.
# Measured on macOS 26 (M3 Max): glob 0.04ms, mdfind 40ms from a shell and ~700ms
# from the launchd agent, System Events osascript 116ms+. Spawning the slow two
# every attempt made a fruitless loop hold the lock for ~30s, and the NEXT
# screenshot's event then hit `(( got_lock )) || exit 0` and was dropped silently.
#
# 1) FS glob — authoritative and free when the dir is outside TCC scope, which is
#    why the screenshot location is installed to ~/Screenshots.
# 2) Spotlight — only when readdir is blocked (TCC dir). Also serves a stale view
#    there (observed listing a deleted file, omitting the newest), so it is never
#    the primary source.
newest_screenshot() {
  local dir="$1" best="" best_m=0 f m
  local -a candidates

  candidates=("$dir"/Screenshot*(N.) "$dir"/Screen\ Shot*(N.))
  for f in "${candidates[@]}"; do
    is_shot_in_dir "$f" "$dir" || continue
    m=$(stat -f %Fm -- "$f" 2>/dev/null || echo 0)
    if (( m > best_m )); then
      best_m=$m
      best=$f
    fi
  done

  if [[ -z "$best" ]]; then
    while IFS= read -r f; do
      is_shot_in_dir "$f" "$dir" || continue
      m=$(stat -f %Fm -- "$f" 2>/dev/null || echo 0)
      if (( m > best_m )); then
        best_m=$m
        best=$f
      fi
    done < <(mdfind -onlyin "$dir" \
      '(kMDItemFSName == "Screenshot*"c) || (kMDItemFSName == "Screen Shot*"c)' 2>/dev/null)
  fi

  print -r -- "$best"
}

# Last-resort enumeration via Automation. Costs an osascript spawn and only works
# if Automation was already granted, so it runs ONCE after the retry loop gives
# up — never inside it.
newest_screenshot_via_system_events() {
  local dir="$1" se
  se=$(osascript - "$dir" <<'APPLESCRIPT' 2>/dev/null || true
on run argv
  set dirPath to item 1 of argv
  try
    tell application "System Events"
      set theFolder to folder dirPath
      set shots to every file of theFolder whose name starts with "Screenshot" or name starts with "Screen Shot"
      if (count of shots) is 0 then return ""
      set best to item 1 of shots
      set bestDate to modification date of best
      repeat with f in shots
        set d to modification date of f
        if d > bestDate then
          set bestDate to d
          set best to f
        end if
      end repeat
      return POSIX path of best
    end tell
  on error
    return ""
  end try
end run
APPLESCRIPT
)
  se=${se//$'\r'/}
  se=${se//$'\n'/}
  is_shot_in_dir "$se" "$dir" && print -r -- "$se"
}

# Size > 4KB and stable across two samples (avoid mid-write)
file_ready() {
  local file="$1" a b
  [[ -f "$file" ]] || return 1
  a=$(stat -f %z "$file" 2>/dev/null || echo 0)
  (( a > 4096 )) || return 1
  sleep 0.04
  [[ -f "$file" ]] || return 1
  b=$(stat -f %z "$file" 2>/dev/null || echo 0)
  (( b > 4096 && b == a ))
}

put_image_on_clipboard() {
  local file="$1" out
  [[ -f "$file" ]] || return 1

  out=$(osascript -l JavaScript - "$file" <<'JXA' 2>&1
function run(argv) {
  ObjC.import("AppKit");
  ObjC.import("Foundation");
  var data = $.NSData.dataWithContentsOfFile(argv[0]);
  if (!data || data.length === 0) return "fail:read";
  var pb = $.NSPasteboard.generalPasteboard;
  pb.clearContents;
  return pb.setDataForType(data, $.NSPasteboardTypePNG) ? "ok" : "fail:set";
}
JXA
)
  if [[ "$out" == "ok" ]]; then
    return 0
  fi

  out=$(osascript - "$file" <<'APPLESCRIPT' 2>&1
on run argv
  try
    set the clipboard to (read (POSIX file (item 1 of argv)) as «class PNGf»)
    return "ok"
  on error errMsg
    return "fail:" & errMsg
  end try
end run
APPLESCRIPT
)
  [[ "$out" == "ok" ]]
}

notify() {
  osascript -e "display notification \"$2\" with title \"$1\"" &>/dev/null &
}

mark_done() {
  local name="$1" mtime="$2"
  echo "$mtime" > "$MTIME_FILE"
  {
    echo "$name"
    grep -Fvx -- "$name" "$STATE_FILE" 2>/dev/null | head -20 || true
  } > "${STATE_FILE}.tmp"
  mv -f "${STATE_FILE}.tmp" "$STATE_FILE"
}

# Copy $1 to the clipboard if it is newer than mtime $2.
# 0 = copied, 1 = copy failed, 2 = nothing to do (absent / not newer / mid-write).
copy_if_newer() {
  local src="$1" last="$2" label="$3" mtime name
  [[ -n "$src" && -f "$src" ]] || return 2
  mtime=$(stat -f %Fm -- "$src" 2>/dev/null || echo 0)
  name=$(basename -- "$src")
  (( mtime > last )) || return 2
  file_ready "$src" || return 2
  # Re-stat after ready (the file may have been rewritten while we sampled it)
  mtime=$(stat -f %Fm -- "$src" 2>/dev/null || echo 0)
  if put_image_on_clipboard "$src"; then
    mark_done "$name" "$mtime"
    log "clipboard: $name (mtime=$mtime $label)"
    notify "Screenshot Ready" "Cmd+V to paste"
    return 0
  fi
  log "clipboard failed: $name"
  return 1
}

# Core: wait for a screenshot NEWER than last success, then copy that only.
try_copy_new() {
  local watch src last attempt rc
  local max_attempts=40   # * ~0.08s ≈ 3.2s for file to appear after event
  local delay=0.08

  last=$(cat "$MTIME_FILE" 2>/dev/null || echo 0)
  # guard non-numeric
  # %Fm is nanosecond-resolution, so this is a float. A whole-second %m dropped
  # any screenshot taken in the same second as the previous one: mtime == last
  # failed the strictly-greater test and the shot never reached the clipboard.
  [[ "$last" == <->(.<->)# ]] || last=0

  watch=$(get_ss_location)
  log "event (watch=$watch last_mtime=$last)"

  for attempt in {1..$max_attempts}; do
    src=$(newest_screenshot "$watch")
    src=${src//$'\r'/}
    src=${src//$'\n'/}

    rc=0; copy_if_newer "$src" "$last" "attempt=$attempt" || rc=$?
    (( rc == 2 )) || return $rc

    if (( attempt == 1 )) && [[ -n "$src" ]]; then
      log "newest not newer: ${src:t} (last=$last)"
    fi
    sleep $delay
  done

  # Loop exhausted. One Automation-based enumeration, deliberately outside the
  # hot path: it costs an osascript spawn and only helps when readdir is blocked.
  src=$(newest_screenshot_via_system_events "$watch")
  src=${src//$'\r'/}
  src=${src//$'\n'/}
  rc=0; copy_if_newer "$src" "$last" "via=system-events" || rc=$?
  (( rc == 2 )) || return $rc

  log "no newer screenshot within timeout (last_mtime=$last)"
  return 0
}

try_copy_new || true
