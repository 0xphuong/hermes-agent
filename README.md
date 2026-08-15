# hermes-agent

Docker Compose deployment for [Hermes Agent](https://hub.docker.com/r/nousresearch/hermes-agent).

The image is **stateless** — all state (config, API keys, sessions, memories, skills, logs) lives
under `/opt/data` in the container, mounted from `~/.hermes` on the host. Upgrading means pulling a
new image; nothing is lost.

---

## Quick install

```bash
curl -fsSL https://raw.githubusercontent.com/0xphuong/hermes-agent/main/install.sh | bash
```

Add flags after `--`:

```bash
curl -fsSL .../install.sh | bash -s -- --with-claude-code
```

The installer clones into a temporary directory, runs `setup.sh` there, and deletes the clone.
**Nothing is left on disk.** The containers keep running by themselves (`restart: unless-stopped`),
and day-to-day you talk to them through the `hermes` alias setup offers to add:

```bash
hermes                  # open the chat CLI
hermes status           # gateway status
hermes logs --follow    # live logs
```

That also means `docker compose` is not available afterwards — there is no compose file left to
point it at. Reinstall or uninstall by running the installer again. The compose project name is
pinned to `hermes-agent` in the file itself, so running from a throwaway directory does not name
the project after it.

> **Write the dashboard password down when setup prints it.** It lives in `.env`, which goes with
> the working directory. There is nowhere to look it up afterwards.

Pin the version with `HERMES_AGENT_REF=v1.2.3`, or keep the working directory for debugging with
`KEEP_DIR=1`.

> Piping a script from the internet into a shell runs it before you have read it. To look first:
> `curl -fsSL .../install.sh -o install.sh && less install.sh && bash install.sh`

### Requirements

Docker and the compose v2 plugin. The installer checks for them and, if either is missing on an
**apt** system, offers to install Docker CE from the official repository, start it, and add you to
the `docker` group. Everywhere else it says what is missing and stops rather than guessing.

Group membership only takes effect in a new login session, so a first install on a machine without
Docker ends by asking you to `newgrp docker` (or log out and back in) and run the installer again.

**Hermes alone is the default.** 9router (an LLM router) and headroom are optional extras; setup
asks once whether you want them, and the answer is No unless you say otherwise. Skip the question
with `--with-router` / `--without-router`.

setup.sh creates the data directories, runs the hermes setup wizard, does `docker compose up -d`,
then prints the URLs and access details. Both scripts are safe to re-run — `.env` and `9router.env`
are never copied over or regenerated, so existing secrets survive, and an install that already has
9router keeps it.

Prefer to keep the repo? The old flow still works:

```bash
git clone git@github-0xphuong:0xphuong/hermes-agent.git
cd hermes-agent && ./setup.sh
```

**Internal secrets** (`HERMES_DASHBOARD_SECRET`, and `JWT_SECRET` / `API_KEY_SECRET` /
`MACHINE_ID_SALT` when 9router is installed) are generated automatically, with no prompt.

**Login passwords** — the dashboard, plus 9router if you install it — are prompted for (typed twice,
not echoed). Press Enter to skip and get a random string instead.

> Passwords must not contain `$`. Docker Compose reads it as a variable and swallows the rest —
> `ab$cde` arrives in the container as `ab`, with no error anywhere. The script rejects it at the
> prompt.

| Option | Effect |
|---|---|
| `--with-router` | Install 9router + headroom too, no prompt |
| `--without-router` | Hermes only, no prompt |
| `--with-claude-code` | Build the image from `Dockerfile` — the `claude` CLI plus the supervised claude-proxy service — instead of using the official one |
| `--no-start` | Only write the config files, do not start anything |
| `--non-interactive` | Prompt for nothing (implies hermes only) |
| `--help` | Show usage |

### Adding or removing 9router later

The two extra services sit behind a compose **profile**. Setup writes `COMPOSE_PROFILES` into the
`.env` it hands to compose, so the choice is made at install time:

```bash
# add them
curl -fsSL .../install.sh | bash -s -- --with-router

# drop them again
curl -fsSL .../install.sh | bash -s -- --uninstall --yes
curl -fsSL .../install.sh | bash -s -- --without-router
```

`COMPOSE_PROFILES` is written into `.env` during the install and read by the compose CLI itself, so
setup never has to remember `--profile`. A hermes-only install never creates `9router.env`, which is
why the compose file marks that `env_file` as `required: false`: without it, even
`docker compose ps` would fail over a file belonging to a service that is deliberately not running.

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

## Uninstall

There is no local script to run — it went with the working directory. Reach it the way you
installed:

```bash
curl -fsSL .../install.sh | bash -s -- --uninstall           # containers only; data stays
curl -fsSL .../install.sh | bash -s -- --uninstall --purge   # + data + images
```

| Flag | Also removes |
|---|---|
| *(none)* | The containers, and the `hermes` shell alias |
| `--data` | `~/.hermes` and `~/.9router` — config, sessions, memories, **and the claude login** |
| `--images` | The hermes, 9router and headroom images |
| `--purge` | Both of the above |
| `--yes` | Skip the confirmation |

The default leaves every byte of state on disk, so reinstalling picks up where it left off.
Anything that deletes data asks you to type `delete` in full — not `y`.

The `hermes` alias goes with the containers it points at — leaving it behind would just fail with
"No such container". Every candidate rc file is checked (`.zshrc`, `.bashrc`, `.profile`), not only
the current shell's, since the install may have run under a different one. It is still live in the
shell you are sitting in until you `unalias hermes` or open a new one.

It always tears down with `--profile router`, whatever `COMPOSE_PROFILES` said: a deployment that
switched the profile off leaves 9router and headroom running but invisible to a bare
`docker compose down`, and uninstall is exactly the moment they must not be missed.

---

## Access

| Service | Address | Notes |
|---|---|---|
| Dashboard | `http://127.0.0.1:9119` | Log in with `HERMES_DASHBOARD_USER` / `_PASSWORD` |
| API (OpenAI-compatible) | `http://127.0.0.1:8642` | Only works once `API_SERVER_*` is enabled |
| 9router | `http://127.0.0.1:20128` | Only with `COMPOSE_PROFILES=router`; internally `http://9router:20128` |
| claude-proxy | `http://localhost:8082` | **Inside the hermes container only**, never published |

Everything **binds to host loopback by default**. Reach the dashboard from another machine over an
SSH tunnel:

```bash
ssh -L 9119:127.0.0.1:9119 user@host
# then open http://127.0.0.1:9119 locally
```

### Exposing it externally

Setup asks at install time — there is no `.env` left on disk to edit afterwards:

```
  Who can reach the dashboard?
    1  127.0.0.1  this host only — reach it over an SSH tunnel (default)
    2  0.0.0.0    anything that can route to this machine
```

Or skip the question by setting it in the environment:

```bash
HERMES_BIND_ADDR=0.0.0.0 bash -c 'curl -fsSL .../install.sh | bash'
```

Before picking 2, understand this:

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

With the `hermes` alias setup installs (`alias hermes="docker exec -it hermes hermes"`):

```bash
hermes                  # open the chat CLI
hermes status           # reports "Manager: s6 (container supervisor)"
hermes logs --follow    # structured Hermes logs
```

`docker compose` is not available after an install — there is no compose file left on disk. Use
docker directly:

```bash
docker logs -f hermes   # container stdout (gateway + dashboard)
docker restart hermes
docker ps
```

`docker exec hermes ...` automatically drops from root to the `hermes` user (UID 10000), so files it
creates get the right ownership — no `--user` needed.

### Where the logs are

| Source | Location |
|---|---|
| Gateway + dashboard, live | `docker logs -f hermes` (rotated 20MB × 5, lost on `docker rm`) |
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

A running gateway **comes back on its own** after `docker restart hermes` or an image upgrade. Only
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

Re-run the installer; it pulls, rebuilds and recreates the containers:

```bash
curl -fsSL .../install.sh | bash -s -- --with-claude-code
```

The data directory is left alone. The container runs config-schema migrations itself and writes
timestamped backups next to `config.yaml` / `.env` before touching them. To inspect the changes
first, add `HERMES_SKIP_CONFIG_MIGRATION=1` to `environment:`.

In production, pin `HERMES_IMAGE_TAG` to a specific version instead of `latest`.

---

## Backup

All state lives in bind-mounted directories; there are no named volumes:

```bash
docker stop hermes
sudo tar czf hermes-backup-$(date +%F).tar.gz -C ~ .hermes           # hermes only
sudo tar czf hermes-backup-$(date +%F).tar.gz -C ~ .hermes .9router  # with 9router
docker start hermes
```

`sudo` because the runtime chowns `~/.hermes` to UID 10000 mode 0700 — your own user cannot read
it. The `claude` login and its session transcripts are inside, so this covers them too.

The `claude` CLI's login and session transcripts are inside `.hermes` (the container's
`/opt/data`), so they come back with it.

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

