#!/usr/bin/env bash
#
# One-line installer for the hermes-agent stack.
#
#   curl -fsSL https://raw.githubusercontent.com/0xphuong/hermes-agent/main/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --with-claude-code
#   curl -fsSL .../install.sh | bash -s -- --uninstall --purge
#
# It clones into a temporary directory, runs setup.sh there, and deletes the
# clone. Nothing is left on disk: the containers keep running on their own
# (restart: unless-stopped), and day-to-day you talk to them through the
# `hermes` alias setup.sh offers to install.
#
# That means `docker compose` is not available afterwards — there is no compose
# file left to point it at. Reinstall or uninstall by running this script again.
#
# Environment:
#   HERMES_AGENT_REPO / _REF     which repo and ref to clone (default: main)
#   KEEP_DIR=1                   keep the working directory instead of deleting
#
# Piping a script from the internet into a shell runs it before you have read
# it. To look first:
#   curl -fsSL .../install.sh -o install.sh && less install.sh && bash install.sh
set -euo pipefail

REPO="${HERMES_AGENT_REPO:-https://github.com/0xphuong/hermes-agent.git}"
REF="${HERMES_AGENT_REF:-main}"
KEEP_DIR="${KEEP_DIR:-0}"

if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_CYAN=$'\033[36m'
else
  C_RESET=''; C_DIM=''; C_RED=''; C_GREEN=''; C_CYAN=''
fi
info() { printf '%s==>%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
die()  { printf '%s error:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

info "Checking the environment"
command -v git    >/dev/null 2>&1 || die "git is not installed"
command -v docker >/dev/null 2>&1 || die "docker is not installed"
docker compose version >/dev/null 2>&1 || die "docker compose v2 (the plugin) is required"
ok "git $(git --version | awk '{print $3}'), docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?')"

# Set before the clone exists so an interrupt at any point still cleans up.
TMP=""
cleanup() {
  if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
    if [ "$KEEP_DIR" = 1 ]; then
      printf '%s  kept %s (KEEP_DIR=1)%s\n' "$C_DIM" "$TMP" "$C_RESET"
    else
      rm -rf "$TMP"
    fi
  fi
}
trap cleanup EXIT INT TERM

TMP="$(mktemp -d)"
info "Fetching $REPO ($REF)"
git clone --quiet --depth 1 --branch "$REF" "$REPO" "$TMP/repo" \
  || die "clone failed — check the repo URL, the ref, and your network"
ok "cloned to a temporary directory"

printf '\n'
cd "$TMP/repo"

# Not `exec`: this script has to outlive setup.sh so the trap can delete the
# clone afterwards. Failures propagate through set -e.
#
# The compose project name is pinned in docker-compose.yml, so running from a
# throwaway directory does not name the project after it.
bash ./setup.sh "$@"

printf '%s  working directory removed — the containers keep running on their own%s\n\n' \
  "$C_DIM" "$C_RESET"
