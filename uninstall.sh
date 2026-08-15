#!/usr/bin/env bash
#
# Remove the hermes-agent stack. Containers only by default — your data is not
# touched unless you ask for it in so many words.
#
#   ./uninstall.sh                 # stop + remove containers and the network
#   ./uninstall.sh --data          # also delete ~/.hermes and ~/.9router
#   ./uninstall.sh --images        # also remove the docker images
#   ./uninstall.sh --purge         # containers + data + images + this directory
#   ./uninstall.sh --dry-run       # print what would happen, change nothing
#   ./uninstall.sh --yes           # skip the confirmation prompt
#   ./uninstall.sh --help
#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

WITH_DATA=0
WITH_IMAGES=0
WITH_DIR=0
DRY_RUN=0
ASSUME_YES=0

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
  awk 'NR > 2 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --data)     WITH_DATA=1 ;;
    --images)   WITH_IMAGES=1 ;;
    --purge)    WITH_DATA=1; WITH_IMAGES=1; WITH_DIR=1 ;;
    --dry-run)  DRY_RUN=1 ;;
    --yes|-y)   ASSUME_YES=1 ;;
    -h|--help)  usage ;;
    *)          die "invalid argument: $1  (see --help)" ;;
  esac
  shift
done

run() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '  %swould run:%s %s\n' "$C_DIM" "$C_RESET" "$*"
  else
    "$@"
  fi
}

# Success line for something `run` just did. Silent during a dry run, where
# "ok deleted /home/you/.hermes" would be a plain lie sitting under a
# "would run" it never executed.
ok_done() { [ "$DRY_RUN" = 1 ] || ok "$@"; }

