#!/usr/bin/env bash
#
# One-line installer for the hermes-agent stack.
#
#   curl -fsSL https://raw.githubusercontent.com/0xphuong/hermes-agent/main/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --with-claude-code
#
# It clones the repo into a temporary directory, copies the files the stack
# actually needs into an install directory, deletes the clone, then hands over
# to setup.sh. Nothing git-related survives — no .git, no docs, no installer.
#
# Environment:
#   INSTALL_DIR    where the stack lives afterwards   (default ~/hermes-agent)
#   HERMES_AGENT_REPO / _REF                          (default this repo, main)
#
# Piping a script from the internet into a shell runs it before you have read
# it. To look first:
#   curl -fsSL .../install.sh -o install.sh && less install.sh && bash install.sh
set -euo pipefail

REPO="${HERMES_AGENT_REPO:-https://github.com/0xphuong/hermes-agent.git}"
REF="${HERMES_AGENT_REF:-main}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/hermes-agent}"

# Files the deployed stack needs. Anything not listed here stays behind in the
# temporary clone and dies with it. .dockerignore is NOT optional: without it a
# later `--with-claude-code` rebuild would ship .env and 9router.env to the
# Docker daemon.
INSTALL_FILES=(
  docker-compose.yml
  Dockerfile
  .dockerignore
  docker
  setup.sh
  .env.example
  9router.env.example
)

if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_CYAN=$'\033[36m'
else
  C_RESET=''; C_RED=''; C_GREEN=''; C_CYAN=''
fi
info() { printf '%s==>%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
die()  { printf '%s error:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

info "Checking the environment"
command -v git    >/dev/null 2>&1 || die "git is not installed"
command -v docker >/dev/null 2>&1 || die "docker is not installed"
docker compose version >/dev/null 2>&1 || die "docker compose v2 (the plugin) is required"
ok "git $(git --version | awk '{print $3}'), docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?')"

# The trap is set before the clone exists so an interrupt at any point after
# this line still cleans up. `${TMP:-}` because it is not assigned yet.
TMP=""
cleanup() { [ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

TMP="$(mktemp -d)"
info "Fetching $REPO ($REF)"
git clone --quiet --depth 1 --branch "$REF" "$REPO" "$TMP/repo" \
  || die "clone failed — check the repo URL, the ref, and your network"
ok "cloned to a temporary directory"

info "Installing into $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
for f in "${INSTALL_FILES[@]}"; do
  [ -e "$TMP/repo/$f" ] || die "missing $f in the repo — wrong ref?"
  # -a to keep the executable bit on setup.sh and the s6 run scripts: s6
  # silently ignores a run script that is not executable.
  # The trailing slash on the source of a directory copies its *contents*, so
  # re-running does not nest docker/docker/.
  if [ -d "$TMP/repo/$f" ]; then
    mkdir -p "$INSTALL_DIR/$f"
    cp -a "$TMP/repo/$f/." "$INSTALL_DIR/$f/"
  else
    cp -a "$TMP/repo/$f" "$INSTALL_DIR/$f"
  fi
done
ok "$(printf '%s ' "${INSTALL_FILES[@]}")"

# .env and 9router.env are never copied, so an existing install keeps its
# secrets and setup.sh treats this as a re-run rather than a fresh setup.
rm -rf "$TMP"
TMP=""
ok "removed the clone — no .git, no docs, no installer left behind"

info "Handing over to setup.sh"
printf '\n'
cd "$INSTALL_DIR"
# `exec` so setup.sh owns the terminal and its exit status is ours. It reads
# every prompt from /dev/tty, which is what makes this work under a pipe.
exec bash ./setup.sh "$@"
