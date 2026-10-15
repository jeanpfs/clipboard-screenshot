#!/bin/zsh
# Installer for clipboard-screenshot
# Copies new screenshots to the clipboard.

set -euo pipefail
setopt NULL_GLOB
unsetopt NOMATCH

SUPPORT_DIR="${CLIPBOARD_SCREENSHOT_HOME:-$HOME/Library/Application Support/com.stevederico.clipboard-screenshot}"
APP_NAME="Clipboard Screenshot"
APP_BUNDLE="${SUPPORT_DIR}/${APP_NAME}.app"
APP_EXEC="${APP_BUNDLE}/Contents/MacOS/clipboard-screenshot"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
LABEL="com.stevederico.clipboard-screenshot"
PLIST_DEST="$LAUNCH_AGENTS/${LABEL}.plist"
OLD_LABEL="com.clipboard-screenshot.watcher"
OLD_PLIST="$LAUNCH_AGENTS/${OLD_LABEL}.plist"
UID_NUM=$(id -u)
DOMAIN="gui/${UID_NUM}"
SHOTS_DIR="$HOME/Screenshots"

echo "==> Installing ${APP_NAME}"

mkdir -p "$SUPPORT_DIR" "$SHOTS_DIR"
chmod 700 "$SUPPORT_DIR"

# Standardise on ~/Screenshots. It sits at the home root, outside TCC scope, so
# the agent enumerates it directly (0.04ms) instead of depending on Spotlight,
# which serves a stale view for TCC-protected folders like ~/Desktop.
#
# Sequoia splits this preference per capture mode: `location-screenshot` drives
# the Cmd+Shift+3/4 UI while `location` is what the screencapture CLI reads.
# Both must agree, or the agent watches a folder the UI never writes to.
LOC_SAVE="$SUPPORT_DIR/previous-screencapture-location"
CURRENT_LOC=$(defaults read com.apple.screencapture location-screenshot 2>/dev/null) \
  || CURRENT_LOC=$(defaults read com.apple.screencapture location 2>/dev/null) \
  || CURRENT_LOC="$HOME/Desktop"
CURRENT_LOC=${CURRENT_LOC/#\~/$HOME}
CURRENT_LOC=${CURRENT_LOC%/}

if [[ "$CURRENT_LOC" != "$SHOTS_DIR" ]]; then
  # Remember the very first location we displaced, so uninstall can put it back.
  [[ -f "$LOC_SAVE" ]] || printf '%s' "$CURRENT_LOC" > "$LOC_SAVE"
  echo "==> Screenshot location → $SHOTS_DIR (was $CURRENT_LOC)"
  defaults write com.apple.screencapture location-screenshot "$SHOTS_DIR"
  defaults write com.apple.screencapture location "$SHOTS_DIR"
  killall Screenshot screencaptureui 2>/dev/null || true
  launchctl kickstart -k "${DOMAIN}/com.apple.SystemUIServer.agent" 2>/dev/null \
    || killall SystemUIServer 2>/dev/null || true
  CURRENT_LOC="$SHOTS_DIR"
fi

echo "==> Watching screenshot location: $CURRENT_LOC"

# Floating thumbnail (bottom-right) DELAYS writing the PNG to disk until it
# dismisses — so clipboard can't update until then. No public API to the
# in-memory thumbnail. Disable it so the file hits Desktop immediately.
THUMB_SAVE="$SUPPORT_DIR/previous-show-thumbnail"
CUR_THUMB=$(defaults read com.apple.screencapture show-thumbnail 2>/dev/null || echo 1)
if [[ ! -f "$THUMB_SAVE" ]]; then
  echo "$CUR_THUMB" > "$THUMB_SAVE"
fi
if [[ "$CUR_THUMB" != "0" ]]; then
  defaults write com.apple.screencapture show-thumbnail -bool false
  launchctl kickstart -k "${DOMAIN}/com.apple.SystemUIServer.agent" 2>/dev/null \
    || killall SystemUIServer 2>/dev/null || true
  echo "==> Disabled floating screenshot thumbnail (was delaying Desktop write)"
  echo "    Re-enable: defaults write com.apple.screencapture show-thumbnail -bool true"
else
  echo "==> Floating thumbnail already off"
fi

mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"
cp -f "./watcher.sh" "$APP_EXEC"
chmod +x "$APP_EXEC"

cat > "${APP_BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>clipboard-screenshot</string>
    <key>CFBundleIdentifier</key>
    <string>${LABEL}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.7.0</string>
    <key>CFBundleVersion</key>
    <string>1.7.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>${APP_NAME} detects new screenshots so they can be copied to the clipboard.</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © Steve Derico</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "${APP_BUNDLE}/Contents/PkgInfo"
xattr -dr com.apple.quarantine "$APP_BUNDLE" 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_BUNDLE" 2>/dev/null || true

mkdir -p "$LAUNCH_AGENTS"
launchctl bootout "${DOMAIN}/${OLD_LABEL}" 2>/dev/null || true
rm -f "$OLD_PLIST"

# Event-driven: launchd WatchPaths = FSEvents under the hood (no poll loop)
# Watch ONLY the configured screenshot location. Also watching ~/Desktop woke the
# agent on every unrelated Desktop change, and each wake runs a retry loop that
# holds the lock — a real screenshot arriving in that window can be dropped at
# `(( got_lock )) || exit 0`. get_ss_location re-reads the pref on every run, so
# changing the location later is picked up by re-running install.sh.
watch_paths=("$CURRENT_LOC")

WATCH_XML=""
for p in "${watch_paths[@]}"; do
  WATCH_XML+="        <string>${p}</string>
"
done

cat > "$PLIST_DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>${APP_EXEC}</string>
    </array>

    <key>WatchPaths</key>
    <array>
${WATCH_XML}    </array>

    <key>ThrottleInterval</key>
    <integer>0</integer>

    <key>ExitTimeOut</key>
    <integer>15</integer>

    <key>RunAtLoad</key>
    <false/>
    <key>KeepAlive</key>
    <false/>

    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>

    <key>ProcessType</key>
    <string>Interactive</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin</string>
        <key>HOME</key>
        <string>${HOME}</string>
        <key>CLIPBOARD_SCREENSHOT_HOME</key>
        <string>${SUPPORT_DIR}</string>
    </dict>

    <key>StandardOutPath</key>
    <string>${SUPPORT_DIR}/watcher.log</string>
    <key>StandardErrorPath</key>
    <string>${SUPPORT_DIR}/watcher.log</string>
</dict>
</plist>
EOF

chmod 644 "$PLIST_DEST"

if launchctl print "${DOMAIN}/${LABEL}" &>/dev/null; then
  launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
fi
launchctl unload "$PLIST_DEST" 2>/dev/null || true

if launchctl bootstrap "$DOMAIN" "$PLIST_DEST" 2>/dev/null; then
  launchctl enable "${DOMAIN}/${LABEL}" 2>/dev/null || true
  echo "==> Bootstrapped WatchPaths agent (${DOMAIN}/${LABEL})"
else
  launchctl load -w "$PLIST_DEST"
fi

echo
echo "App:     $APP_BUNDLE"
echo "Trigger: WatchPaths on ${watch_paths[*]} (FS event — not polling)"
echo "Logs:    $SUPPORT_DIR/watcher.log"
echo
echo "New screenshots → clipboard automatically."
echo "No Full Disk Access required (resolves files via mdfind under TCC)."
echo
echo "Stop:      launchctl bootout ${DOMAIN}/${LABEL}"
echo "Uninstall: cd $(pwd) && ./uninstall.sh"
