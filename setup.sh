#!/usr/bin/env bash
#
# One-shot setup for hermes-agent. 9router + headroom are optional extras.
# Idempotent: re-running never overwrites a secret that already exists.
#
#   ./setup.sh                     # hermes only; asks whether to add 9router
#   ./setup.sh --with-router       # hermes + 9router + headroom, no prompt
#   ./setup.sh --without-router    # hermes only, no prompt
#   ./setup.sh --with-claude-code  # build the image with the `claude` CLI + claude-proxy
#   ./setup.sh --no-start          # only write the config files, do not start
#   ./setup.sh --non-interactive   # prompt for nothing (implies hermes only)
#   ./setup.sh --uninstall         # remove containers; add --data --images --purge
#   ./setup.sh --help
#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

WITH_CLAUDE_CODE=0
NO_START=0
NON_INTERACTIVE=0
# empty = ask (or default to no when there is nothing to ask on)
WITH_ROUTER=""
UNINSTALL=0
UN_DATA=0
UN_IMAGES=0
ASSUME_YES=0

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
  # Prints the header comment block above: from the first line after `#!` +
  # blank, up to the last comment line before `set -euo pipefail`. Derived
  # rather than hardcoded, so adding an option to the block cannot silently
  # drop the last line off `--help`.
  awk 'NR > 2 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
  exit 0
}

# ------------------------------------------------------------------ args ----
while [ $# -gt 0 ]; do
  case "$1" in
    --with-claude-code) WITH_CLAUDE_CODE=1 ;;
    --with-router)      WITH_ROUTER=1 ;;
    --without-router)   WITH_ROUTER=0 ;;
    --no-start)         NO_START=1 ;;
    --non-interactive)  NON_INTERACTIVE=1 ;;
    --uninstall)        UNINSTALL=1 ;;
    --data)             UN_DATA=1 ;;
    --images)           UN_IMAGES=1 ;;
    --purge)            UN_DATA=1; UN_IMAGES=1 ;;
    --yes|-y)           ASSUME_YES=1 ;;
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

# The script has already cd'd next to itself, so "run it from the right
# directory" is useless advice — moving your shell changes nothing. What
# matters is WHICH COPY of setup.sh you run, so name the directory it is
# actually looking in and point at the two ways out.
for f in docker-compose.yml .env.example 9router.env.example; do
  [ -f "$f" ] && continue
  printf '\n' >&2
  warn "looked in: $PWD"
  warn "setup.sh always works next to itself, so a lone copy of it cannot do anything."
  warn "Either run the copy that sits beside docker-compose.yml:"
  warn "    cd <install-dir> && ./setup.sh"
  warn "or install from scratch:"
  warn "    curl -fsSL https://raw.githubusercontent.com/0xphuong/hermes-agent/main/install.sh | bash"
  printf '\n' >&2
  die "missing $f"
done
ok "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null), compose $(docker compose version --short)"

