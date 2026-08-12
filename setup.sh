#!/usr/bin/env bash
#
# Setup mot phat cho stack hermes-agent + 9router + headroom.
# Idempotent: chay lai nhieu lan khong ghi de secret da co.
#
#   ./setup.sh                     # setup + up -d
#   ./setup.sh --with-claude-code  # build image co CLI `claude` tu Dockerfile
#   ./setup.sh --no-start          # chi tao file config, khong up
#   ./setup.sh --non-interactive   # khong hoi gi, tu sinh ca mat khau dang nhap
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
    *)                  die "tham so khong hop le: $1  (dung --help)" ;;
  esac
  shift
done

# --------------------------------------------------------------- helpers ----

# Ghi KEY=VALUE vao file .env — thay dong cu neu co, khong thi them vao cuoi.
# Dung awk thay `sed -i` cho chay duoc ca tren macOS lan GNU.
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

# Dien secret ngau nhien neu key dang trong. Tra ve 0 neu vua sinh moi.
fill_secret() {
  local file="$1" key="$2" val
  val="$(get_kv "$key" "$file")"
  if [ -z "$val" ]; then
    set_kv "$file" "$key" "$(openssl rand -hex 32)"
    return 0
  fi
  return 1
}

# Hoi mat khau dang nhap, go 2 lan de xac nhan, khong hien ky tu.
# In prompt ra stderr, chi in ket qua ra stdout de goi ham bat duoc bang $().
# Ket qua co prefix: `usr:` = nguoi dung go, `gen:` = tu sinh ngau nhien.
# (Ham chay trong subshell nen khong set duoc bien toan cuc — phai bao qua stdout.)
# Enter rong => tu sinh ngau nhien.
prompt_password() {
  local label="$1" min="${2:-8}" p1 p2 tries=0

  # Khong co TTY hoac chay --non-interactive => tu sinh, khong hoi.
  if [ "$NON_INTERACTIVE" = 1 ] || [ ! -r /dev/tty ]; then
    printf 'gen:%s\n' "$(openssl rand -hex 16)"
    return 0
  fi

  while :; do
    # Chan vong lap vo han khi stdin bi dong giua chung.
    tries=$((tries + 1))
    if [ "$tries" -gt 5 ]; then
      printf '    %s!!%s qua 5 lan khong hop le — dung lai\n' "$C_RED" "$C_RESET" >&2
      return 1
    fi

    printf '    %s%s%s (Enter = tu sinh ngau nhien): ' "$C_BOLD" "$label" "$C_RESET" >&2
    IFS= read -rs p1 < /dev/tty || true
    printf '\n' >&2

    if [ -z "$p1" ]; then
      printf 'gen:%s\n' "$(openssl rand -hex 16)"
      return 0
    fi

    # `$` trong .env bi docker compose hieu la bien va nuot mat phan sau —
    # `ab$cde` vao container thanh `ab`. Chan tu dau thay vi escape.
    case "$p1" in
      *'$'*)  printf '    %s!!%s khong dung ky tu $ (docker compose se hieu la bien)\n' \
                "$C_YELLOW" "$C_RESET" >&2; continue ;;
      *'`'*)  printf '    %s!!%s khong dung ky tu `\n' "$C_YELLOW" "$C_RESET" >&2; continue ;;
      ' '*|*' ') printf '    %s!!%s khong de khoang trang o dau/cuoi\n' \
                "$C_YELLOW" "$C_RESET" >&2; continue ;;
    esac

    if [ "${#p1}" -lt "$min" ]; then
      printf '    %s!!%s toi thieu %s ky tu (dang co %s)\n' \
        "$C_YELLOW" "$C_RESET" "$min" "${#p1}" >&2
      continue
    fi

    printf '    Nhap lai de xac nhan: ' >&2
    IFS= read -rs p2 < /dev/tty || true
    printf '\n' >&2

    if [ "$p1" != "$p2" ]; then
      printf '    %s!!%s hai lan nhap khong khop, thu lai\n' "$C_YELLOW" "$C_RESET" >&2
      continue
    fi

    printf 'usr:%s\n' "$p1"
    return 0
  done
}

