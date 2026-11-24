# LLMGateway

LLMGateway serves Qwen3-14B on your own hardware to several apps (TradeFlow's Sentinel, LeadScout, and others). It falls back to a pay-per-token host when local serving is down, too slow, or busy.

The requirements are in [SPEC.md](SPEC.md). The gateway itself isn't built yet; milestone 1 is evaluating whether LiteLLM's proxy covers most of the spec.

## What runs today: the shared Ollama server

One Ollama server, shared by every app, runs as its own background service with a menu bar icon. Apps no longer start their own.

```bash
brew install ollama
scripts/service.sh install     # start at login, restart if it stops, menu bar icon
ollama pull qwen3:14b          # each model an app uses, one time
```

- **Address:** `http://127.0.0.1:11434`. Apps use the Ollama API there, or the OpenAI-compatible API at `/v1`. Docker containers reach it at `http://host.docker.internal:11434`.
- **Menu bar icon** (a chip):
  - The dot is green when a model is in memory, gray when the server is idle, and red when it's down.
  - The menu shows the loaded model and when it unloads, and lists the installed models.
  - It can unload a model to free memory, and start, stop or restart Ollama.
  - It also opens the log and the settings file.
- **Settings:** `ollama/ollama.env` holds the listen address, keep-alive time and parallel slots. After editing it, choose **Restart Ollama** from the menu, or run `scripts/service.sh restart`.
- **Log:** `logs/ollama.log`. It moves to `ollama.log.1` once it passes 50 MB, checked each time Ollama starts.
- **Other commands:** `scripts/service.sh status`, `scripts/service.sh uninstall`. Downloaded models stay in `~/.ollama`.
- **Stop from the menu:** Ollama stays stopped until you start it again or log in again. Every app that uses it fails its AI calls in the meantime.

### Files

| Path | What it is |
| --- | --- |
| `scripts/service.sh` | Installs the two launchd agents: `local.llmgateway.ollama` and `local.llmgateway.tray` |
| `ollama/serve.sh` | What launchd runs: loads `ollama.env`, then `exec ollama serve` |
| `ollama/ollama.env` | Ollama settings |
| `macos/LLMGatewayTray.swift` | The menu bar app, built to `~/Applications/LLMGateway.app` |

Once the gateway in SPEC.md exists, it will sit in front of this server, and apps will move from `:11434` to the gateway's address.