# ------------------------------------------------------------- uninstall ----
# Lives here rather than in its own script because the install directory is
# deleted after a deploy: a standalone uninstall.sh would be deleted with it.
# Reach it the same way you installed:
#   curl -fsSL .../install.sh | bash -s -- --uninstall --purge
if [ "$UNINSTALL" = 1 ]; then
  HERMES_DATA_DIR="$(expand_tilde "$(get_kv HERMES_DATA_DIR .env)")"
  ROUTER_DATA_DIR="$(expand_tilde "$(get_kv ROUTER_DATA_DIR .env)")"
  : "${HERMES_DATA_DIR:=$HOME/.hermes}"
  : "${ROUTER_DATA_DIR:=$HOME/.9router}"

  size_of() { if [ -d "$1" ]; then du -sh "$1" 2>/dev/null | cut -f1; else echo "-"; fi; }

  printf '\n%sThis will remove%s\n' "$C_BOLD" "$C_RESET"
  printf '  containers   hermes, 9router, headroom\n'
  if [ "$UN_DATA" = 1 ]; then
    printf '  %sdata         %s (%s)%s\n' "$C_RED" "$HERMES_DATA_DIR" "$(size_of "$HERMES_DATA_DIR")" "$C_RESET"
    printf '  %s             %s (%s)%s\n' "$C_RED" "$ROUTER_DATA_DIR" "$(size_of "$ROUTER_DATA_DIR")" "$C_RESET"
    printf '               %sconfig, sessions, memories, and the claude login%s\n' "$C_DIM" "$C_RESET"
  fi
  if [ "$UN_IMAGES" = 1 ]; then
    printf '  images       hermes-agent, hermes-claude, 9router, headroom\n'
  fi
  if [ "$UN_DATA" = 0 ] && [ "$UN_IMAGES" = 0 ]; then
    printf '\n%sKept%s  %s and the images — reinstalling picks up where this left off.\n' \
      "$C_BOLD" "$C_RESET" "$HERMES_DATA_DIR"
  fi
  printf '\n'

  if [ "$ASSUME_YES" = 0 ]; then
    if [ ! -r /dev/tty ]; then
      die "no terminal to confirm on — re-run with --yes if you mean it"
    fi
    if [ "$UN_DATA" = 1 ]; then
      # Deleting state deserves more than a reflex keystroke.
      printf '  %sType "delete" to confirm:%s ' "$C_BOLD" "$C_RESET"
      IFS= read -r reply < /dev/tty || reply=""
      [ "$reply" = "delete" ] || die "aborted — nothing was changed"
    else
      printf '  Continue? [y/N] '
      IFS= read -r reply < /dev/tty || reply=""
      case "$reply" in [Yy]*) ;; *) die "aborted — nothing was changed" ;; esac
    fi
    printf '\n'
  fi

  info "Removing containers"
  # --profile router regardless of what .env says: a deployment that switched
  # the profile off leaves those two running but invisible to a bare `down`,
  # and this is exactly the moment they must not be missed.
  docker compose --profile router down --remove-orphans 2>/dev/null \
    || for c in hermes 9router headroom; do docker rm -f "$c" >/dev/null 2>&1 || true; done
  ok "containers removed"

  if [ "$UN_IMAGES" = 1 ]; then
    info "Removing images"
    for img in hermes-claude nousresearch/hermes-agent decolua/9router \
               ghcr.io/chopratejas/headroom; do
      ids="$(docker images -q "$img" 2>/dev/null | sort -u || true)"
      if [ -n "$ids" ]; then
        # shellcheck disable=SC2086
        docker rmi $ids >/dev/null 2>&1 || warn "could not remove $img (still in use?)"
        ok "$img"
      fi
    done
  fi

  if [ "$UN_DATA" = 1 ]; then
    info "Deleting data"
    for d in "$HERMES_DATA_DIR" "$ROUTER_DATA_DIR"; do
      [ -d "$d" ] || continue
      # The runtime chowns its data to UID 10000 mode 0700, so these are very
      # often not yours to delete.
      if rm -rf "$d" 2>/dev/null; then
        ok "deleted $d"
      elif command -v sudo >/dev/null 2>&1; then
        warn "$d is owned by the container's UID 10000 — escalating"
        sudo rm -rf "$d" && ok "deleted $d (via sudo)"
      else
        warn "could not delete $d — remove it by hand"
      fi
    done
  fi

  # The alias points at a container that no longer exists, so it goes too.
  # Every candidate rc file is checked, not just the current shell's: the
  # install may well have run under a different one.
  remove_hermes_alias() {
    local line='alias hermes="docker exec -it hermes hermes"'
    local rc tmp found=0
    for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile"; do
      [ -f "$rc" ] || continue
      grep -qF "$line" "$rc" || continue
      tmp="$(mktemp)"
      # Drops the alias and the "# hermes-agent" marker that precedes it, and
      # nothing else. The marker is held back one line so a stray comment that
      # is NOT followed by our alias survives.
      awk -v l="$line" '
        $0 == "# hermes-agent" { if (held != "") print held; held = $0; next }
        $0 == l                { held = ""; next }
                               { if (held != "") { print held; held = "" } print }
        END                    { if (held != "") print held }
      ' "$rc" > "$tmp"
      # cat rather than mv: keeps the rc file's own inode, owner and mode.
      cat "$tmp" > "$rc"
      rm -f "$tmp"
      ok "removed the hermes alias from $rc"
      found=1
    done
    if [ "$found" = 1 ]; then
      printf '  %sGone from new shells. In this one: unalias hermes%s\n' "$C_DIM" "$C_RESET"
    fi
  }
  remove_hermes_alias

  printf '\n%sUninstalled.%s\n' "$C_BOLD" "$C_RESET"
  if [ "$UN_DATA" = 0 ]; then
    printf '  Your data is still at %s.\n' "$HERMES_DATA_DIR"
    printf '  %sDelete it too by adding --data%s\n' "$C_DIM" "$C_RESET"
  fi
  printf '\n'
  exit 0
