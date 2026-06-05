# Hermes Agent — per-client single-tenant VM

A turnkey **personal AI agent in the client's messaging apps**, powered by
[Hermes Agent](https://hermes-agent.nousresearch.com) (Nous Research, MIT license),
backed by an **OpenAI-compatible LLM provider** (avots.ai by default; the client can
also pick OpenAI or Anthropic in the panel). One VM = one client. Each client uses
their **own provider key**, which they enter in a branded web setup panel.

## What the client gets

- A personal agent reachable from **Telegram** (default). It has a closed learning
  loop: it builds skills from experience, curates long-term memory, and searches its
  own past conversations across sessions.
- A **CloudHosting setup panel** at `https://vps-<o3>-<o4>.cloudhosting.lv` (the VM's
  deterministic hostname from its IP, e.g. `185.8.60.226 → vps-60-226.cloudhosting.lv`).
  They:
  1. log in with **PANEL_PASSWORD**,
  2. pick a provider — **avots is recommended and pre-selected** — and paste their key
     (the panel validates it against the provider before saving),
  3. create a Telegram bot via **@BotFather** and paste the **bot token** plus the
     **allowed Telegram user ids** (comma-separated; get yours from **@userinfobot**),
     following the panel's in-page guide.
  The **panel is the single source of truth for all per-client agent secrets**
  (provider, API key, Telegram bot token, Telegram allowed users). It writes
  `config.yaml` + `.env` into the shared data dir (`./data`) and triggers a gateway
  restart so the agent immediately uses the new settings. The Ubuntu autoinstall
  injects **none** of these secrets — it sets only `PANEL_PASSWORD` (and derives the
  domain).
- It runs unattended on their VM (not their laptop) and can run scheduled automations.
- Everything (config, sessions, skills, memories) lives on the VM in `./data`.

Other platforms Hermes supports (Discord, Slack, WhatsApp, Signal, etc.) can be added
later; Telegram is the default because it is **outbound-only**.

## Files in this directory

| File | Purpose |
|---|---|
| `docker-compose.yml` | `gateway` (Hermes, pinned+digest), `panel` (ai-panel), `caddy` (TLS), optional `dashboard`. Hardened, no docker.sock. `gateway` has **no `env_file`** — its secrets come from the data dir, not the compose-level `.env`. |
| `Caddyfile` | TLS terminator → `reverse_proxy panel:8080` for `${PANEL_DOMAIN}`, automatic Let's Encrypt. |
| `config.yaml` | Hermes config wiring the provider (provider `custom`, base_url, model). Pre-seeded into `./data`; the panel rewrites it when the client saves a key. |
| `.env.example` | Template for the **compose-level** `.env` ONLY (PANEL_PASSWORD, PANEL_DOMAIN, HERMES_UID/GID, optional dashboard). Provider/Telegram secrets are **not** here — the panel writes those into `./data`. |
| `firstboot.sh` | First-real-boot oneshot: data perms, derive domain, `compose pull/up`, install applier, self-disable. |
| `hermes-firstboot.service` | systemd oneshot that runs `firstboot.sh` once. |
| `autoinstall-snippet.yaml` | Ubuntu autoinstall drop-in: apt-install, clone, write `.env`, enable first-boot unit. |
| `applier/` | Host-side applier (`apply.sh` + systemd `path`/`service`): panel → `docker compose restart gateway`. |

## Network model: inbound 443 for the panel, still outbound for the agent

This stack used to be strictly outbound-only. Adding the setup panel changes that:

- **INBOUND 80 + 443 are now required** for the panel + ACME. Caddy is the **only**
  internet-facing service; it terminates TLS for `${PANEL_DOMAIN}` and reverse-proxies
  `:443 → panel:8080`. Because Hermes is an **agent** (no product UI), there is **only
  `:443` = the panel** — no `:8443` product port.
- The **agent (`gateway`) still publishes nothing.** It sits on its own private bridge
  (`hermes`) and only talks **outbound**: long-polling to Telegram and HTTPS to the
  provider (avots / OpenAI / Anthropic). The panel + Caddy share a separate `web` bridge.
- TLS is **real Let's Encrypt via HTTP-01** — the `vps-<o3>-<o4>.cloudhosting.lv`
  A-record already exists by convention, so issuance needs no DNS step.

The only other optional inbound service is the **local admin dashboard** (port 9119),
**off by default**, bound to **127.0.0.1 only**. Reach it via an SSH tunnel:
`ssh -L 9119:localhost:9119 <vm>`. Never bind it to `0.0.0.0`; it stores API keys.

## First-boot + apply flow

```
Ubuntu autoinstall (late-commands, in-target):
  apt-install git/docker.io/docker-compose-v2/ca-certificates
  git clone -> /opt/hermes-vm
  write COMPOSE-LEVEL /opt/hermes-vm/.env: ONLY PANEL_PASSWORD (+ blank PANEL_DOMAIN,
    HERMES_UID/GID). NO provider key, NO Telegram token/allowlist.
  enable hermes-firstboot.service
        |
        v  (first real boot, docker + network up)
firstboot.sh:
  chown ./data to HERMES_UID:GID; seed config.yaml; chmod 0600 ./data/.env if present
  derive PANEL_DOMAIN from primary IPv4 if blank  ->  vps-<o3>-<o4>.cloudhosting.lv
  docker compose pull && up -d   (gateway + panel + caddy)
  install applier units + /etc/cloudhosting-panel.env; enable cloudhosting-applier.path
  disable itself
        |
        v  (client opens the panel and enters provider/key + Telegram token/allowed ids)
panel (unprivileged, SOURCE OF TRUTH for secrets) writes ./data/config.yaml +
  ./data/.env (OPENAI_API_KEY, OPENAI_BASE_URL, TELEGRAM_BOT_TOKEN,
  TELEGRAM_ALLOWED_USERS), touches ./data/.apply-request
        |
        v
systemd cloudhosting-applier.path  ->  .service  ->  applier/apply.sh (on the HOST)
        |
        v
docker compose -f /opt/hermes-vm/docker-compose.yml restart gateway
  (gateway has no env_file; it re-reads ./data/config.yaml + ./data/.env at start)
```

The panel container is **unprivileged and has no docker.sock**; only the host-side
applier drives docker. Docker control stays off the web surface entirely.

> **Reload behaviour — `restart`, not `up -d` (and why).** The `gateway` service has
> **no `env_file`** and carries **no** provider/Telegram secrets in its compose
> `environment:`. Every agent secret lives in the **data dir** (`/opt/data/config.yaml`
> + `/opt/data/.env`, a bind mount) and Hermes loads it **itself at process start**. A
> `docker compose restart gateway` restarts that process, so it re-reads the freshly
> written data-dir files — there is **no compose-level env to re-evaluate**, so `up -d`
> (which would recreate the container) is unnecessary. The applier therefore uses
> `restart`. *Only* if you ever move a secret back into the compose
> `environment:`/`env_file:` (don't — the panel is the source of truth) would you need
> `up -d` so compose re-evaluates it. Hermes is pre-1.0: confirm `restart` picks up a
> panel-changed `.env` against the pinned image before baking the golden image.

## uid / perms decision for `./data`

The shared `./data` is mounted into **both** the agent (`/opt/data`) and the panel
(`/data`). The conflict to solve: the panel image defaults to **uid 10001** and chmods
the `.env` it writes to **0600 (owner-only)**, while Hermes runs as **HERMES_UID:GID
(default 10000:10000)** — so a panel-owned 0600 `.env` would be unreadable by the agent.

**Decision: run the panel as the agent's uid:gid.** `docker-compose.yml` sets
`user: "${HERMES_UID:-10000}:${HERMES_GID:-10000}"` on the `panel` service. Then:

- both processes are the **same uid**, so the panel's `0600 .env` is owned by — and
  readable by — the agent;
- `./data` has a **single owner** (`firstboot.sh` runs `chown -R 10000:10000 ./data`,
  `chmod 0750`), no group-writable bit, no setgid — minimal surface;
- the secret stays **owner-only** (no world/group read), which is the right posture for
  an API key.

The panel image is uid-agnostic (it only `chmod`s files it owns and needs no `$HOME`),
so running it as 10000 is safe. If you change `HERMES_UID/GID`, both services follow it
via the same `.env` variables.

## EXACT provider wiring

Two places under the **data dir** (`./data` → `/opt/data`), both pointing at the same
OpenAI-compatible gateway; the secret only ever lives in `./data/.env`. The **panel
writes both** when the client saves a key (avots is the default; the panel can rewrite
these for OpenAI/Anthropic). Neither is ever placed in the compose-level `/opt/hermes-vm/.env`.

**`./data/config.yaml` → `model:`** (non-secret settings; pre-seeded, panel-overwritten)

```yaml
model:
  provider: "custom"                          # any OpenAI-compatible endpoint
  default: "anthropic/claude-opus-4.8"        # avots default model
  base_url: "https://api.avots.ai/openai/v1"  # MUST end at /v1
  api_key: "${OPENAI_API_KEY}"                # expanded from .env (${VAR} syntax)
  context_length: 200000                      # safety net if /v1/models is silent
```

**`./data/.env`** (secret + env-var fallback path; written by the panel, chmod 0600,
owned by the agent uid — never committed, never in the compose-level `.env`)

```ini
OPENAI_API_KEY=av_mcp_<key>                    # the active ref used by config.yaml
OPENAI_BASE_URL=https://api.avots.ai/openai/v1
AVOTS_API_KEY=av_mcp_<key>                     # mirror; same key (harmless for non-avots)
TELEGRAM_BOT_TOKEN=123456:ABC-DEF...           # from @BotFather (panel-written)
TELEGRAM_ALLOWED_USERS=123456789,987654321     # comma-separated ids from @userinfobot
```

Auth sent on the wire: `Authorization: Bearer av_mcp_<key>`. Validated 2026-06-05.
Field provenance (re-verify against upstream when bumping the pin):
- `provider: custom` — upstream `cli-config.yaml.example`: *"`custom` - Any other
  OpenAI-compatible endpoint. Set base_url below."*
- `${VAR}` expansion + `OPENAI_BASE_URL`/`OPENAI_API_KEY` fallback — upstream
  `docs/reference/environment-variables.md`.

## Run steps (manual / first VM, without autoinstall)

```bash
cd /opt/hermes-vm
cp .env.example .env && edit .env       # set PANEL_PASSWORD ONLY; leave PANEL_DOMAIN blank
                                        # to auto-derive. Do NOT put provider/Telegram secrets here.
./firstboot.sh                          # data perms, derive domain, pull, up, install applier
docker compose logs -f gateway          # the agent is idle until the panel writes its config
```

Then open `https://vps-<o3>-<o4>.cloudhosting.lv`, log in with PANEL_PASSWORD, pick a
provider and paste the key, and enter the Telegram bot token + allowed user ids. The
panel writes `./data/config.yaml` + `./data/.env` and the applier restarts the agent —
**the panel is the only place these secrets are entered**. In production this is all done
by `autoinstall-snippet.yaml` + `firstboot.sh` on first boot (which sets only
PANEL_PASSWORD); you do not run it by hand.

## Security hardening checklist

The agent can run arbitrary commands/code. Critically, **Hermes skips dangerous-command
approval when its terminal/exec backend runs inside a container** (upstream: *"When
running in `docker`/`singularity`/`modal`/`daytona` backends, dangerous command checks
are skipped because the container itself is the security boundary."*). On this VM the
agent's default `local` backend executes inside the Hermes container, so **the VM and
its egress are the real security boundary**. Lock the box down:

- [x] **Pin a patched image by digest** — `nousresearch/hermes-agent:v2026.5.29.2`
      (= release v0.15.2) pinned with `@sha256:...`. Never `:latest`.
- [x] `security_opt: [no-new-privileges:true]` on **every** service (gateway, panel, caddy).
- [x] **No `docker.sock` mount** anywhere — the agent must never reach the host Docker.
      Docker control lives only in the host-side applier.
- [x] `cap_drop: [ALL]` (gateway/panel/caddy), `pids_limit`, CPU/memory limits, log rotation.
- [x] **Agent publishes no public ports.** Only Caddy is internet-facing (80/443).
      Panel is on the internal `web` network behind Caddy. Dashboard (if any) loopback-only.
- [x] **Panel is password-gated (fail closed).** `PANEL_PASSWORD` must be set or the
      panel refuses to start. The panel can set the client's API key, so it must never be open.
- [x] **TLS in front of the panel** via Caddy + Let's Encrypt (HSTS, no server banner,
      X-Frame-Options DENY, body-size cap).
- [x] **Set `TELEGRAM_ALLOWED_USERS`** (or set it via the panel) — without it, anyone who
      finds the bot can drive the agent. This is the inbound authorization control.
- [x] `approvals.mode: manual` in config (never `off`); do **not** enable YOLO.
- [ ] **Restrict outbound egress** at the VM/network level: allow only what the agent
      needs (the chosen provider, Telegram, package mirrors). This is the real mitigation
      for prompt-injection exfiltration, since in-container approval is skipped.
- [ ] Keep `/var/log/cloud-init-output.log` + autoinstall logs root-only (they can
      contain the rendered `.env`).
- [ ] **Patch + re-bake pipeline**: this project is pre-1.0 and ships releases/CVEs
      frequently. Re-check Docker Hub + GitHub releases and re-bake on each patch.

## Version-pin notes

- **Hermes** pinned: `nousresearch/hermes-agent:v2026.5.29.2` (release **v0.15.2**),
  newest patched release as of **2026-06-05**. Multi-arch index digest in compose:
  `sha256:2bba4ab37729ebdd864d4caf277b24fec4cd8bfc2855185fd9f4c90f9bf7bfa3`. Re-verify
  tag **and** digest before baking the golden image.
- **Caddy** pinned to `caddy:2.8-alpine`. Bump deliberately.
- **Panel** uses `ghcr.io/cloudhostinglv/ai-panel:latest` (public). For reproducible
  golden images, consider pinning it to a tag/digest too.

## Caveats / things to verify before baking

- **Hermes image is built/pushed under a Docker Hub account** (`nousresearch/hermes-agent`,
  pusher `definitelynotcthulhu`); there is currently **no GHCR mirror**. Confirm the
  publisher is trusted and consider mirroring the pinned digest into your own registry.
- **`context_length: 200000`** is a safety-net for Claude Opus 4.x; if avots' `/v1/models`
  advertises a window, Hermes auto-detects it. Confirm the right value per default model.
- **In-container approval is skipped** — the single most important reason egress
  restriction + VM lockdown are mandatory, not optional.
- **Dashboard PID-namespace coupling.** The optional dashboard must share the gateway's
  PID namespace (`pid: service:gateway` + `network_mode: service:gateway`); re-verify if enabled.
- **Live-VM items to confirm:** (1) HTTP-01 issuance actually succeeds for the derived
  `vps-<o3>-<o4>.cloudhosting.lv` (A-record present, ports 80/443 reachable, no upstream
  firewall); (2) `docker compose restart gateway` is enough for the agent to pick up a
  panel-changed `.env` (else switch the applier to `up -d`); (3) the `panel` running as
  uid 10000 can write `./data` and the agent reads the 0600 `.env`; (4) `ip route get`
  returns the public IPv4 the hostname encodes (not a NAT/private address).
