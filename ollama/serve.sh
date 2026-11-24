#!/bin/sh
# Runs the shared Ollama server for launchd (agent local.llmgateway.ollama, installed by scripts/service.sh).
# Loads ollama/ollama.env, and writes Ollama's output to logs/ollama.log (moved to ollama.log.1 past 50 MB
# when it starts).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$ROOT/logs/ollama.log"
mkdir -p "$ROOT/logs"
if [ -f "$LOG" ] && [ "$(stat -f%z "$LOG")" -gt 52428800 ]; then mv "$LOG" "$LOG.1"; fi
set -a
[ -f "$ROOT/ollama/ollama.env" ] && . "$ROOT/ollama/ollama.env"
set +a
echo "$(date '+%Y-%m-%d %H:%M:%S') [llmgateway] starting ollama serve on ${OLLAMA_HOST:-127.0.0.1:11434}" >>"$LOG"
exec ollama serve >>"$LOG" 2>&1