fi

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
  if [ "$DASH_PASS_PROMPTED" = 1 ]; then
    ok "dashboard password set"
  else
    ok "generated a dashboard password"
  fi
  printf '\n'
else
  ok "HERMES_DASHBOARD_PASSWORD already set — leaving it alone"
  [ -n "$(get_kv HERMES_DASHBOARD_USER .env)" ] || set_kv .env HERMES_DASHBOARD_USER admin
fi

# ------------------------------------------------------------ bind addr ----
# Asked at install time because there is no `.env` left to edit afterwards —
# the working directory goes away when this finishes.
#
# Precedence: an explicit HERMES_BIND_ADDR from the environment wins, then a
# value already in .env from an earlier run, then the question.
if [ -n "${HERMES_BIND_ADDR:-}" ]; then
  set_kv .env HERMES_BIND_ADDR "$HERMES_BIND_ADDR"
  ok "bind address $HERMES_BIND_ADDR (from the environment)"
elif [ "$(get_kv HERMES_BIND_ADDR .env)" != "127.0.0.1" ] \
     && [ -n "$(get_kv HERMES_BIND_ADDR .env)" ]; then
  ok "bind address $(get_kv HERMES_BIND_ADDR .env) — keeping the current value"
elif [ "$NON_INTERACTIVE" = 0 ] && [ -r /dev/tty ]; then
  printf '\n  %sWho can reach the dashboard?%s\n' "$C_BOLD" "$C_RESET"
  printf '    %s1%s  127.0.0.1  this host only — reach it over an SSH tunnel %s(default)%s\n' \
    "$C_BOLD" "$C_RESET" "$C_DIM" "$C_RESET"
  printf '    %s2%s  0.0.0.0    anything that can route to this machine\n' "$C_BOLD" "$C_RESET"
  printf '\n    %sBefore picking 2:%s an exposed dashboard was the entry point for the June 2026\n' \
    "$C_YELLOW" "$C_RESET"
  printf '    MCP-config persistence campaign. Basic auth is on and cannot be turned off, but it\n'
  printf '    is not enough for the public internet — put a VPN or an authenticating proxy first.\n'
  printf '\n    Choice [1]: '
  { IFS= read -r reply < /dev/tty; } 2>/dev/null || reply=""
  case "$reply" in
    2) set_kv .env HERMES_BIND_ADDR 0.0.0.0
       warn "bind address 0.0.0.0 — the dashboard is reachable from the network"
       ;;
    *) set_kv .env HERMES_BIND_ADDR 127.0.0.1
       ok "bind address 127.0.0.1 (loopback only)"
       ;;
  esac
  printf '\n'
else
  set_kv .env HERMES_BIND_ADDR 127.0.0.1
  ok "bind address 127.0.0.1 (loopback only)"
fi

