#!/bin/sh
# Runs the shared Ollama server in the background on macOS: starts at login, restarts if it stops,
# and adds a menu bar icon (status, loaded model, start/stop/restart, log).
#
# Usage: scripts/service.sh install     (build the menu bar app, install and start both)
#        scripts/service.sh uninstall   (stop and remove both; downloaded models stay in ~/.ollama)
#        scripts/service.sh restart     (restart Ollama, e.g. after editing ollama/ollama.env)
#        scripts/service.sh status
#
# Two launchd agents in ~/Library/LaunchAgents: local.llmgateway.ollama (ollama/serve.sh) and
# local.llmgateway.tray (the menu bar icon, ~/Applications/LLMGateway.app).
# Ollama's output goes to logs/ollama.log. Re-run the install after moving this folder.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENTS="$HOME/Library/LaunchAgents"
SERVER=local.llmgateway.ollama
TRAY=local.llmgateway.tray
SERVER_PLIST="$AGENTS/$SERVER.plist"
TRAY_PLIST="$AGENTS/$TRAY.plist"
APP="$HOME/Applications/LLMGateway.app"
APP_BINARY="$APP/Contents/MacOS/LLMGateway"
LOG_FILE="$ROOT/logs/ollama.log"
SETTINGS="$ROOT/ollama/ollama.env"
DOMAIN="gui/$(id -u)"

fail() { echo "$1" >&2; exit 1; }
loaded() { launchctl print "$DOMAIN/$1" >/dev/null 2>&1; }
unload() { if loaded "$1"; then launchctl bootout "$DOMAIN/$1" 2>/dev/null || true; fi; }

# host:port from ollama.env (default 127.0.0.1:11434)
ollama_host() {
  host=$(sed -n 's/^OLLAMA_HOST=//p' "$SETTINGS" 2>/dev/null | tail -1)
  echo "${host:-127.0.0.1:11434}"
}

install() {
  [ "$(uname)" = Darwin ] || fail "This sets up a macOS background service."
  OLLAMA_BIN=$(command -v ollama) || fail "Ollama isn't installed: brew install ollama"
  command -v swiftc >/dev/null || fail "swiftc not found. Install Apple's command line tools: xcode-select --install"
  HOST=$(ollama_host)
  URL="http://$HOST"
  PATH_VALUE="$(dirname "$OLLAMA_BIN"):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

  unload "$TRAY"
  unload "$SERVER"

  echo "Building the menu bar app…"
  mkdir -p "$APP/Contents/MacOS" "$AGENTS" "$ROOT/logs"
  cat >"$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$TRAY</string>
  <key>CFBundleName</key><string>LLMGateway</string>
  <key>CFBundleExecutable</key><string>LLMGateway</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
EOF
  swiftc -O -o "$APP_BINARY" "$ROOT/macos/LLMGatewayTray.swift" || fail "Couldn't compile the menu bar app."

  cat >"$SERVER_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$SERVER</string>
  <key>ProgramArguments</key><array><string>$ROOT/ollama/serve.sh</string></array>
  <key>WorkingDirectory</key><string>$ROOT</string>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>$PATH_VALUE</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$ROOT/logs/launchd.log</string>
  <key>StandardErrorPath</key><string>$ROOT/logs/launchd.log</string>
</dict></plist>
EOF
  cat >"$TRAY_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$TRAY</string>
  <key>ProgramArguments</key><array><string>$APP_BINARY</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>LLMGATEWAY_OLLAMA_URL</key><string>$URL</string>
    <key>LLMGATEWAY_SERVICE_LABEL</key><string>$SERVER</string>
    <key>LLMGATEWAY_SERVICE_PLIST</key><string>$SERVER_PLIST</string>
    <key>LLMGATEWAY_LOG_FILE</key><string>$LOG_FILE</string>
    <key>LLMGATEWAY_SETTINGS_FILE</key><string>$SETTINGS</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
EOF

  # Another Ollama already on the port (e.g. one an app started itself): ours keeps retrying every
  # 10 seconds and takes over as soon as that one stops.
  PORT=${HOST##*:}
  OTHER=$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | head -1 || true)

  launchctl bootstrap "$DOMAIN" "$SERVER_PLIST" || fail "launchctl bootstrap $SERVER_PLIST failed"
  launchctl bootstrap "$DOMAIN" "$TRAY_PLIST" || fail "launchctl bootstrap $TRAY_PLIST failed"

  echo
  echo "Installed. Ollama now starts at login and runs in the background on $URL."
  [ -n "$OTHER" ] && echo "  Note: another process (pid $OTHER) already listens on port $PORT; this one takes over when it stops."
  echo "  Menu bar: the chip icon (green = model loaded, gray = idle, red = down)"
  echo "  Settings: ollama/ollama.env, then Restart Ollama from the menu"
  echo "  Log:      logs/ollama.log"
  echo "  Remove:   scripts/service.sh uninstall"
}

uninstall() {
  unload "$TRAY"
  unload "$SERVER"
  rm -f "$SERVER_PLIST" "$TRAY_PLIST"
  rm -rf "$APP"
  echo "Removed the Ollama service and menu bar icon. Downloaded models stay in ~/.ollama."
}

status() {
  for label in "$SERVER" "$TRAY"; do
    if [ ! -f "$AGENTS/$label.plist" ]; then echo "$label: not installed"; continue; fi
    info=$(launchctl print "$DOMAIN/$label" 2>/dev/null || true)
    state=$(echo "$info" | sed -n 's/^[[:space:]]*state = //p' | head -1)
    pid=$(echo "$info" | sed -n 's/^[[:space:]]*pid = //p' | head -1)
    echo "$label: ${state:-not loaded}${pid:+ (pid $pid)}"
  done
  URL="http://$(ollama_host)"
  if version=$(curl -sf --max-time 2 "$URL/api/version"); then
    echo "ollama: up at $URL $version"
    curl -sf --max-time 2 "$URL/api/ps" | sed 's/"digest":"[^"]*",//g' | cut -c1-300
    echo
  else
    echo "ollama: not answering at $URL"
  fi
}

case "${1:-status}" in
  install) install ;;
  uninstall) uninstall ;;
  restart) launchctl kickstart -k "$DOMAIN/$SERVER" && echo "Restarted Ollama." ;;
  status) status ;;
  *) fail "Usage: scripts/service.sh <install|uninstall|restart|status>" ;;
esac
