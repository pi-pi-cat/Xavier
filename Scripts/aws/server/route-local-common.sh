#!/usr/bin/env bash

# Shared helpers for the host-local transit and landing scripts.
# Callers enable strict mode before sourcing this file.

LOG_PREFIX="${LOG_PREFIX:-aws-route}"
INTERACTIVE="${INTERACTIVE:-auto}"
AUTO_APPROVE="${AUTO_APPROVE:-0}"
NO_COLOR="${NO_COLOR:-0}"

BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/aws-route}"
STATE_ROOT="${STATE_ROOT:-/etc/aws-route}"
BACKUP_PATH=""

if [ -t 1 ] && [ "$NO_COLOR" != "1" ]; then
  COLOR_BLUE='\033[34m'
  COLOR_GREEN='\033[32m'
  COLOR_YELLOW='\033[33m'
  COLOR_RED='\033[31m'
  COLOR_RESET='\033[0m'
else
  COLOR_BLUE=''
  COLOR_GREEN=''
  COLOR_YELLOW=''
  COLOR_RED=''
  COLOR_RESET=''
fi

log() {
  printf '[%s] %s\n' "$LOG_PREFIX" "$*"
}

detail() {
  printf '  %s\n' "$*"
}

warn() {
  printf '%b[%s] WARNING: %s%b\n' "$COLOR_YELLOW" "$LOG_PREFIX" "$*" "$COLOR_RESET" >&2
}

die() {
  printf '%b[%s] ERROR: %s%b\n' "$COLOR_RED" "$LOG_PREFIX" "$*" "$COLOR_RESET" >&2
  exit 1
}

step() {
  printf '\n%b==> %s%b\n' "$COLOR_BLUE" "$*" "$COLOR_RESET"
}

ok() {
  printf '%bPASS%b %s\n' "$COLOR_GREEN" "$COLOR_RESET" "$*"
}

is_interactive() {
  [ "$INTERACTIVE" != "0" ] && [ "$INTERACTIVE" != "false" ] && [ -t 0 ] && [ -t 1 ]
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "run this script as root, for example: sudo $0"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required but is not installed"
}

require_private_file() {
  local path="$1"
  local owner mode

  [ -f "$path" ] || return 0
  require_command stat
  owner="$(stat -c '%u' "$path")"
  mode="$(stat -c '%a' "$path")"
  [ "$owner" = "0" ] && [ "$mode" = "600" ] || \
    die "refusing to read insecure file $path; expected root:root mode 600"
}

is_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|y|Y|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

prompt_with_default() {
  local prompt="$1"
  local default_value="$2"
  local answer

  if ! is_interactive; then
    printf '%s\n' "$default_value"
    return 0
  fi

  printf '%s [%s]: ' "$prompt" "$default_value" >&2
  IFS= read -r answer || true
  printf '%s\n' "${answer:-$default_value}"
}

prompt_required() {
  local prompt="$1"
  local answer

  is_interactive || die "$prompt is required in non-interactive mode"
  while :; do
    printf '%s: ' "$prompt" >&2
    IFS= read -r answer || die "input was interrupted"
    [ -n "$answer" ] && {
      printf '%s\n' "$answer"
      return 0
    }
    warn "$prompt cannot be empty"
  done
}

prompt_secret() {
  local prompt="$1"
  local answer

  is_interactive || die "$prompt is required in non-interactive mode"
  printf '%s: ' "$prompt" >&2
  IFS= read -r -s answer || die "input was interrupted"
  printf '\n' >&2
  printf '%s\n' "$answer"
}

confirm_action() {
  local prompt="$1"
  local default_answer="${2:-no}"
  local answer suffix

  is_true "$AUTO_APPROVE" && return 0
  if ! is_interactive; then
    [ "$default_answer" = "yes" ]
    return
  fi

  if [ "$default_answer" = "yes" ]; then
    suffix='[Y/n]'
  else
    suffix='[y/N]'
  fi

  printf '%s %s ' "$prompt" "$suffix" >&2
  IFS= read -r answer || true
  if [ -z "$answer" ]; then
    [ "$default_answer" = "yes" ]
    return
  fi
  is_true "$answer"
}

confirm_exact() {
  local prompt="$1"
  local expected="$2"
  local answer

  is_true "$AUTO_APPROVE" && return 0
  is_interactive || die "this destructive action requires an interactive terminal"
  printf '%s\nType %s to continue: ' "$prompt" "$expected" >&2
  IFS= read -r answer || true
  [ "$answer" = "$expected" ]
}

validate_port_value() {
  local value="$1"
  case "$value" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$value" -ge 1 ] && [ "$value" -le 65535 ]
}

validate_ipv4_value() {
  printf '%s\n' "$1" | awk -F. '
    NF == 4 {
      good = 1
      for (i = 1; i <= 4; i++) {
        if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) good = 0
      }
    }
    END { exit !(good == 1) }
  '
}

is_private_ipv4() {
  validate_ipv4_value "$1" || return 1
  case "$1" in
    10.*|192.168.*|172.16.*|172.17.*|172.18.*|172.19.*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
    *) return 1 ;;
  esac
}

validate_interface_name() {
  case "$1" in
    ''|*[!A-Za-z0-9_.:-]*) return 1 ;;
    *) return 0 ;;
  esac
}

