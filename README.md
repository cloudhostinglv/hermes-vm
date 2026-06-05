# Hermes Agent — per-client single-tenant VM

A turnkey **personal AI agent in the client's messaging apps**, powered by
[Hermes Agent](https://hermes-agent.nousresearch.com) (Nous Research, MIT license),
backed by **avots.ai** as the LLM gateway. One VM = one client. Each client uses
their **own avots key**.

## What the client gets

- A personal agent reachable from **Telegram** (default). It has a closed learning
  loop: it builds skills from experience, curates long-term memory, and searches its
  own past conversations across sessions.
- It runs unattended on their VM (not their laptop) and can run scheduled automations.
- Everything (config, sessions, skills, memories) lives on the VM in `./data`.

Other platforms Hermes supports (Discord, Slack, WhatsApp, Signal, etc.) can be added
later, but Telegram is the default because it is **outbound-only** (see Network model).

## Files in this directory

| File | Purpose |
|---|---|
| `docker-compose.yml` | Pinned image, mounted `./data`, outbound-only, hardened. |
| `config.yaml` | Hermes config wiring avots (provider `custom`, base_url, model). Pre-seeded into `./data`. |
| `.env.example` | Template for per-client secrets (avots key, Telegram token). |
| `autoinstall-snippet.yaml` | cloud-init `write_files` + `runcmd` to inject `.env` and start the stack. |

## Run steps (manual / first VM)

```bash
cd /srv/avots-vm/hermes
mkdir -p data
cp config.yaml data/config.yaml          # the config Hermes reads lives in the data dir
cp .env.example data/.env && edit data/.env   # fill AVOTS_API_KEY + TELEGRAM_BOT_TOKEN + TELEGRAM_ALLOWED_USERS
chown -R 1000:1000 data                   # match HERMES_UID/HERMES_GID in .env
docker compose pull
docker compose up -d
docker compose logs -f gateway            # watch it connect to Telegram + avots
```

Then message the bot on Telegram from an allow-listed account. In production this is
all done by `autoinstall-snippet.yaml` on first boot; you do not run it by hand.

## EXACT avots wiring

Two places, both pointing at the same avots gateway. The secret only ever lives in `.env`.

**`config.yaml` -> `model:`** (non-secret settings)

```yaml
model:
  provider: "custom"                          # any OpenAI-compatible endpoint
  default: "anthropic/claude-opus-4.8"        # lazy alias "claude" also works
  base_url: "https://api.avots.ai/openai/v1"  # MUST end at /v1
  api_key: "${AVOTS_API_KEY}"                 # expanded from .env (${VAR} syntax)
  context_length: 200000                      # safety net if /v1/models is silent
```

**`.env`** (secret + env-var fallback path)

```ini
AVOTS_API_KEY=av_mcp_<key>
OPENAI_API_KEY=av_mcp_<key>                    # same key; Hermes' custom-endpoint fallback
OPENAI_BASE_URL=https://api.avots.ai/openai/v1
```

Auth sent on the wire: `Authorization: Bearer av_mcp_<key>`. Validated 2026-06-05:
`/v1/models` works and tool-calling works both stream and non-stream.

Field provenance (so you can re-verify against upstream):
- `provider: custom` — upstream `cli-config.yaml.example`: `"custom" - Any other
  OpenAI-compatible endpoint. Set base_url below.`
- `default` / `base_url` / `api_key` / `context_length` — same example file.
- `${VAR}` expansion and `OPENAI_BASE_URL` / `OPENAI_API_KEY` fallback — upstream
  `docs/reference/environment-variables.md`.

## Network model: outbound-only, no TLS

Telegram uses **long-polling**: the gateway makes **outbound** HTTPS requests to
Telegram's servers and to avots. Nothing connects *in*. So:

- The compose file **publishes no ports**. The container sits on a private bridge.
- **No inbound TLS, no certificates, no reverse proxy, no open 443.** There is no
  inbound surface to terminate TLS for.
- This is intentionally more locked down than upstream's `network_mode: host`.

The only optional inbound service is the **local admin dashboard** (port 9119),
which is **off by default** and, when enabled, binds **127.0.0.1 only**. Reach it via
an SSH tunnel: `ssh -L 9119:localhost:9119 <vm>`. Never bind it to `0.0.0.0`; it
stores API keys.

> If a client ever needs a messaging transport that requires an **inbound webhook**
> (e.g. some non-Telegram integrations), that changes the model: you then need TLS +
> a reverse proxy (Caddy), like the builder products. The Telegram default avoids all
> of that.

## Security hardening checklist

The agent can run arbitrary commands/code. Critically, **Hermes skips dangerous-command
approval when its terminal/exec backend runs inside a container** — upstream:
*"When running in `docker`, `singularity`, `modal`, or `daytona` backends, dangerous
command checks are skipped because the container itself is the security boundary."*
On this VM the agent's default `local` backend executes inside the Hermes container,
so **the VM and its egress are the real security boundary**. Treat the whole VM as
fully compromisable by its own agent and lock the box down:

- [x] **Pin a patched image by digest** — `nousresearch/hermes-agent:v2026.5.29.2`
      (= release v0.15.2) pinned with `@sha256:...`. Never `:latest`.
- [x] `security_opt: [no-new-privileges:true]` on every service.
- [x] **No `docker.sock` mount** anywhere — the agent must never reach the host Docker.
- [x] `cap_drop: [ALL]`, `pids_limit`, CPU/memory limits, log rotation.
- [x] **Publish no public ports**; dashboard (if any) loopback-only.
- [x] **Set `TELEGRAM_ALLOWED_USERS`** — without it, anyone who finds the bot can drive
      the agent. This is the inbound authorization control.
- [x] `approvals.mode: manual` in config (never `off`); do **not** enable YOLO
      (`HERMES_YOLO_MODE` / `--yolo`).
- [ ] **Restrict outbound egress** at the VM/network level (firewall/security group):
      allow only what the agent needs (avots, Telegram, package mirrors). This is the
      real mitigation for prompt-injection exfiltration, since in-container approval is
      skipped. See upstream `docs/security/network-egress-isolation.md`.
- [ ] Keep `/var/log/cloud-init-output.log` root-only (it can contain the rendered `.env`).
- [ ] **Patch + re-bake pipeline**: this project is pre-1.0 and ships releases/CVEs
      frequently. Re-check Docker Hub + GitHub releases and re-bake on each patch.

## Version-pin note

- Pinned: `nousresearch/hermes-agent:v2026.5.29.2` (release **v0.15.2 (2026.5.29.2)**),
  the newest patched release as of **2026-06-05**.
- Multi-arch (amd64 + arm64) index digest pinned in compose:
  `sha256:2bba4ab37729ebdd864d4caf277b24fec4cd8bfc2855185fd9f4c90f9bf7bfa3`.
- A `# PIN — re-verify before baking` comment marks the tag in `docker-compose.yml`.
  Re-verify the tag **and** digest before baking the golden image.

## Caveats / things to verify before baking

- **Pre-1.0 churn.** Config keys and behavior can shift between releases. Re-validate
  `config.yaml` against the pinned tag's `cli-config.yaml.example` when bumping.
- **`context_length: 200000`** is a safety-net value for Claude Opus 4.x. If avots'
  `/v1/models` advertises a context window, Hermes auto-detects it and you can drop the
  override; confirm the right number for the default model on avots.
- **In-container approval is skipped** (documented above). This is the single most
  important reason egress restriction + VM lockdown are mandatory, not optional.
- **Image is built/pushed under a Docker Hub account** (`nousresearch/hermes-agent`,
  pusher `definitelynotcthulhu`); there is currently **no GHCR mirror**. Confirm the
  publisher is trusted and consider mirroring the pinned digest into your own registry
  so a Hub change can't move it under you.
- **Dashboard PID-namespace coupling.** The optional dashboard must share the gateway's
  PID namespace (upstream: running it as a separate container is unsupported). The
  compose uses `pid: service:gateway` + `network_mode: service:gateway` to satisfy this;
  re-verify if you enable it.
- **Telegram numeric user IDs** must be filled in `TELEGRAM_ALLOWED_USERS` per client;
  an empty/placeholder value leaves the bot open.
