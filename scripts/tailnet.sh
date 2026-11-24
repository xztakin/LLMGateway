#!/bin/sh
# Makes the shared Ollama server reachable from other machines on your Tailscale network (tailnet), such as the
# remote TradeFlow host, and from nowhere else (SPEC.md §7).
#
# Usage: scripts/tailnet.sh share     (serve Ollama on this machine's tailnet address, port 11434)
#        scripts/tailnet.sh unshare   (stop serving it on the tailnet)
#        scripts/tailnet.sh status
#
# How: `tailscale serve` proxies tailnet port 11434 to 127.0.0.1:11434. Ollama itself stays bound to localhost,
# so it is never on the LAN or the internet. The proxy also matters for another reason: Ollama answers 403 to
# requests whose Host header isn't local (a *.ts.net name or 100.x address), and the proxy rewrites it.
# The setting is kept by Tailscale across restarts and reboots; running `share` again is harmless.
#
# Ollama has no authentication. Anyone on the tailnet who can reach this port can use the model, so restrict it
# with a Tailscale access rule (README.md, "Reaching it from another machine").
set -e

PORT=11434
TARGET="http://127.0.0.1:$PORT"

fail() { echo "$1" >&2; exit 1; }

find_cli() {
  if command -v tailscale >/dev/null; then command -v tailscale
  elif [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then echo /Applications/Tailscale.app/Contents/MacOS/Tailscale
  else fail "Tailscale isn't installed: brew install --cask tailscale-app, then open Tailscale and log in."
  fi
}

TS=$(find_cli)

require_login() {
  "$TS" status >/dev/null 2>&1 || fail "Tailscale isn't connected. Open the Tailscale menu bar app and log in (or: $TS up)."
}

dns_name() { "$TS" status --json 2>/dev/null | plutil -extract Self.DNSName raw -o - - 2>/dev/null | sed 's/\.$//'; }
tail_ip() { "$TS" ip -4 2>/dev/null | head -1; }

check() {
  ip=$(tail_ip)
  if curl -sf -m 5 "http://$ip:$PORT/api/version" >/dev/null; then
    echo "ok: Ollama answers on the tailnet at http://$ip:$PORT"
  else
    echo "warning: no answer from http://$ip:$PORT/api/version. Is Ollama up? (scripts/service.sh status)" >&2
  fi
}

share() {
  require_login
  curl -sf -m 3 "$TARGET/api/version" >/dev/null || echo "note: Ollama isn't answering at $TARGET right now (scripts/service.sh status)." >&2
  "$TS" serve --bg --http="$PORT" "$TARGET"
  check
  name=$(dns_name)
  echo
  echo "Point the remote TradeFlow host at:"
  [ -n "$name" ] && echo "  TRADEFLOW_OLLAMA_URL=http://$name:$PORT"
  echo "  TRADEFLOW_OLLAMA_URL=http://$(tail_ip):$PORT   (use the IP inside Docker containers if they can't resolve the name)"
}

unshare() {
  require_login
  "$TS" serve --http="$PORT" off
  echo "Ollama is no longer served on the tailnet (still on $TARGET locally)."
}

status() {
  require_login
  echo "tailnet name: $(dns_name)   ip: $(tail_ip)"
  "$TS" serve status
  check
}

case "$1" in
  share) share ;;
  unshare) unshare ;;
  status) status ;;
  *) fail "Usage: $0 share | unshare | status" ;;
esac