# Shell khong tu expand `~` khi no den tu bien — lam thu cong.
expand_tilde() {
  case "$1" in
    "~")   printf '%s\n' "$HOME" ;;
    "~"/*) printf '%s\n' "$HOME/${1#\~/}" ;;
    *)     printf '%s\n' "$1" ;;
  esac
}

# ------------------------------------------------------------- preflight ----
info "Kiem tra moi truong"

command -v docker  >/dev/null 2>&1 || die "chua cai docker"
command -v openssl >/dev/null 2>&1 || die "chua cai openssl"
docker compose version >/dev/null 2>&1 || die "can docker compose v2 (plugin), khong phai docker-compose v1"
docker info >/dev/null 2>&1 || die "docker daemon khong chay"

for f in docker-compose.yml .env.example 9router.env.example; do
  [ -f "$f" ] || die "thieu file $f — chay script tu trong thu muc repo"
done
ok "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null), compose $(docker compose version --short)"

# ------------------------------------------------------------------ .env ----
info "Chuan bi .env (config cua hermes)"

if [ ! -f .env ]; then
  cp .env.example .env
  ok "tao .env tu .env.example"
else
  ok ".env da co — giu nguyen gia tri hien tai"
fi

# Secret ky session — khong ai go tay, tu sinh.
fill_secret .env HERMES_DASHBOARD_SECRET && ok "sinh HERMES_DASHBOARD_SECRET"

# Tai khoan dang nhap dashboard — hoi nguoi dung.
DASH_PASS_PROMPTED=0
if [ -z "$(get_kv HERMES_DASHBOARD_PASSWORD .env)" ]; then
  printf '\n  %sTai khoan dang nhap Hermes dashboard%s\n' "$C_BOLD" "$C_RESET"

  if [ "$NON_INTERACTIVE" = 0 ] && [ -r /dev/tty ]; then
    printf '    Username [admin]: ' >&2
    IFS= read -r dash_user < /dev/tty || true
    set_kv .env HERMES_DASHBOARD_USER "${dash_user:-admin}"
  else
    [ -n "$(get_kv HERMES_DASHBOARD_USER .env)" ] || set_kv .env HERMES_DASHBOARD_USER admin
  fi

  dash_raw="$(prompt_password 'Password' 8)" \
    || die "khong dat duoc mat khau dashboard — chay lai setup.sh"
  case "$dash_raw" in
    usr:*) dash_pass="${dash_raw#usr:}"; DASH_PASS_PROMPTED=1 ;;
    gen:*) dash_pass="${dash_raw#gen:}"; DASH_PASS_PROMPTED=0 ;;
    *)     die "prompt_password tra ve gia tri la — bao loi script" ;;
  esac
  [ -n "$dash_pass" ] || die "mat khau dashboard rong — chay lai setup.sh"
  set_kv .env HERMES_DASHBOARD_PASSWORD "$dash_pass"
  [ "$DASH_PASS_PROMPTED" = 1 ] && ok "da dat mat khau dashboard" \
                               || ok "tu sinh mat khau dashboard"
  printf '\n'
else
  ok "HERMES_DASHBOARD_PASSWORD da co — giu nguyen"
  [ -n "$(get_kv HERMES_DASHBOARD_USER .env)" ] || set_kv .env HERMES_DASHBOARD_USER admin
fi

# ----------------------------------------------------------- 9router.env ----
info "Chuan bi 9router.env"

if [ ! -f 9router.env ]; then
  cp 9router.env.example 9router.env
  ok "tao 9router.env tu 9router.env.example"
else
  ok "9router.env da co — giu nguyen gia tri hien tai"
fi

# Secret noi bo — tu sinh.
fill_secret 9router.env JWT_SECRET      && ok "sinh JWT_SECRET"
fill_secret 9router.env API_KEY_SECRET  && ok "sinh API_KEY_SECRET"
fill_secret 9router.env MACHINE_ID_SALT && ok "sinh MACHINE_ID_SALT"

# Mat khau dang nhap 9router — hoi nguoi dung.
ROUTER_PASS_PROMPTED=0
if [ -z "$(get_kv INITIAL_PASSWORD 9router.env)" ]; then
  printf '\n  %sMat khau dang nhap 9router%s\n' "$C_BOLD" "$C_RESET"
  router_raw="$(prompt_password 'Password' 8)" \
    || die "khong dat duoc mat khau 9router — chay lai setup.sh"
  case "$router_raw" in
    usr:*) router_pass="${router_raw#usr:}"; ROUTER_PASS_PROMPTED=1 ;;
    gen:*) router_pass="${router_raw#gen:}"; ROUTER_PASS_PROMPTED=0 ;;
    *)     die "prompt_password tra ve gia tri la — bao loi script" ;;
  esac
  [ -n "$router_pass" ] || die "mat khau 9router rong — chay lai setup.sh"
  set_kv 9router.env INITIAL_PASSWORD "$router_pass"
  [ "$ROUTER_PASS_PROMPTED" = 1 ] && ok "da dat mat khau 9router" \
                                 || ok "tu sinh mat khau 9router"
  printf '\n'
else
  ok "INITIAL_PASSWORD da co — giu nguyen"
fi

chmod 600 .env 9router.env 2>/dev/null || true

# ------------------------------------------------------------- data dirs ----
info "Tao thu muc du lieu"

HERMES_DATA_DIR="$(expand_tilde "$(get_kv HERMES_DATA_DIR .env)")"
ROUTER_DATA_DIR="$(expand_tilde "$(get_kv ROUTER_DATA_DIR .env)")"
: "${HERMES_DATA_DIR:=$HOME/.hermes}"
: "${ROUTER_DATA_DIR:=$HOME/.9router}"

mkdir -p "$HERMES_DATA_DIR" "$ROUTER_DATA_DIR"
ok "$HERMES_DATA_DIR"
ok "$ROUTER_DATA_DIR"

# ----------------------------------------------------- claude-code build ----
OVERRIDE_FILE=docker-compose.override.yml

if [ "$WITH_CLAUDE_CODE" = 1 ]; then
  [ -f Dockerfile ] || die "--with-claude-code can file Dockerfile"
  cat > "$OVERRIDE_FILE" <<'YAML'
# Sinh boi setup.sh --with-claude-code. File nay bi .gitignore bo qua.
services:
  hermes:
    build: .
    image: hermes-claude:latest
YAML
  ok "tao $OVERRIDE_FILE — hermes se build tu Dockerfile (co CLI claude)"
elif [ -f "$OVERRIDE_FILE" ] && grep -q 'setup.sh --with-claude-code' "$OVERRIDE_FILE" 2>/dev/null; then
  ok "$OVERRIDE_FILE da co — van build image co CLI claude"
fi

# ------------------------------------------------------------ validate -----
info "Kiem tra docker-compose.yml"
docker compose config >/dev/null || die "docker-compose.yml khong hop le (xem loi o tren)"
ok "config hop le"

if [ "$NO_START" = 1 ]; then
  printf '\n%sDa tao xong file config. Bo --no-start de khoi dong stack.%s\n' "$C_BOLD" "$C_RESET"
  exit 0
fi

# --------------------------------------------------------- hermes wizard ----
# Wizard hoi API key cua model va token cac chat platform, ghi vao
# $HERMES_DATA_DIR/.env. Chi can chay mot lan.
if [ ! -f "$HERMES_DATA_DIR/.env" ]; then
  if [ -t 0 ] && [ -t 1 ]; then
    info "Chua co $HERMES_DATA_DIR/.env — can chay setup wizard cua hermes"
    printf '    Chay wizard bay gio? [Y/n] '
    read -r reply
    case "${reply:-Y}" in
      [Nn]*) warn "bo qua — gateway se khong co API key, chay lai sau:"
             warn "  docker run -it --rm -v $HERMES_DATA_DIR:/opt/data nousresearch/hermes-agent setup" ;;
      *)     docker run -it --rm -v "$HERMES_DATA_DIR:/opt/data" nousresearch/hermes-agent setup ;;
    esac
  else
    warn "chua co $HERMES_DATA_DIR/.env va khong co TTY de chay wizard"
    warn "chay tay:  docker run -it --rm -v $HERMES_DATA_DIR:/opt/data nousresearch/hermes-agent setup"
  fi
fi

# ----------------------------------------------------------------- start ----
info "Khoi dong stack"
if [ "$WITH_CLAUDE_CODE" = 1 ]; then
  docker compose up -d --build
else
  docker compose up -d
fi

info "Cho container on dinh"
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
printf '%s  Deploy xong%s\n' "$C_BOLD" "$C_RESET"
printf '%s========================================================%s\n\n' "$C_BOLD" "$C_RESET"

printf '%sTruy cap%s\n' "$C_BOLD" "$C_RESET"
printf '  Hermes dashboard   http://%s:%s\n' "$BIND_ADDR" "$DASH_PORT"
printf '  9router            http://%s:%s\n' "$BIND_ADDR" "$ROUTER_PORT"
printf '  Hermes API         http://%s:%s  %s(chi khi bat API_SERVER_ENABLED)%s\n\n' \
  "$BIND_ADDR" "$API_PORT" "$C_DIM" "$C_RESET"

printf '%sDang nhap%s\n' "$C_BOLD" "$C_RESET"
if [ "$DASH_PASS_PROMPTED" = 1 ]; then
  printf '  Dashboard  %s / %s(mat khau ban vua nhap)%s\n' "$DASH_USER" "$C_DIM" "$C_RESET"
else
  printf '  Dashboard  %s / %s\n' "$DASH_USER" "$DASH_PASS"
fi
if [ "$ROUTER_PASS_PROMPTED" = 1 ]; then
  printf '  9router    %s(mat khau ban vua nhap)%s\n' "$C_DIM" "$C_RESET"
else
  printf '  9router    password: %s\n' "$ROUTER_PASS"
fi
printf '  %sQuen thi doc lai: grep PASSWORD .env 9router.env%s\n\n' "$C_DIM" "$C_RESET"

if [ "$BIND_ADDR" = "127.0.0.1" ]; then
  printf '%sVao tu may khac%s\n' "$C_BOLD" "$C_RESET"
  printf '  Cong dang bind loopback. Dung SSH tunnel:\n'
  printf '    ssh -L %s:127.0.0.1:%s -L %s:127.0.0.1:%s user@<host>\n' \
    "$DASH_PORT" "$DASH_PORT" "$ROUTER_PORT" "$ROUTER_PORT"
  printf '  %sDoi HERMES_BIND_ADDR=0.0.0.0 trong .env de mo ra ngoai — doc README truoc.%s\n\n' \
    "$C_DIM" "$C_RESET"
fi

printf '%sDu lieu%s\n' "$C_BOLD" "$C_RESET"
printf '  Hermes   %s\n' "$HERMES_DATA_DIR"
printf '  9router  %s\n\n' "$ROUTER_DATA_DIR"

printf '%sNoi hermes voi 9router%s\n' "$C_BOLD" "$C_RESET"
printf '  Sua %s/config.yaml:\n' "$HERMES_DATA_DIR"
printf '    model:\n'
printf '      provider: custom\n'
printf '      model: <ten-model-tren-9router>\n'
printf '      base_url: http://9router:20128/v1\n'
printf '      api_key: "none"\n'
printf '  Roi: docker compose restart hermes\n\n'

printf '%sLenh hay dung%s\n' "$C_BOLD" "$C_RESET"
printf '  docker compose logs -f              # log realtime\n'
printf '  docker compose ps                   # trang thai\n'
printf '  docker compose restart hermes       # restart 1 service\n'
printf '  docker compose down                 # dung stack\n'
printf '  docker exec -it hermes hermes       # mo CLI chat\n'
printf '  docker exec hermes hermes status    # trang thai gateway\n'
if [ "$WITH_CLAUDE_CODE" = 1 ]; then
  printf '  docker exec -it hermes env HOME=/opt/data/home claude   # CLI claude\n'
fi
printf '\n'