# ---------------------------------------------------------------- router ----
# Hermes is the product; 9router is an optional LLM router in front of it, and
# headroom is 9router's own dependency. Default is hermes alone.
#
# A leftover 9router.env shifts the DEFAULT to yes — it never answers on the
# user's behalf. Deciding for them means a directory that happens to still hold
# a months-old 9router.env silently installs two extra services on what the
# user is treating as a fresh install, and the only clue is one `ok` line
# scrolling past. Ask either way; just start the cursor on the safe answer.
if [ -z "$WITH_ROUTER" ]; then
  if [ -f 9router.env ]; then router_default=1; else router_default=0; fi

  if [ "$NON_INTERACTIVE" = 0 ] && [ -r /dev/tty ]; then
    printf '\n  %sAlso install 9router?%s %s(LLM router + headroom; hermes does not need it)%s\n' \
      "$C_BOLD" "$C_RESET" "$C_DIM" "$C_RESET"
    if [ "$router_default" = 1 ]; then
      printf '    %sThis directory already has a 9router.env from an earlier install.%s\n' \
        "$C_DIM" "$C_RESET"
      printf '    Install it? [Y/n] '
    else
      printf '    Install it? [y/N] '
    fi
    IFS= read -r reply < /dev/tty || reply=""
    case "$reply" in
      [Yy]*) WITH_ROUTER=1 ;;
      [Nn]*) WITH_ROUTER=0 ;;
      *)     WITH_ROUTER="$router_default" ;;   # bare Enter takes the default
    esac
    printf '\n'
  else
    # No terminal to ask on. Keeping a configured router is the conservative
    # choice here: tearing one down unasked is worse than leaving it up.
    WITH_ROUTER="$router_default"
    if [ "$WITH_ROUTER" = 1 ]; then
      ok "9router.env exists and there is no terminal to ask on — keeping 9router"
    fi
  fi
fi

# COMPOSE_PROFILES is read by the compose CLI itself out of ./.env, so every
# later `docker compose …` in this directory picks the right services up
# without anyone having to remember `--profile router`.
if [ "$WITH_ROUTER" = 1 ]; then
  set_kv .env COMPOSE_PROFILES router
else
  set_kv .env COMPOSE_PROFILES ""
  ok "hermes only — 9router and headroom stay out of this deployment"
fi

ROUTER_PASS_PROMPTED=0
if [ "$WITH_ROUTER" = 1 ]; then
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
    if [ "$ROUTER_PASS_PROMPTED" = 1 ]; then
      ok "9router password set"
    else
      ok "generated a 9router password"
    fi
    printf '\n'
  else
    ok "INITIAL_PASSWORD already set — leaving it alone"
  fi
fi

chmod 600 .env 2>/dev/null || true
[ -f 9router.env ] && chmod 600 9router.env 2>/dev/null || true

# ------------------------------------------------------------- data dirs ----
info "Creating the data directories"

HERMES_DATA_DIR="$(expand_tilde "$(get_kv HERMES_DATA_DIR .env)")"
ROUTER_DATA_DIR="$(expand_tilde "$(get_kv ROUTER_DATA_DIR .env)")"
: "${HERMES_DATA_DIR:=$HOME/.hermes}"
: "${ROUTER_DATA_DIR:=$HOME/.9router}"

mkdir -p "$HERMES_DATA_DIR"
ok "$HERMES_DATA_DIR"
if [ "$WITH_ROUTER" = 1 ]; then
  mkdir -p "$ROUTER_DATA_DIR"
  ok "$ROUTER_DATA_DIR"
fi

# claude-proxy needs no directory of its own: it runs inside the hermes
# container and the `claude` CLI stores its login and session transcripts under
# /opt/data, which is $HERMES_DATA_DIR on the host. PUID/PGID already cover the
# ownership.

# ----------------------------------------------------- claude-code build ----
OVERRIDE_FILE=docker-compose.override.yml

if [ "$WITH_CLAUDE_CODE" = 1 ]; then
  [ -f Dockerfile ] || die "--with-claude-code needs the Dockerfile"
  # HERMES_IMAGE_TAG is forwarded as a build arg, not just used for `image:`.
  # Without it the derived image would always build FROM :latest while compose
  # believes it is running the pinned tag — the two silently diverge.
  cat > "$OVERRIDE_FILE" <<'YAML'
# Generated by setup.sh --with-claude-code. This file is git-ignored.
services:
  hermes:
    build:
      context: .
      args:
        HERMES_IMAGE_TAG: ${HERMES_IMAGE_TAG:-latest}
    image: hermes-claude:${HERMES_IMAGE_TAG:-latest}