# Same tilde handling as setup.sh — the shell does not expand `~` from a
# variable, and these paths come straight out of .env.
expand_tilde() {
  case "$1" in
    "~")   printf '%s\n' "$HOME" ;;
    "~"/*) printf '%s\n' "$HOME/${1#\~/}" ;;
    *)     printf '%s\n' "$1" ;;
  esac
}
get_kv() {
  [ -f "$2" ] || return 0
  grep -E "^$1=" "$2" 2>/dev/null | head -1 | cut -d= -f2- || true
}

# Read the data paths BEFORE anything gets deleted — .env is the only record of
# where they are, and --purge removes it.
HERMES_DATA_DIR="$(expand_tilde "$(get_kv HERMES_DATA_DIR .env)")"
ROUTER_DATA_DIR="$(expand_tilde "$(get_kv ROUTER_DATA_DIR .env)")"
: "${HERMES_DATA_DIR:=$HOME/.hermes}"
: "${ROUTER_DATA_DIR:=$HOME/.9router}"
INSTALL_DIR="$PWD"

size_of() { [ -d "$1" ] && du -sh "$1" 2>/dev/null | cut -f1 || echo "-"; }

# ------------------------------------------------------------------ plan ----
printf '\n%sThis will remove%s\n' "$C_BOLD" "$C_RESET"
printf '  containers   hermes, 9router, headroom  %s(and this project'"'"'s network)%s\n' \
  "$C_DIM" "$C_RESET"

if [ "$WITH_DATA" = 1 ]; then
  printf '  %sdata         %s  (%s)%s\n' "$C_RED" "$HERMES_DATA_DIR" "$(size_of "$HERMES_DATA_DIR")" "$C_RESET"
  printf '  %s             %s  (%s)%s\n' "$C_RED" "$ROUTER_DATA_DIR" "$(size_of "$ROUTER_DATA_DIR")" "$C_RESET"
  printf '               %shermes config, sessions, memories, skills, and the claude login%s\n' \
    "$C_DIM" "$C_RESET"
fi
[ "$WITH_IMAGES" = 1 ] && printf '  images       hermes-agent, hermes-claude, 9router, headroom\n'
if [ "$WITH_DIR" = 1 ]; then
  printf '  %sdirectory    %s  (.env and 9router.env with it)%s\n' "$C_RED" "$INSTALL_DIR" "$C_RESET"
fi

if [ "$WITH_DATA" = 0 ] && [ "$WITH_IMAGES" = 0 ]; then
  printf '\n%sKept%s  %s, %s, images, and this directory.\n' \
    "$C_BOLD" "$C_RESET" "$HERMES_DATA_DIR" "$ROUTER_DATA_DIR"
  printf '      %sRe-running ./setup.sh brings everything back as it was.%s\n' "$C_DIM" "$C_RESET"
fi
printf '\n'

if [ "$DRY_RUN" = 0 ] && [ "$ASSUME_YES" = 0 ]; then
  if [ -r /dev/tty ]; then
    if [ "$WITH_DATA" = 1 ] || [ "$WITH_DIR" = 1 ]; then
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
  else
    die "no terminal to confirm on — re-run with --yes if you mean it"
  fi
fi

# ------------------------------------------------------------ containers ----
info "Removing containers"
if [ -f docker-compose.yml ] && docker compose version >/dev/null 2>&1; then
  # --profile router regardless of what .env says: a deployment that switched
  # the profile off leaves those two containers running but invisible to a bare
  # `down`, and this is exactly the moment they must not be missed.
  # --remove-orphans catches containers from services since renamed or dropped.
  run docker compose --profile router down --remove-orphans
  ok_done "compose down"
else
  warn "no docker-compose.yml here — falling back to removing containers by name"
  for c in hermes 9router headroom claude-cli-adapter; do
    if [ -n "$(docker ps -aq -f "name=^${c}$" 2>/dev/null)" ]; then
      run docker rm -f "$c"
      ok_done "removed $c"
    fi
  done
fi

# ---------------------------------------------------------------- images ----
if [ "$WITH_IMAGES" = 1 ]; then
  info "Removing images"
  for img in hermes-claude nousresearch/hermes-agent decolua/9router \
             ghcr.io/chopratejas/headroom; do
    ids="$(docker images -q "$img" 2>/dev/null | sort -u || true)"
    if [ -n "$ids" ]; then
      # shellcheck disable=SC2086
      run docker rmi $ids 2>/dev/null || warn "could not remove $img (still in use?)"
      ok_done "$img"
    fi
  done
fi

# ------------------------------------------------------------------ data ----
if [ "$WITH_DATA" = 1 ]; then
  info "Deleting data directories"
  for d in "$HERMES_DATA_DIR" "$ROUTER_DATA_DIR"; do
    if [ -d "$d" ]; then
      # The runtime writes as UID 10000, so on Linux some files may not be
      # owned by you. Try plain rm first and only then ask for sudo.
      if run rm -rf "$d" 2>/dev/null; then
        ok_done "deleted $d"
      elif [ "$DRY_RUN" = 0 ] && command -v sudo >/dev/null 2>&1; then
        warn "$d needs elevated permissions (files owned by the container's UID 10000)"
        sudo rm -rf "$d" && ok "deleted $d (via sudo)"
      else
        warn "could not delete $d — remove it by hand"
      fi
    fi
  done
fi

# ------------------------------------------------------------- directory ----
if [ "$WITH_DIR" = 1 ]; then
  info "Removing the install directory"
  # cd out first: deleting the directory the shell is sitting in leaves it with
  # no valid working directory, and everything after this line gets strange.
  # The script itself is already read into memory, so removing it is fine.
  cd /
  run rm -rf "$INSTALL_DIR"
  ok_done "deleted $INSTALL_DIR"
fi

printf '\n'
if [ "$DRY_RUN" = 1 ]; then
  printf '%sDry run — nothing was changed.%s\n\n' "$C_BOLD" "$C_RESET"
else
  printf '%sUninstalled.%s\n' "$C_BOLD" "$C_RESET"
  if [ "$WITH_DATA" = 0 ]; then
    printf '  Your data is still at %s.\n' "$HERMES_DATA_DIR"
    printf '  %sDelete it too with: ./uninstall.sh --data%s\n' "$C_DIM" "$C_RESET"
  fi
  printf '\n'
fi
