# hermes-agent

Docker Compose deployment for [Hermes Agent](https://hub.docker.com/r/nousresearch/hermes-agent).

The image is **stateless** — all state (config, API keys, sessions, memories, skills, logs) lives
under `/opt/data` in the container, mounted from `~/.hermes` on the host. Upgrading means pulling a
new image; nothing is lost.

---

## Quick install

```bash
git clone git@github-0xphuong:0xphuong/hermes-agent.git
cd hermes-agent
./setup.sh
```

The script creates the data directories, runs the hermes setup wizard, does `docker compose up -d`,
then prints the URLs and access details. It is safe to re-run — existing values are never
overwritten.

**Internal secrets** (`HERMES_DASHBOARD_SECRET`, `JWT_SECRET`, `API_KEY_SECRET`, `MACHINE_ID_SALT`)
are generated automatically, with no prompt.

**Login passwords** — dashboard and 9router — are prompted for (typed twice, not echoed). Press
Enter to skip and get a random string instead.

> Passwords must not contain `$`. Docker Compose reads it as a variable and swallows the rest —
> `ab$cde` arrives in the container as `ab`, with no error anywhere. The script rejects it at the
> prompt.

| Option | Effect |
|---|---|
| `--with-claude-code` | Build the image from `Dockerfile` (bundles the `claude` CLI) instead of using the official one |
| `--no-start` | Only write the config files, do not start anything |
| `--non-interactive` | Prompt for nothing, generate the login passwords too (for CI) |
| `--help` | Show usage |

The rest of this document describes the manual steps the script performs for you.

---

## First install (manual)

### 1. Prepare

```bash
git clone git@github-0xphuong:0xphuong/hermes-agent.git
cd hermes-agent
cp .env.example .env
```

Generate two secrets and fill them into `.env`:

```bash
openssl rand -hex 32   # -> HERMES_DASHBOARD_PASSWORD
openssl rand -hex 32   # -> HERMES_DASHBOARD_SECRET
```

### 2. Run the setup wizard

The wizard asks for model API keys and chat-platform tokens, and writes them to `~/.hermes/.env`.
It only needs to run **once**:

```bash
mkdir -p ~/.hermes
docker run -it --rm -v ~/.hermes:/opt/data nousresearch/hermes-agent setup
```

> **Do not run this from a VPS browser console** (Hetzner and many other providers). Web consoles
> mistransmit special characters — `:` becomes `;`, `@` renders wrong — silently corrupting both the
> `-v ~/.hermes:/opt/data` argument and any API key you paste. Use SSH: `ssh root@<host>`.

If you use Nous Portal, also run (the refresh token persists in the volume):

```bash
docker run -it --rm -v ~/.hermes:/opt/data nousresearch/hermes-agent setup --portal
```

### 3. Start

```bash
docker compose up -d
docker compose logs -f
```

---

## Access

| Service | Address | Notes |
|---|---|---|
| Dashboard | `http://127.0.0.1:9119` | Log in with `HERMES_DASHBOARD_USER` / `_PASSWORD` |
| API (OpenAI-compatible) | `http://127.0.0.1:8642` | Only works once `API_SERVER_*` is enabled |
| 9router | `http://127.0.0.1:20128` | Router UI; on the internal network it is `http://9router:20128` |
| claude-cli-adapter | `http://127.0.0.1:8082` | **No auth** — see the section below |

Everything **binds to host loopback by default**. Reach the dashboard from another machine over an
SSH tunnel:

```bash
ssh -L 9119:127.0.0.1:9119 user@host
# then open http://127.0.0.1:9119 locally
```

### Exposing it externally

Set `HERMES_BIND_ADDR=0.0.0.0` in `.env`. Before you do, understand this:

A public dashboard with **no auth** was the entry point for the June 2026 MCP-config persistence
campaign — internet scanners found exposed dashboards and drove the agent into installing an SSH-key
backdoor. This compose file ships basic auth configured, so the gate is always on, but basic auth is
**not enough** for the public internet. For a public deploy use OAuth (Nous Portal:
`HERMES_DASHBOARD_OAUTH_CLIENT_ID`) or self-hosted OIDC (`HERMES_DASHBOARD_OIDC_ISSUER` +
`_CLIENT_ID`), or leave it on loopback and reach it over VPN/Tailscale.

`HERMES_DASHBOARD_INSECURE` has been disabled upstream — there is no longer any way to turn auth off
on a non-loopback bind.

---

## Day-to-day operation

```bash
docker compose logs -f                    # live logs (gateway + dashboard)
docker compose restart                    # restart the whole container
docker compose ps                         # status

docker exec hermes hermes logs --follow   # structured Hermes logs
docker exec hermes hermes status          # reports "Manager: s6 (container supervisor)"
docker exec -it hermes hermes             # open the chat CLI inside the running container
```

`docker exec hermes ...` automatically drops from root to the `hermes` user (UID 10000), so files it
creates get the right ownership — no `--user` needed.

### Where the logs are

| Source | Location |
|---|---|
| Gateway + dashboard, live | `docker compose logs -f` (rotated 20MB × 5, lost on `docker rm`) |
| Gateway, durable per profile | `~/.hermes/logs/gateways/<profile>/current` (rotated 10 × 1MB) |
| Container boot audit | `~/.hermes/logs/container-boot.log` |
| `agent.log`, `errors.log` | `~/.hermes/logs/` |

Only files on the volume survive `docker rm`.

---

## Multi-profile

One container runs any number of independent profiles (separate SOUL, skills, memory, sessions).
Each profile is a supervised s6 service that restarts on crash — **no extra container needed**:

```bash
docker exec hermes hermes profile create coder
docker exec hermes hermes -p coder gateway start
docker exec hermes hermes -p coder gateway status
docker exec hermes hermes profile delete coder
```

A running gateway **comes back on its own** after `docker compose restart` or an image upgrade. Only
an explicit `hermes gateway stop` keeps it down across restarts.

**The dashboard needs a single port for all profiles** — the profile switcher in the UI sends the
target profile along with each request.

**OpenAI-compatible clients are different:** every profile has its own API server and they all
default to port 8642, so they collide. Give each one its own port in *that profile's* `.env`:

```bash
docker exec hermes hermes profile create work
cat >> ~/.hermes/profiles/work/.env <<'EOF'
API_SERVER_ENABLED=true
API_SERVER_PORT=8643
EOF
docker exec hermes hermes -p work gateway restart
```

Then publish `- "127.0.0.1:8643:8643"` in `docker-compose.yml`.

> Never put `API_SERVER_PORT` in the compose `environment:` block — a global value forces every
> profile onto the same port.

---

## Upgrading

```bash
docker compose pull
docker compose up -d
```

The data directory is left alone. The container runs config-schema migrations itself and writes
timestamped backups next to `config.yaml` / `.env` before touching them. To inspect the changes
first, add `HERMES_SKIP_CONFIG_MIGRATION=1` to `environment:`.

In production, pin `HERMES_IMAGE_TAG` to a specific version instead of `latest`.

---

## Backup

All state lives in bind-mounted directories; there are no named volumes:

```bash
docker compose stop
tar czf hermes-backup-$(date +%F).tar.gz -C ~ .hermes .9router .claude-adapter
docker compose start
```

After restoring, put the ownership back: `sudo chown -R 10001:10001 ~/.claude-adapter`.

---

## Further configuration

`config.yaml` lives at `~/.hermes/config.yaml`.

### Tool-loop circuit breaker for unattended gateways

By default Hermes only warns when an agent gets stuck in a tool-call loop — reasonable for a CLI with
someone watching, useless for a gateway running unattended. Enable the circuit breaker:

```yaml
tool_loop_guardrails:
  hard_stop_enabled: true
  hard_stop_after:
    exact_failure: 5
    idempotent_no_progress: 5
```

### Pointing at a local inference server (vLLM / Ollama)

Server running on **this host** (Linux):

```yaml
model:
  provider: custom
  model: my-model
  base_url: http://172.17.0.1:8000/v1   # docker0 gateway; host.docker.internal on macOS
  api_key: "none"
```

Server running in **another container**: put both on the same network and use the **container name**
as the hostname (`http://vllm:8000/v1`) — not `localhost`, which is the Hermes container itself. No
trailing `/` on `base_url`. `model` must match `--served-model-name`.

Check it: `docker exec hermes curl -s http://vllm:8000/v1/models`

### claude-cli-adapter

The `claude-cli-adapter` container wraps the `claude` CLI in an Anthropic/OpenAI-style HTTP API. It
sits on the same `hermes-net` network, so it is reachable by container name — point Hermes at it like
any other provider:

```yaml
model:
  provider: custom
  model: cc/claude-sonnet-5
  base_url: http://claude-cli-adapter:8082/v1
  api_key: "none"
```

The adapter's default backend is 9router (`http://9router:20128`), which needs
`ADAPTER_ANTHROPIC_AUTH_TOKEN` in `.env` — an API key generated in the 9router UI. To use a
subscription instead of a token, clear that value and set `ADAPTER_CLAUDE_CODE_OAUTH_TOKEN`
(generated with `claude setup-token`). Setting `ADAPTER_ANTHROPIC_AUTH_TOKEN` and
`ADAPTER_ANTHROPIC_API_KEY` at the same time makes the container **refuse to start** — the CLI would
send two auth headers.

> The adapter has **no authentication of its own**: it ignores the API key and serves anyone who can
> reach it. That is why `ADAPTER_BIND_ADDR` is a separate variable, deliberately decoupled from
> `HERMES_BIND_ADDR` — opening the dashboard to the LAN must not drag the adapter along. Only set it
> to `0.0.0.0` behind a reverse proxy that authenticates.

The `claude` CLI's state (credentials + `.claude.json`) lives in `ADAPTER_DATA_DIR`, default
`~/.claude-adapter`, mounted at `/home/app`. The container runs as **UID 10001** and has **no
`PUID`/`PGID`** like hermes does — it starts directly as the `app` user, so it cannot chown anything
itself. On Linux that directory must be owned by `10001:10001`:

```bash
sudo chown -R 10001:10001 ~/.claude-adapter
```

`setup.sh` handles this (asking for sudo if needed). Skip it and Claude Code cannot write its
credentials, failing with a very unhelpful permission error. On macOS, Docker Desktop maps ownership
for you and this is unnecessary.

Source lives in its own repo,
[`0xphuong/claude-cli-adapter`](https://github.com/0xphuong/claude-cli-adapter); this compose file
only runs the published image. To build from source, use the compose file in that repo.

---

## Installing extra tools in the container

`/opt/hermes` is an **immutable** install tree, read-only to the runtime. Everything mutable belongs
under `/opt/data`.

- **npm / PyPI** → tell Hermes to run it through `npx` / `uvx` and to remember the command in memory.
  Config goes under `/opt/data/<tool>/`.
- **apt packages / binaries** → teach Hermes the install command and have it remember. Lasts as long
  as the container does.
- **Must be present on every start** → build a derived image `FROM nousresearch/hermes-agent:latest`,
  `USER root` → install → `USER hermes`. Then change `image:` in the compose file.
- **Tools that need their own service** (DB, queue) → run a sidecar on the same network and call it
  by container name.

CLI skills that store credentials under `~` must be initialised with the subprocess's real HOME. For
example, `xurl`:

```bash
docker exec -it hermes env HOME=/opt/data/home xurl auth
docker exec hermes env HOME=/opt/data/home xurl auth status
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Compose says `required variable ... is missing` | You skipped `cp .env.example .env`, or left the dashboard credentials blank |
| Container exits immediately | `docker compose logs` — usually `setup` was never run, or a port is taken |
| `Permission denied` on `~/.hermes` | The runtime is UID 10000. Set `HERMES_PUID`/`HERMES_PGID` to match the directory owner (`id -u`, `id -g`) |
| Browser tools fail silently | Missing shared memory — compose sets `shm_size: 1gb`, check nothing overrides it |
| Dashboard unreachable | It is bound to loopback by design — use an SSH tunnel |
| Gateway stuck after a network incident | `docker compose restart` |

Check the image version: `docker run --rm nousresearch/hermes-agent:latest version`

---

## Warnings

**Never run two Hermes containers against the same data directory.** Session files and the memory
store do not support concurrent writes — the data will be corrupted.

**Never commit `.env`.** It is already in `.gitignore`.
