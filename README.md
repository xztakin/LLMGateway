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
  - **Open Chat…** opens a chat window, so you can use the local model like an app. You pick the model, and Think turns reasoning on for qwen3. Replies stream in. While the window is open, the app shows in the Dock and in Cmd-Tab. The chat uses one of Ollama's two parallel slots.
- **Settings:** `ollama/ollama.env` holds the listen address, keep-alive time and parallel slots. After editing it, choose **Restart Ollama** from the menu, or run `scripts/service.sh restart`.
- **Log:** `logs/ollama.log`. It moves to `ollama.log.1` once it passes 50 MB, checked each time Ollama starts.
- **Other commands:** `scripts/service.sh status`, `scripts/service.sh uninstall`. Downloaded models stay in `~/.ollama`.
- **Stop from the menu:** Ollama stays stopped until you start it again or log in again. Every app that uses it fails its AI calls in the meantime.

### Reaching it from another machine (the remote TradeFlow host)

Other machines reach Ollama over Tailscale only. It is never on the LAN or the internet (SPEC.md §7).

1. **This Mac, once:**
   - Install Tailscale with `brew install --cask tailscale-app`. It asks for your password.
   - Open Tailscale from Applications, allow its system extension, and log in.
   - Then run `scripts/tailnet.sh share`. It prints the URL the remote host should use, `http://<this-mac>.<tailnet>.ts.net:11434`.
   - Tailscale keeps the setting across reboots.
2. **The remote host:**
   - Install Tailscale and join the same tailnet with `tailscale up --advertise-tags=tag:tradeflow`.
   - In TradeFlow's `.env`, set `TRADEFLOW_OLLAMA_URL` to the printed URL. If the Docker containers can't resolve `*.ts.net` names, use the 100.x IP instead.
   - Check it from the host with `curl $TRADEFLOW_OLLAMA_URL/api/version`.
3. **Access rule:** Ollama has no authentication, so limit who can reach the port. In the Tailscale admin console under Access controls, tag this Mac `tag:llm` and add a rule like this:

   ```json
   "tagOwners": { "tag:llm": ["autogroup:admin"], "tag:tradeflow": ["autogroup:admin"] },
   "grants": [ { "src": ["tag:tradeflow"], "dst": ["tag:llm"], "ip": ["tcp:11434"] } ]
   ```

   Add LeadScout's machine to `src` when it moves off this Mac. If your policy still has the default allow-all rule, remove it, or every tailnet device can reach the model.
4. **Keep this Mac awake:** if it sleeps, the sentinel fails closed and blocks entries. Keep it plugged in. System sleep is already off (`pmset -g`), but closing the lid still sleeps it.

`scripts/tailnet.sh status` shows the tailnet address and whether Ollama answers there. `scripts/tailnet.sh unshare` takes it off the tailnet. Once the gateway exists, share the gateway's port instead. It adds per-client keys.

### Files

| Path | What it is |
| --- | --- |
| `scripts/tailnet.sh` | Serves Ollama on the Tailscale network for remote apps |
| `scripts/service.sh` | Installs the two launchd agents: `local.llmgateway.ollama` and `local.llmgateway.tray` |
| `ollama/serve.sh` | What launchd runs: loads `ollama.env`, then `exec ollama serve` |
| `ollama/ollama.env` | Ollama settings |
| `macos/LLMGatewayTray.swift` | The menu bar app, built to `~/Applications/LLMGateway.app` |

Once the gateway in SPEC.md exists, it will sit in front of this server, and apps will move from `:11434` to the gateway's address.