YAML
  ok "created $OVERRIDE_FILE — hermes will build from Dockerfile (claude CLI + claude-proxy)"
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
# Everything interactive goes through /dev/tty rather than stdin. Under
# `curl … | bash` stdin IS the script being piped in, so a plain `read` there
# consumes the rest of the script instead of the user's answer, and `[ -t 0 ]`
# is false even when a perfectly good terminal is attached.
if [ ! -f "$HERMES_DATA_DIR/.env" ]; then
  if [ "$NON_INTERACTIVE" = 0 ] && [ -r /dev/tty ]; then
    info "No $HERMES_DATA_DIR/.env yet — the hermes setup wizard needs to run"
    printf '    Run the wizard now? [Y/n] '
    IFS= read -r reply < /dev/tty || reply=""
    case "${reply:-Y}" in
      [Nn]*) warn "skipped — the gateway will have no API key; run it later with:"
             warn "  docker run -it --rm -v $HERMES_DATA_DIR:/opt/data nousresearch/hermes-agent setup" ;;
      # The wizard is interactive, so hand docker the terminal explicitly: with
      # a piped stdin `-it` would fail with "the input device is not a TTY".
      *)     docker run -it --rm -v "$HERMES_DATA_DIR:/opt/data" \
               nousresearch/hermes-agent setup < /dev/tty ;;
    esac
  else
    warn "no $HERMES_DATA_DIR/.env and no terminal to run the wizard on"
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
if [ "$WITH_ROUTER" = 1 ]; then
  printf '  9router            http://%s:%s\n' "$BIND_ADDR" "$ROUTER_PORT"
fi
printf '  Hermes API         http://%s:%s  %s(only with API_SERVER_ENABLED)%s\n' \
  "$BIND_ADDR" "$API_PORT" "$C_DIM" "$C_RESET"
if [ "$WITH_CLAUDE_CODE" = 1 ]; then
  printf '  claude-proxy       %sinside the hermes container only, http://localhost:8082%s\n' \
    "$C_DIM" "$C_RESET"
fi
printf '\n'

printf '%sCredentials%s\n' "$C_BOLD" "$C_RESET"
if [ "$DASH_PASS_PROMPTED" = 1 ]; then
  printf '  Dashboard  %s / %s(the password you just typed)%s\n' "$DASH_USER" "$C_DIM" "$C_RESET"
else
  printf '  Dashboard  %s / %s\n' "$DASH_USER" "$DASH_PASS"
fi
if [ "$WITH_ROUTER" = 1 ]; then
  if [ "$ROUTER_PASS_PROMPTED" = 1 ]; then
    printf '  9router    %s(the password you just typed)%s\n' "$C_DIM" "$C_RESET"
  else
    printf '  9router    password: %s\n' "$ROUTER_PASS"
  fi
  printf '\n  %sSave these now.%s The working directory — .env and 9router.env with it —\n' \
    "$C_RED" "$C_RESET"
  printf '  is deleted when this finishes. There is nowhere left to look them up.\n\n'
else
  printf '\n  %sSave this now.%s The working directory, .env included, is deleted when\n' \
    "$C_RED" "$C_RESET"
  printf '  this finishes. There is nowhere left to look it up.\n\n'
fi

if [ "$BIND_ADDR" = "127.0.0.1" ]; then
  printf '%sReaching it from another machine%s\n' "$C_BOLD" "$C_RESET"
  printf '  The ports are bound to loopback. Use an SSH tunnel:\n'
  if [ "$WITH_ROUTER" = 1 ]; then
    printf '    ssh -L %s:127.0.0.1:%s -L %s:127.0.0.1:%s user@<host>\n' \
      "$DASH_PORT" "$DASH_PORT" "$ROUTER_PORT" "$ROUTER_PORT"
  else
    printf '    ssh -L %s:127.0.0.1:%s user@<host>\n' "$DASH_PORT" "$DASH_PORT"
  fi
  printf '  %sTo expose it, reinstall with HERMES_BIND_ADDR=0.0.0.0 set — read the README first.%s\n\n' \
    "$C_DIM" "$C_RESET"
fi

printf '%sData%s\n' "$C_BOLD" "$C_RESET"
printf '  Hermes          %s\n' "$HERMES_DATA_DIR"
if [ "$WITH_ROUTER" = 1 ]; then
  printf '  9router         %s\n' "$ROUTER_DATA_DIR"
