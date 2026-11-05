#!/bin/sh
# Installs Snapback.app into ~/Applications and starts it at login via a LaunchAgent.
#
# Usage: ./install.sh [path/to/Snapback.app]
# Defaults to the Snapback.app next to this script (as shipped in release zips).

set -eu

APP_NAME="Snapback"
BUNDLE_ID="com.snapback.Snapback"

SRC="${1:-$(cd "$(dirname "$0")" && pwd)/$APP_NAME.app}"
DEST_DIR="$HOME/Applications"
APP="$DEST_DIR/$APP_NAME.app"
AGENT="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
LOG="$HOME/Library/Logs/$APP_NAME.log"
DOMAIN="gui/$(id -u)"

if [ ! -d "$SRC" ]; then
    echo "error: $SRC not found" >&2
    exit 1
fi

launchctl bootout "$DOMAIN/$BUNDLE_ID" 2>/dev/null || true

mkdir -p "$DEST_DIR" "$(dirname "$AGENT")" "$(dirname "$LOG")"
rm -rf "$APP"
cp -R "$SRC" "$APP"
# Downloaded builds are ad-hoc signed, not notarized: clear the quarantine flag
# so Gatekeeper lets launchd start the app.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$BUNDLE_ID</string>
	<key>ProgramArguments</key>
	<array>
		<string>$APP/Contents/MacOS/$APP_NAME</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<!-- Restart after a crash, but not after choosing Quit. -->
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardOutPath</key>
	<string>$LOG</string>
	<key>StandardErrorPath</key>
	<string>$LOG</string>
</dict>
</plist>
EOF

launchctl bootstrap "$DOMAIN" "$AGENT"

echo "Installed $APP_NAME to $APP"
echo "Grant Accessibility access when prompted:"
echo "  System Settings > Privacy & Security > Accessibility > $APP_NAME"