validate_node_address() {
  local value="$1"
  [ -n "$value" ] || return 1
  case "$value" in
    *[!A-Za-z0-9_.:-]*|.*|*-|*.) return 1 ;;
  esac
  return 0
}

validate_password_value() {
  local value="$1"
  [ "${#value}" -ge 24 ] && [ "${#value}" -le 128 ] || return 1
  case "$value" in
    *[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

detect_os() {
  [ -r /etc/os-release ] || die "/etc/os-release is missing"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_VERSION_ID="${VERSION_ID:-unknown}"
  OS_PRETTY_NAME="${PRETTY_NAME:-$OS_ID $OS_VERSION_ID}"
}

require_supported_debian() {
  detect_os
  [ "$OS_ID" = "debian" ] || die "supported operating system: Debian 12 or 13; detected $OS_PRETTY_NAME"
  case "$OS_VERSION_ID" in
    12|13) ;;
    *) die "supported Debian versions: 12 or 13; detected $OS_PRETTY_NAME" ;;
  esac
}

detect_primary_route() {
  local route
  route="$(ip -4 route get 1.1.1.1 2>/dev/null | head -n 1 || true)"
  PRIMARY_INTERFACE="$(printf '%s\n' "$route" | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") print $(i + 1)}')"
  PRIMARY_PRIVATE_IP="$(printf '%s\n' "$route" | awk '{for (i = 1; i <= NF; i++) if ($i == "src") print $(i + 1)}')"

  if [ -z "$PRIMARY_INTERFACE" ]; then
    PRIMARY_INTERFACE="$(ip -4 route show default 2>/dev/null | awk 'NR == 1 {print $5}')"
  fi
  if [ -z "$PRIMARY_PRIVATE_IP" ] && [ -n "$PRIMARY_INTERFACE" ]; then
    PRIMARY_PRIVATE_IP="$(ip -4 -o addr show dev "$PRIMARY_INTERFACE" scope global 2>/dev/null | awk 'NR == 1 {split($4, a, "/"); print a[1]}')"
  fi

  validate_interface_name "$PRIMARY_INTERFACE" || return 1
  validate_ipv4_value "$PRIMARY_PRIVATE_IP" || return 1
}

get_public_ipv4() {
  local url candidate
  require_command curl
  for url in \
    https://api.ipify.org \
    https://icanhazip.com \
    https://ifconfig.me/ip; do
    candidate="$(curl -4fsSL --proto '=https' --tlsv1.2 --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    if validate_ipv4_value "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

generate_hex_password() {
  require_command openssl
  openssl rand -hex 24
}

base64url_encode() {
  require_command openssl
  printf '%s' "$1" | openssl base64 -A | tr '+/' '-_' | tr -d '='
}

format_endpoint() {
  case "$1" in
    *:*) printf '[%s]\n' "$1" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

safe_fragment() {
  printf '%s' "$1" | tr ' ' '-' | tr -cd 'A-Za-z0-9._-'
}

mask_secret() {
  local value="$1"
  [ -n "$value" ] || {
    printf '<unset>\n'
    return 0
  }
  printf '%s...%s\n' "${value%${value#????????}}" "${value: -4}"
}

start_backup() {
  local label="$1"
  BACKUP_PATH="$BACKUP_ROOT/${label}-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  install -d -m 700 "$BACKUP_PATH"
  : >"$BACKUP_PATH/MISSING"
  chmod 600 "$BACKUP_PATH/MISSING"
}

backup_file() {
  local path="$1"
  local key
  [ -n "$BACKUP_PATH" ] || die "backup has not been initialized"
  key="$(printf '%s' "$path" | tr '/' '_')"
  if [ -e "$path" ]; then
    cp -a "$path" "$BACKUP_PATH/$key"
  else
    printf '%s\n' "$path" >>"$BACKUP_PATH/MISSING"
  fi
}

backup_files() {
  local path
  start_backup "$1"
  shift
  for path in "$@"; do
    backup_file "$path"
  done
  printf '%s\n' "$BACKUP_PATH"
}

restore_file() {
  local path="$1"
  local key
  [ -n "$BACKUP_PATH" ] || return 0
  key="$(printf '%s' "$path" | tr '/' '_')"
  if grep -Fxq "$path" "$BACKUP_PATH/MISSING" 2>/dev/null; then
    rm -f "$path"
  elif [ -e "$BACKUP_PATH/$key" ]; then
    install -d -m 755 "$(dirname "$path")"
    rm -rf "$path"
    cp -a "$BACKUP_PATH/$key" "$path"
  fi
}

write_root_file() {
  local content="$1"
  local destination="$2"
  local mode="$3"
  local directory temporary

  directory="$(dirname "$destination")"
  install -d -m 700 "$directory"
  temporary="$(mktemp "$directory/.aws-route-write.XXXXXX")"
  printf '%s' "$content" >"$temporary"
  chmod "$mode" "$temporary"
  chown root:root "$temporary" 2>/dev/null || true
  mv -f "$temporary" "$destination"
  chmod "$mode" "$destination"
  chown root:root "$destination" 2>/dev/null || true
}

print_result() {
  printf '%s=%s\n' "$1" "$2"
}