fi
printf '\n'

if [ "$WITH_CLAUDE_CODE" = 1 ]; then
  printf '%sPoint hermes at claude-proxy%s\n' "$C_BOLD" "$C_RESET"
  printf '  Log the claude CLI in once:\n'
  printf '    docker exec -it -u hermes hermes claude\n'
  printf '  Then put this in %s/config.yaml:\n\n' "$HERMES_DATA_DIR"
  printf '    model:\n'
  printf '      default: claude-opus-4-6\n'
  printf '      provider: anthropic\n'
  printf '    providers:\n'
  printf '      anthropic:\n'
  printf '        api_key: dummy\n'
  printf '        base_url: http://127.0.0.1:8082/v1\n'
  printf '        default_model: claude-sonnet-4-6\n\n'
  printf '  %sbase_url must sit under providers.anthropic — model.base_url is ignored\n' "$C_DIM"
  printf '  for that provider and hermes calls api.anthropic.com instead.%s\n' "$C_RESET"
  printf '  Edit from inside (the host cannot read /opt/data):\n'
  printf '    docker exec -it -u hermes hermes vi /opt/data/config.yaml\n'
  printf '    docker restart hermes\n\n'
elif [ "$WITH_ROUTER" = 1 ]; then
  printf '%sWiring hermes to 9router%s\n' "$C_BOLD" "$C_RESET"
  printf '  Edit %s/config.yaml:\n' "$HERMES_DATA_DIR"
  printf '    model:\n'
  printf '      provider: custom\n'
  printf '      model: <model-name-on-9router>\n'
  printf '      base_url: http://9router:20128/v1\n'
  printf '      api_key: "none"\n'
  printf '  Then: docker compose restart hermes\n\n'
else
  printf '%sNext: pick a model%s\n' "$C_BOLD" "$C_RESET"
  printf '  The wizard wrote your provider keys to %s/.env.\n' "$HERMES_DATA_DIR"
  printf '  Add 9router later by reinstalling with --with-router.\n\n'
fi

# ----------------------------------------------------------------- alias ----
# The install directory is deleted after this, so `docker compose` stops being
# available. An alias straight onto the container is what is left, and it is
# what people actually want to type anyway.
install_hermes_alias() {
  local rc line
  line='alias hermes="docker exec -it hermes hermes"'

  # Write to the rc file of the shell the user actually runs, falling back to
  # bash. Appending to the wrong one looks like the alias silently failed.
  case "$(basename "${SHELL:-/bin/bash}")" in
    zsh)  rc="$HOME/.zshrc" ;;
    bash) rc="$HOME/.bashrc" ;;
    *)    rc="$HOME/.profile" ;;
  esac

  if [ -f "$rc" ] && grep -qF "$line" "$rc"; then
    ok "alias already in $rc"
    return 0
  fi
  printf '\n# hermes-agent\n%s\n' "$line" >> "$rc"
  ok "added to $rc"
  printf '  %sActive in new shells. For this one:%s source %s\n' "$C_DIM" "$C_RESET" "$rc"
}

if [ "$NON_INTERACTIVE" = 0 ] && [ -r /dev/tty ]; then
  printf '%sShell alias%s\n' "$C_BOLD" "$C_RESET"
  printf '  %shermes%s  ->  docker exec -it hermes hermes\n' "$C_BOLD" "$C_RESET"
  printf '  Add it to your shell? [Y/n] '
  IFS= read -r reply < /dev/tty || reply=""
  case "$reply" in
    [Nn]*) printf '  %sskipped — run: docker exec -it hermes hermes%s\n' "$C_DIM" "$C_RESET" ;;
    *)     install_hermes_alias ;;
  esac
  printf '\n'
fi

printf '%sUsing it%s\n' "$C_BOLD" "$C_RESET"
printf '  hermes                  # open the chat CLI\n'
printf '  hermes status           # gateway status\n'
printf '  hermes logs --follow    # live logs\n'
if [ "$WITH_CLAUDE_CODE" = 1 ]; then
  printf '  docker exec -it -u hermes hermes claude   # log the claude CLI in (once)\n'
fi
printf '\n'