### claude-proxy — running the `claude` CLI inside the hermes container

Built from `./Dockerfile` (installer flag `--with-claude-code`), which adds three things to the published
hermes image: the `claude` CLI, `claude_proxy/server.py` fetched from
[`0xphuong/claude-cli-adapter`](https://github.com/0xphuong/claude-cli-adapter), and an s6 service
that supervises it. The proxy wraps the local CLI in an **Anthropic Messages API** — `POST
/v1/messages`, `GET /v1/models`, `GET /health`, and nothing else.

It listens on `127.0.0.1:8082` **inside the hermes container**, so hermes reaches it with no network
hop and nothing published to the host.

Set this in `~/.hermes/config.yaml` by hand — setup prints the block at the end of an install.

**The short form.** Override the built-in `anthropic` provider and point it at the proxy:

```yaml
model:
  default: claude-opus-4-6
  provider: anthropic
providers:
  anthropic:
    api_key: dummy                       # required by the SDK, ignored by the proxy
    base_url: http://127.0.0.1:8082/v1
    default_model: claude-sonnet-4-6
```

The base_url has to live under `providers.anthropic`, not `model.base_url` — hermes ignores the
latter for the `anthropic` provider and calls api.anthropic.com regardless, which looks exactly like
the proxy being bypassed.

**The long form**, if you would rather leave the `anthropic` provider untouched and declare a
separate one:

```yaml
model:
  default: claude-sonnet-4-6
  provider: local                        # must name an entry in custom_providers
  base_url: http://127.0.0.1:8082/v1
  api_key: dummy
  api_mode: anthropic_messages           # NOT chat_completions

custom_providers:
  - name: local
    base_url: http://127.0.0.1:8082/v1
    model: claude-sonnet-4-6
    api_mode: anthropic_messages
```

Whichever you pick, two things are easy to get wrong:

- `api_mode` **must** be `anthropic_messages` wherever it appears. The proxy serves `/v1/messages`
  only, so `chat_completions` 404s every single call.
- `provider:` and the block it names have to agree. `provider: local` with no `custom_providers`
  entry called `local` fails at startup.

`config.yaml` is inside the container, and `/opt/data` is mode 0700 owned by UID 10000 — your own
user cannot even read it from the host. Edit it from inside:

```bash
docker exec -it -u hermes hermes vi /opt/data/config.yaml
docker restart hermes
```

Verify a model name before wiring it in — `claude --model <id>` accepts `sonnet`, `opus`,
`claude-sonnet-4-6` and other aliases, but not every string that looks valid. Check one with:

```bash
docker exec -u hermes hermes claude -p "hi" --model claude-sonnet-4-6 --output-format json
```

The `claude` CLI it drives uses the subscription login stored at `/opt/data/.claude`. Log in once:

```bash
docker exec -it -u hermes hermes claude
```

That path is on the `/opt/data` volume, so the login and the CLI's session transcripts survive
container recreates — and the proxy's `--resume` needs both.

> **Do not set `CLAUDE_PROXY_UPSTREAM_URL` / `_TOKEN` to a namespacing router.** They point the CLI
> at a gateway instead of api.anthropic.com. The CLI expands `--model sonnet` into
> `claude-sonnet-5`; a router that serves `cc/claude-sonnet-5` does not have that name, so every
> call 404s and it reads as a broken proxy. Leave both empty for the subscription.

Service controls, all inside the container:

```bash
docker exec hermes /command/s6-svstat /run/service/claude-proxy   # up/down + uptime
docker exec hermes curl -s http://127.0.0.1:8082/health
docker logs -f hermes | grep -i proxy                              # it logs to stdout
```

Set `CLAUDE_PROXY_ENABLED=0` to leave the slot supervised but down.

#### Smoke-testing the proxy

Everything runs inside the hermes container, so every command goes through `docker exec`:

```bash
# 1. Liveness
docker exec hermes curl -s http://127.0.0.1:8082/health

# 2. Model list (a hardcoded stub — it does not reflect what the CLI can reach)
docker exec hermes curl -s http://127.0.0.1:8082/v1/models

# 3. A real completion. The first call for a given system+tools fingerprint
#    bootstraps a claude session and pays full price; later calls reuse it and
#    read from cache. Expect tens of seconds either way, not milliseconds.
docker exec hermes curl -s -X POST http://127.0.0.1:8082/v1/messages \
  -H 'content-type: application/json' \
  -d '{"model":"claude-sonnet-4-6","max_tokens":64,
       "messages":[{"role":"user","content":"Reply with exactly: PONG"}]}'
```

If step 3 fails while step 1 works, the problem is the CLI rather than the proxy. Run it directly to
see the real error, which the proxy only forwards as an opaque 502:

```bash
docker exec -u hermes hermes claude -p "hi" --output-format json
```

A 404 on every model usually means `CLAUDE_PROXY_UPSTREAM_URL` is pointing the CLI at a router that
namespaces its models. Empty is the right value for the subscription.

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
| Container exits immediately | `docker logs hermes` — usually `setup` was never run, or a port is taken |
| `Permission denied` on `~/.hermes` | The runtime is UID 10000. Set `HERMES_PUID`/`HERMES_PGID` to match the directory owner (`id -u`, `id -g`) |
| Browser tools fail silently | Missing shared memory — compose sets `shm_size: 1gb`, check nothing overrides it |
| Dashboard unreachable | It is bound to loopback by design — use an SSH tunnel |
| Gateway stuck after a network incident | `docker restart hermes` |

Check the image version: `docker run --rm nousresearch/hermes-agent:latest version`

---

## Warnings

**Never run two Hermes containers against the same data directory.** Session files and the memory
store do not support concurrent writes — the data will be corrupted.

**Never commit `.env`.** It is already in `.gitignore`.
