#!/usr/bin/env bash
#
# One-shot setup for the hermes-agent + 9router + headroom stack.
# Idempotent: re-running never overwrites a secret that already exists.
#
#   ./setup.sh                     # set up + up -d
#   ./setup.sh --with-claude-code  # build an image with the `claude` CLI from Dockerfile
#   ./setup.sh --no-start          # only write the config files, do not start
#   ./setup.sh --non-interactive   # prompt for nothing, generate the login passwords too
#   ./setup.sh --help
#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

WITH_CLAUDE_CODE=0
NO_START=0
NON_INTERACTIVE=0

# ---------------------------------------------------------------- output ----
if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''
fi

info() { printf '%s==>%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s  !!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%s error:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

usage() {
  sed -n '3,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

# ------------------------------------------------------------------ args ----
while [ $# -gt 0 ]; do
  case "$1" in
    --with-claude-code) WITH_CLAUDE_CODE=1 ;;
    --no-start)         NO_START=1 ;;
    --non-interactive)  NON_INTERACTIVE=1 ;;
    -h|--help)          usage ;;
    *)                  die "invalid argument: $1  (see --help)" ;;
  esac
  shift
done

# --------------------------------------------------------------- helpers ----

# Write KEY=VALUE into a .env file — replacing the existing line, or appending.
# Uses awk rather than `sed -i` so it works on both macOS and GNU.
set_kv() {
  local file="$1" key="$2" val="$3" tmp
  tmp="$(mktemp)"
  awk -v k="$key" -v v="$val" '
    $0 ~ "^" k "=" { print k "=" v; found = 1; next }
    { print }
    END { if (!found) print k "=" v }
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}

get_kv() {
  [ -f "$2" ] || return 0
  grep -E "^$1=" "$2" 2>/dev/null | head -1 | cut -d= -f2- || true
}

# Fill in a random secret if the key is empty. Returns 0 if one was generated.
fill_secret() {
  local file="$1" key="$2" val
  val="$(get_kv "$key" "$file")"
  if [ -z "$val" ]; then
    set_kv "$file" "$key" "$(openssl rand -hex 32)"
    return 0
  fi
  return 1
}

# Prompt for a login password, typed twice to confirm, never echoed.
# Prompts go to stderr and only the result to stdout, so callers can capture it
# with $(). The result is prefixed: `usr:` = typed by the user, `gen:` = random.
# (The function runs in a subshell and cannot set globals — it has to report
# that fact through stdout.)
# An empty Enter means "generate a random one".
prompt_password() {
  local label="$1" min="${2:-8}" p1 p2 tries=0

  # No TTY, or --non-interactive: generate silently instead of asking.
  if [ "$NON_INTERACTIVE" = 1 ] || [ ! -r /dev/tty ]; then
    printf 'gen:%s\n' "$(openssl rand -hex 16)"
    return 0
  fi

  while :; do
    # Guard against an infinite loop if stdin closes mid-way.
    tries=$((tries + 1))
    if [ "$tries" -gt 5 ]; then
      printf '    %s!!%s 5 invalid attempts — giving up\n' "$C_RED" "$C_RESET" >&2
      return 1
    fi

    printf '    %s%s%s (Enter = generate a random one): ' "$C_BOLD" "$label" "$C_RESET" >&2
    IFS= read -rs p1 < /dev/tty || true
    printf '\n' >&2

    if [ -z "$p1" ]; then
      printf 'gen:%s\n' "$(openssl rand -hex 16)"
      return 0
    fi

    # Docker compose reads `$` in .env as a variable and swallows the rest —
    # `ab$cde` reaches the container as `ab`. Reject it instead of escaping.
    case "$p1" in
      *'$'*)  printf '    %s!!%s no $ character (docker compose reads it as a variable)\n' \
                "$C_YELLOW" "$C_RESET" >&2; continue ;;
      *'`'*)  printf '    %s!!%s no ` character\n' "$C_YELLOW" "$C_RESET" >&2; continue ;;
      ' '*|*' ') printf '    %s!!%s no leading or trailing whitespace\n' \
                "$C_YELLOW" "$C_RESET" >&2; continue ;;
    esac

    if [ "${#p1}" -lt "$min" ]; then
      printf '    %s!!%s minimum %s characters (got %s)\n' \
        "$C_YELLOW" "$C_RESET" "$min" "${#p1}" >&2
      continue
    fi

    printf '    Type it again to confirm: ' >&2
    IFS= read -rs p2 < /dev/tty || true
    printf '\n' >&2

    if [ "$p1" != "$p2" ]; then
      printf '    %s!!%s the two entries do not match, try again\n' "$C_YELLOW" "$C_RESET" >&2
      continue
    fi

    printf 'usr:%s\n' "$p1"
    return 0
  done
}

