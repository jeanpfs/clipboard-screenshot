#!/bin/zsh
# Uninstall clipboard-screenshot

set -euo pipefail

APP_NAME="Clipboard Screenshot"
SUPPORT_DIR="${CLIPBOARD_SCREENSHOT_HOME:-$HOME/Library/Application Support/com.stevederico.clipboard-screenshot}"
# Guard: uninstall does `rm -rf "$SUPPORT_DIR"`. A mis-set CLIPBOARD_SCREENSHOT_HOME
# (e.g. $HOME) would wipe unrelated data. Refuse anything outside our bundle id.
if [[ "$SUPPORT_DIR" != *"com.stevederico.clipboard-screenshot"* ]]; then
  echo "refusing to uninstall: SUPPORT_DIR does not look like ours: $SUPPORT_DIR" >&2
  exit 1
fi
APP_BUNDLE="${SUPPORT_DIR}/${APP_NAME}.app"
LABEL="com.stevederico.clipboard-screenshot"
OLD_LABEL="com.clipboard-screenshot.watcher"
PLIST_DEST="$HOME/Library/LaunchAgents/${LABEL}.plist"
OLD_PLIST="$HOME/Library/LaunchAgents/${OLD_LABEL}.plist"
UID_NUM=$(id -u)
DOMAIN="gui/${UID_NUM}"

echo "==> Uninstalling ${APP_NAME}"

for lbl in "$LABEL" "$OLD_LABEL"; do
  launchctl bootout "${DOMAIN}/${lbl}" 2>/dev/null || true
done
for p in "$PLIST_DEST" "$OLD_PLIST"; do
  if [[ -f "$p" ]]; then
    launchctl unload -w "$p" 2>/dev/null || true
    rm -f "$p"
    echo "    Removed $(basename "$p")"
  fi
done

# Restore floating thumbnail if we turned it off
THUMB_SAVE="$SUPPORT_DIR/previous-show-thumbnail"
if [[ -f "$THUMB_SAVE" ]]; then
  prev=$(cat "$THUMB_SAVE")
  if [[ "$prev" == "0" ]]; then
    defaults write com.apple.screencapture show-thumbnail -bool false
  else
    defaults write com.apple.screencapture show-thumbnail -bool true
  fi
  launchctl kickstart -k "${DOMAIN}/com.apple.SystemUIServer.agent" 2>/dev/null \
    || killall SystemUIServer 2>/dev/null || true
  echo "    Restored screenshot thumbnail setting ($prev)"
fi

# Restore the screenshot location if we moved it out of TCC scope
LOC_SAVE="$SUPPORT_DIR/previous-screencapture-location"
if [[ -f "$LOC_SAVE" ]]; then
  prev_loc=$(cat "$LOC_SAVE")
  if [[ -n "$prev_loc" ]]; then
    # Both keys: `location-screenshot` is what the Cmd+Shift+4 UI reads on
    # Sequoia, `location` is the legacy key the screencapture CLI still uses.
    defaults write com.apple.screencapture location-screenshot "$prev_loc"
    defaults write com.apple.screencapture location "$prev_loc"
    killall Screenshot screencaptureui 2>/dev/null || true
    launchctl kickstart -k "${DOMAIN}/com.apple.SystemUIServer.agent" 2>/dev/null \
      || killall SystemUIServer 2>/dev/null || true
    echo "    Restored screenshot location ($prev_loc)"
  fi
fi

# ~/Screenshots is the user's screenshot folder, not an install dir — never
# touched here. Only our own app bundle and support state are removed.
rm -rf "$APP_BUNDLE" "$SUPPORT_DIR"
echo "    Removed app + support files"

echo
echo "Uninstalled."
