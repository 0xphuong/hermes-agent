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

SELF_URL="${HERMES_AGENT_INSTALLER_URL:-https://raw.githubusercontent.com/0xphuong/hermes-agent/main/install.sh}"
# Kept for the docker-group re-exec below. %q so a re-exec cannot mangle an
# argument containing a space.
ORIG_ARGS="$(printf ' %q' "$@")"

REPO="${HERMES_AGENT_REPO:-https://github.com/0xphuong/hermes-agent.git}"
REF="${HERMES_AGENT_REF:-main}"
KEEP_DIR="${KEEP_DIR:-0}"

if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
else
  C_RESET=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''
fi
info() { printf '%s==>%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s  !!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%s error:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# ---------------------------------------------------------------- docker ----
# Install docker only when it is actually missing, and only on apt systems —
# the upstream repository is Debian/Ubuntu specific. Anywhere else this reports
# what to install and stops rather than guessing.
apt_install_docker() {
  local codename distro
  # The repo path differs per distro; pointing Debian at .../linux/ubuntu gives
  # a suite that does not exist there and apt fails on the next update.
  # shellcheck source=/dev/null
  distro="$(. /etc/os-release && echo "${ID:-ubuntu}")"
  case "$distro" in
    ubuntu|debian) ;;
    *) distro=ubuntu ;;   # Mint, Pop!_OS and friends track ubuntu suites
  esac
  # shellcheck source=/dev/null
  codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
  [ -n "$codename" ] || die "could not read the distro codename from /etc/os-release"

  info "Removing conflicting packages"
  # dpkg --get-selections prints nothing for packages that were never
  # installed, so this list is usually short or empty — and `apt remove` with
  # no arguments is an error, hence the guard.
  local conflicting
  # `dpkg --get-selections` also lists packages in the `deinstall` state — ones
  # already removed but not purged. Only genuinely installed ones are worth
  # passing to apt.
  conflicting="$($SUDO dpkg --get-selections docker.io docker-compose \
      docker-compose-v2 docker-doc podman-docker containerd runc 2>/dev/null \
      | awk '$2 == "install" { print $1 }' || true)"
  if [ -n "$conflicting" ]; then
    # shellcheck disable=SC2086
    $SUDO apt-get remove -y $conflicting || warn "could not remove: $conflicting"
  else
    ok "none installed"
  fi

  info "Adding Docker's apt repository"
  $SUDO apt-get update -qq
  $SUDO apt-get install -y -qq ca-certificates curl
  $SUDO install -m 0755 -d /etc/apt/keyrings
  $SUDO curl -fsSL "https://download.docker.com/linux/$distro/gpg" \
    -o /etc/apt/keyrings/docker.asc
  $SUDO chmod a+r /etc/apt/keyrings/docker.asc
  $SUDO tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/$distro
Suites: $codename
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  ok "$distro / $codename"

  info "Installing docker"
  $SUDO apt-get update -qq
  $SUDO apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
  $SUDO systemctl enable --now docker
  ok "docker installed and enabled"
}

ensure_docker() {
  local need_docker=0 need_compose=0 reply

  command -v docker >/dev/null 2>&1 || need_docker=1
  if [ "$need_docker" = 0 ] && ! docker compose version >/dev/null 2>&1; then
    need_compose=1
  fi

  if [ "$need_docker" = 0 ] && [ "$need_compose" = 0 ]; then
    # Present, but the daemon may be stopped or unreachable for this user.
    if ! docker info >/dev/null 2>&1; then
      if command -v systemctl >/dev/null 2>&1 && [ -n "$SUDO" ] || [ "$(id -u)" = 0 ]; then
        info "Starting the docker daemon"
        $SUDO systemctl start docker 2>/dev/null || true
      fi
      docker info >/dev/null 2>&1 || add_user_to_docker_group
    fi
    return 0
  fi

  printf '\n'
  if [ "$need_docker" = 1 ]; then
    warn "docker is not installed"
  else
    warn "docker is installed but the compose v2 plugin is missing"
  fi

  command -v apt-get >/dev/null 2>&1 \
    || die "this installer can only install docker on apt systems — install it yourself and re-run"

  if [ "$(id -u)" = 0 ]; then
    SUDO=""
  elif command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    die "installing docker needs root, and sudo is not available — install it yourself and re-run"
  fi

  # `[ -r /dev/tty ]` can be true where opening it still fails (inside a
  # container, under some CI runners), so the read has to tolerate that rather
  # than spray "No such device or address" over the output.
  if [ -r /dev/tty ]; then
    printf '    Install it now? [Y/n] '
    # The redirect itself is what fails, and the shell reports that before
    # `read` ever runs — so the whole command has to be grouped and silenced,
    # not just the read.
    { IFS= read -r reply < /dev/tty; } 2>/dev/null || reply=""
    printf '\n'
    case "$reply" in [Nn]*) die "aborted — install docker, then re-run" ;; esac
  fi
  printf '\n'

  if [ "$need_compose" = 1 ]; then
    info "Installing the compose plugin"
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq docker-compose-plugin
    ok "docker-compose-plugin"
  else
    apt_install_docker
  fi

  add_user_to_docker_group
}

# Adds the user to the docker group and, because that cannot apply to a process
# already running, re-executes the installer through `sg` so the run continues
# instead of stopping halfway with homework.
add_user_to_docker_group() {
  local me="${USER:-$(id -un)}"
  [ "$(id -u)" != 0 ] || return 0

  if id -nG "$me" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
    :
  else
    info "Adding $me to the docker group"
    $SUDO usermod -aG docker "$me" && ok "added"
  fi

  docker info >/dev/null 2>&1 && return 0

  # The group is in /etc/group now, but THIS process's credentials were fixed
  # when the shell logged in, and nothing can add a group to a running process.
  # `sg` starts a child that has it — enough to finish the install instead of
  # dumping the user back at the prompt to log out, log in and start over.
  #
  # HERMES_AGENT_REEXEC stops that becoming a loop when docker is still
  # unusable for some other reason (daemon down, socket permissions).
  if [ "${HERMES_AGENT_REEXEC:-0}" != 1 ] && command -v sg >/dev/null 2>&1; then
    info "Re-running under the docker group"
    export HERMES_AGENT_REEXEC=1
    printf '\n'
    # Prefer re-running the file we came from; under `curl | bash` there is no
    # file to re-run, so fetch it again.
    if [ -f "$0" ] && [ -r "$0" ]; then
      exec sg docker -c "bash $(printf '%q' "$0")$ORIG_ARGS"
    else
      exec sg docker -c "curl -fsSL $(printf '%q' "$SELF_URL") | bash -s --$ORIG_ARGS"
    fi
  fi

  printf '\n'
  warn "docker still is not usable as $me — group membership needs a new login session."
  warn "Do one of these, then run this installer again:"
  warn "    newgrp docker           # this shell only"
  warn "    exit and log back in    # everywhere"
  printf '\n'
  exit 0
}

SUDO=""
[ "$(id -u)" = 0 ] || SUDO="sudo"

info "Checking the environment"
if ! command -v git >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    info "Installing git"
    $SUDO apt-get update -qq && $SUDO apt-get install -y -qq git
  else
    die "git is not installed"
  fi
fi
ensure_docker
ok "git $(git --version | awk '{print $3}'), docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?'), compose $(docker compose version --short 2>/dev/null || echo '?')"

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