# The shell does not expand `~` when it arrives from a variable — do it by hand.
expand_tilde() {
  case "$1" in
    "~")   printf '%s\n' "$HOME" ;;
    "~"/*) printf '%s\n' "$HOME/${1#\~/}" ;;
    *)     printf '%s\n' "$1" ;;
  esac
}

# ------------------------------------------------------------- preflight ----
info "Checking the environment"

command -v docker  >/dev/null 2>&1 || die "docker is not installed"
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"
docker compose version >/dev/null 2>&1 || die "docker compose v2 (the plugin) is required, not docker-compose v1"
docker info >/dev/null 2>&1 || die "the docker daemon is not running"

for f in docker-compose.yml .env.example 9router.env.example; do
  [ -f "$f" ] || die "missing $f — run this script from inside the repo directory"
done
ok "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null), compose $(docker compose version --short)"

# ------------------------------------------------------------------ .env ----
info "Preparing .env (hermes config)"

if [ ! -f .env ]; then
  cp .env.example .env
  ok "created .env from .env.example"
else
  ok ".env already exists — keeping the current values"
fi

# Session-signing secret — nobody types this, generate it.
fill_secret .env HERMES_DASHBOARD_SECRET && ok "generated HERMES_DASHBOARD_SECRET"

# Dashboard login account — ask the user.
DASH_PASS_PROMPTED=0
if [ -z "$(get_kv HERMES_DASHBOARD_PASSWORD .env)" ]; then
  printf '\n  %sHermes dashboard login%s\n' "$C_BOLD" "$C_RESET"

  if [ "$NON_INTERACTIVE" = 0 ] && [ -r /dev/tty ]; then
    printf '    Username [admin]: ' >&2
    IFS= read -r dash_user < /dev/tty || true
    set_kv .env HERMES_DASHBOARD_USER "${dash_user:-admin}"
  else
    [ -n "$(get_kv HERMES_DASHBOARD_USER .env)" ] || set_kv .env HERMES_DASHBOARD_USER admin
  fi

  dash_raw="$(prompt_password 'Password' 8)" \
    || die "could not set a dashboard password — run setup.sh again"
  case "$dash_raw" in
    usr:*) dash_pass="${dash_raw#usr:}"; DASH_PASS_PROMPTED=1 ;;
    gen:*) dash_pass="${dash_raw#gen:}"; DASH_PASS_PROMPTED=0 ;;
    *)     die "prompt_password returned something unexpected — script bug" ;;
  esac
  [ -n "$dash_pass" ] || die "empty dashboard password — run setup.sh again"
  set_kv .env HERMES_DASHBOARD_PASSWORD "$dash_pass"
  [ "$DASH_PASS_PROMPTED" = 1 ] && ok "dashboard password set" \
                               || ok "generated a dashboard password"
  printf '\n'
else
  ok "HERMES_DASHBOARD_PASSWORD already set — leaving it alone"
  [ -n "$(get_kv HERMES_DASHBOARD_USER .env)" ] || set_kv .env HERMES_DASHBOARD_USER admin
fi

# ----------------------------------------------------------- 9router.env ----
info "Preparing 9router.env"

if [ ! -f 9router.env ]; then
  cp 9router.env.example 9router.env
  ok "created 9router.env from 9router.env.example"
else
  ok "9router.env already exists — keeping the current values"
fi

# Internal secrets — generated.
fill_secret 9router.env JWT_SECRET      && ok "generated JWT_SECRET"
fill_secret 9router.env API_KEY_SECRET  && ok "generated API_KEY_SECRET"
fill_secret 9router.env MACHINE_ID_SALT && ok "generated MACHINE_ID_SALT"

# 9router login password — ask the user.
ROUTER_PASS_PROMPTED=0
if [ -z "$(get_kv INITIAL_PASSWORD 9router.env)" ]; then
  printf '\n  %s9router login password%s\n' "$C_BOLD" "$C_RESET"
  router_raw="$(prompt_password 'Password' 8)" \
    || die "could not set a 9router password — run setup.sh again"
  case "$router_raw" in
    usr:*) router_pass="${router_raw#usr:}"; ROUTER_PASS_PROMPTED=1 ;;
    gen:*) router_pass="${router_raw#gen:}"; ROUTER_PASS_PROMPTED=0 ;;
    *)     die "prompt_password returned something unexpected — script bug" ;;
  esac
  [ -n "$router_pass" ] || die "empty 9router password — run setup.sh again"
  set_kv 9router.env INITIAL_PASSWORD "$router_pass"
  [ "$ROUTER_PASS_PROMPTED" = 1 ] && ok "9router password set" \
                                 || ok "generated a 9router password"
  printf '\n'
else
  ok "INITIAL_PASSWORD already set — leaving it alone"
fi

chmod 600 .env 9router.env 2>/dev/null || true

# ------------------------------------------------------------- data dirs ----
info "Creating the data directories"

HERMES_DATA_DIR="$(expand_tilde "$(get_kv HERMES_DATA_DIR .env)")"
ROUTER_DATA_DIR="$(expand_tilde "$(get_kv ROUTER_DATA_DIR .env)")"
ADAPTER_DATA_DIR="$(expand_tilde "$(get_kv ADAPTER_DATA_DIR .env)")"
: "${HERMES_DATA_DIR:=$HOME/.hermes}"
: "${ROUTER_DATA_DIR:=$HOME/.9router}"
: "${ADAPTER_DATA_DIR:=$HOME/.claude-adapter}"

mkdir -p "$HERMES_DATA_DIR" "$ROUTER_DATA_DIR" "$ADAPTER_DATA_DIR"
ok "$HERMES_DATA_DIR"
ok "$ROUTER_DATA_DIR"
ok "$ADAPTER_DATA_DIR"

# The adapter container starts directly as the `app` user (UID 10001) and has NO
# PUID/PGID like hermes, so it cannot chown anything itself. If the host directory
# belongs to someone else, Claude Code cannot write its credentials and fails with
# a very unhelpful permission error.
# macOS: Docker Desktop maps bind-mount ownership, so chown is both useless and
# likely to fail.
if [ "$(uname -s)" = "Linux" ] && [ "$(stat -c '%u' "$ADAPTER_DATA_DIR")" != "10001" ]; then
  if chown -R 10001:10001 "$ADAPTER_DATA_DIR" 2>/dev/null; then
    ok "chown 10001:10001 $ADAPTER_DATA_DIR"
  elif [ "$NON_INTERACTIVE" = 0 ] && [ -r /dev/tty ] \
       && sudo chown -R 10001:10001 "$ADAPTER_DATA_DIR" </dev/tty; then
    ok "chown 10001:10001 $ADAPTER_DATA_DIR (via sudo)"
  else
    warn "$ADAPTER_DATA_DIR is not owned by UID 10001 — the adapter cannot store credentials"
    warn "  run:  sudo chown -R 10001:10001 $ADAPTER_DATA_DIR"
  fi
fi

# ----------------------------------------------------- claude-code build ----
OVERRIDE_FILE=docker-compose.override.yml

if [ "$WITH_CLAUDE_CODE" = 1 ]; then
  [ -f Dockerfile ] || die "--with-claude-code needs the Dockerfile"
  cat > "$OVERRIDE_FILE" <<'YAML'
# Generated by setup.sh --with-claude-code. This file is git-ignored.
services:
  hermes:
    build: .
    image: hermes-claude:latest
YAML
  ok "created $OVERRIDE_FILE — hermes will build from Dockerfile (with the claude CLI)"
elif [ -f "$OVERRIDE_FILE" ] && grep -q 'setup.sh --with-claude-code' "$OVERRIDE_FILE" 2>/dev/null; then
  ok "$OVERRIDE_FILE already exists — still building the image with the claude CLI"
fi

# ------------------------------------------------------------ validate -----
info "Validating docker-compose.yml"
docker compose config >/dev/null || die "docker-compose.yml is invalid (see the error above)"
ok "config is valid"

if [ "$NO_START" = 1 ]; then
  printf '\n%sConfig files written. Drop --no-start to bring the stack up.%s\n' "$C_BOLD" "$C_RESET"
  exit 0
fi

# --------------------------------------------------------- hermes wizard ----
# The wizard asks for model API keys and chat-platform tokens and writes them to
# $HERMES_DATA_DIR/.env. It only needs to run once.
if [ ! -f "$HERMES_DATA_DIR/.env" ]; then
  if [ -t 0 ] && [ -t 1 ]; then
    info "No $HERMES_DATA_DIR/.env yet — the hermes setup wizard needs to run"
    printf '    Run the wizard now? [Y/n] '
    read -r reply
    case "${reply:-Y}" in
      [Nn]*) warn "skipped — the gateway will have no API key; run it later with:"
             warn "  docker run -it --rm -v $HERMES_DATA_DIR:/opt/data nousresearch/hermes-agent setup" ;;
      *)     docker run -it --rm -v "$HERMES_DATA_DIR:/opt/data" nousresearch/hermes-agent setup ;;
    esac
  else
    warn "no $HERMES_DATA_DIR/.env and no TTY to run the wizard on"
    warn "run it by hand:  docker run -it --rm -v $HERMES_DATA_DIR:/opt/data nousresearch/hermes-agent setup"
  fi
fi

# ----------------------------------------------------------------- start ----
info "Starting the stack"
if [ "$WITH_CLAUDE_CODE" = 1 ]; then
  docker compose up -d --build
else
  docker compose up -d
fi

info "Waiting for the containers to settle"
for _ in $(seq 1 30); do
  sleep 2
  if [ -z "$(docker compose ps --status restarting -q 2>/dev/null)" ]; then
    break
  fi
done

# --------------------------------------------------------------- summary ----
BIND_ADDR="$(get_kv HERMES_BIND_ADDR .env)";        : "${BIND_ADDR:=127.0.0.1}"
DASH_PORT="$(get_kv HERMES_DASHBOARD_PORT .env)";   : "${DASH_PORT:=9119}"
API_PORT="$(get_kv HERMES_API_PORT .env)";          : "${API_PORT:=8642}"
ROUTER_PORT="$(get_kv ROUTER_PORT .env)";           : "${ROUTER_PORT:=20128}"
ADAPTER_PORT="$(get_kv ADAPTER_PORT .env)";         : "${ADAPTER_PORT:=8082}"
ADAPTER_ADDR="$(get_kv ADAPTER_BIND_ADDR .env)";    : "${ADAPTER_ADDR:=127.0.0.1}"
DASH_USER="$(get_kv HERMES_DASHBOARD_USER .env)"
DASH_PASS="$(get_kv HERMES_DASHBOARD_PASSWORD .env)"
ROUTER_PASS="$(get_kv INITIAL_PASSWORD 9router.env)"

printf '\n'
docker compose ps
printf '\n'

printf '%s========================================================%s\n' "$C_BOLD" "$C_RESET"
printf '%s  Deployed%s\n' "$C_BOLD" "$C_RESET"
printf '%s========================================================%s\n\n' "$C_BOLD" "$C_RESET"

printf '%sAccess%s\n' "$C_BOLD" "$C_RESET"
printf '  Hermes dashboard   http://%s:%s\n' "$BIND_ADDR" "$DASH_PORT"
printf '  9router            http://%s:%s\n' "$BIND_ADDR" "$ROUTER_PORT"
printf '  Hermes API         http://%s:%s  %s(only with API_SERVER_ENABLED)%s\n' \
  "$BIND_ADDR" "$API_PORT" "$C_DIM" "$C_RESET"
printf '  claude-adapter     http://%s:%s  %s(NO auth — do not expose)%s\n\n' \
  "$ADAPTER_ADDR" "$ADAPTER_PORT" "$C_DIM" "$C_RESET"

printf '%sCredentials%s\n' "$C_BOLD" "$C_RESET"
if [ "$DASH_PASS_PROMPTED" = 1 ]; then
  printf '  Dashboard  %s / %s(the password you just typed)%s\n' "$DASH_USER" "$C_DIM" "$C_RESET"
else
  printf '  Dashboard  %s / %s\n' "$DASH_USER" "$DASH_PASS"
fi
if [ "$ROUTER_PASS_PROMPTED" = 1 ]; then
  printf '  9router    %s(the password you just typed)%s\n' "$C_DIM" "$C_RESET"
else
  printf '  9router    password: %s\n' "$ROUTER_PASS"
fi
printf '  %sForgot them? grep PASSWORD .env 9router.env%s\n\n' "$C_DIM" "$C_RESET"

if [ "$BIND_ADDR" = "127.0.0.1" ]; then
  printf '%sReaching it from another machine%s\n' "$C_BOLD" "$C_RESET"
  printf '  The ports are bound to loopback. Use an SSH tunnel:\n'
  printf '    ssh -L %s:127.0.0.1:%s -L %s:127.0.0.1:%s user@<host>\n' \
    "$DASH_PORT" "$DASH_PORT" "$ROUTER_PORT" "$ROUTER_PORT"
  printf '  %sSet HERMES_BIND_ADDR=0.0.0.0 in .env to expose it — read the README first.%s\n\n' \
    "$C_DIM" "$C_RESET"
fi

printf '%sData%s\n' "$C_BOLD" "$C_RESET"
printf '  Hermes          %s\n' "$HERMES_DATA_DIR"
printf '  9router         %s\n' "$ROUTER_DATA_DIR"
printf '  claude-adapter  %s\n\n' "$ADAPTER_DATA_DIR"

printf '%sWiring hermes to 9router%s\n' "$C_BOLD" "$C_RESET"
printf '  Edit %s/config.yaml:\n' "$HERMES_DATA_DIR"
printf '    model:\n'
printf '      provider: custom\n'
printf '      model: <model-name-on-9router>\n'
printf '      base_url: http://9router:20128/v1\n'
printf '      api_key: "none"\n'
printf '  Then: docker compose restart hermes\n\n'

printf '%sCommon commands%s\n' "$C_BOLD" "$C_RESET"
printf '  docker compose logs -f              # live logs\n'
printf '  docker compose ps                   # status\n'
printf '  docker compose restart hermes       # restart one service\n'
printf '  docker compose down                 # stop the stack\n'
printf '  docker exec -it hermes hermes       # open the chat CLI\n'
printf '  docker exec hermes hermes status    # gateway status\n'
if [ "$WITH_CLAUDE_CODE" = 1 ]; then
  printf '  docker exec -it hermes env HOME=/opt/data/home claude   # the claude CLI\n'
fi
printf '\n'
