#!/usr/bin/env bash

set -Eeuo pipefail

AWS_ROUTE_REPOSITORY="${AWS_ROUTE_REPOSITORY:-pi-pi-cat/Xavier}"
AWS_ROUTE_REF="${AWS_ROUTE_REF:-main}"
AWS_ROUTE_SOURCE_DIR="${AWS_ROUTE_SOURCE_DIR:-}"
AWS_ROUTE_RAW_BASE="${AWS_ROUTE_RAW_BASE:-https://raw.githubusercontent.com/${AWS_ROUTE_REPOSITORY}/${AWS_ROUTE_REF}/Scripts/aws}"
AWS_ROUTE_GITHUB_TOKEN="${AWS_ROUTE_GITHUB_TOKEN:-${GH_TOKEN:-${GITHUB_TOKEN:-}}}"
AWS_ROUTE_GITHUB_API_BASE="${AWS_ROUTE_GITHUB_API_BASE:-https://api.github.com}"
AWS_ROUTE_GITHUB_API_VERSION="${AWS_ROUTE_GITHUB_API_VERSION:-2026-03-10}"
AWS_ROUTE_CURL_BIN="${AWS_ROUTE_CURL_BIN:-curl}"
AWS_ROUTE_USE_SUDO="${AWS_ROUTE_USE_SUDO:-auto}"
AWS_ROUTE_SUDO_BIN="${AWS_ROUTE_SUDO_BIN:-sudo}"
AWS_ROUTE_KEEP_TEMP="${AWS_ROUTE_KEEP_TEMP:-0}"

WORK_DIR=""

show_help() {
  cat <<'EOF'
Usage:
  quick-run.sh sg [create|status|delete|help] [options]
  quick-run.sh edge [create|status|delete|help] [arguments] [options]
  quick-run.sh transit [install|status|remove|help] [options]
  quick-run.sh landing [install|status|generate-node|show-credentials|remove|help] [options]

Aliases:
  ec2-sg -> sg
  edge-node -> edge

Mutating actions require --yes or AUTO_APPROVE=1 when launched through this
bootstrap script. Private GitHub repositories require AWS_ROUTE_GITHUB_TOKEN.
Set AWS_ROUTE_REF to a tag or commit SHA to pin downloads. Server components
automatically use sudo when the current user is not root.
EOF
}

die() {
  printf 'quick-run: %s\n' "$*" >&2
  exit 1
}

is_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|y|Y|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

has_yes_option() {
  local argument
  is_true "${AUTO_APPROVE:-0}" && return 0
  for argument in "$@"; do
    case "$argument" in
      -y|--yes) return 0 ;;
    esac
  done
  return 1
}

is_mutating_action() {
  local component="$1"
  local action="$2"

  case "$component:$action" in
    sg:create|sg:delete|edge:create|edge:delete|transit:install|transit:remove|landing:install|landing:generate-node|landing:remove)
      return 0
      ;;
    *) return 1 ;;
  esac
}

cleanup() {
  [ -n "$WORK_DIR" ] || return 0
  if is_true "$AWS_ROUTE_KEEP_TEMP"; then
    printf 'quick-run: kept temporary files at %s\n' "$WORK_DIR" >&2
  else
    rm -rf "$WORK_DIR"
  fi
}

validate_source() {
  if [ -n "$AWS_ROUTE_SOURCE_DIR" ]; then
    [ -d "$AWS_ROUTE_SOURCE_DIR" ] || die "AWS_ROUTE_SOURCE_DIR is not a directory: $AWS_ROUTE_SOURCE_DIR"
    return 0
  fi

  case "$AWS_ROUTE_REPOSITORY" in
    ''|/*|*/|*..*|*[!A-Za-z0-9._/-]*) die "invalid AWS_ROUTE_REPOSITORY" ;;
  esac
  case "$AWS_ROUTE_REF" in
    ''|/*|*/|*..*|*[!A-Za-z0-9._/-]*) die "invalid AWS_ROUTE_REF" ;;
  esac
  command -v "$AWS_ROUTE_CURL_BIN" >/dev/null 2>&1 || die "$AWS_ROUTE_CURL_BIN is required"

  if [ -n "$AWS_ROUTE_GITHUB_TOKEN" ]; then
    case "$AWS_ROUTE_GITHUB_API_BASE" in
      https://*) ;;
      *) die "AWS_ROUTE_GITHUB_API_BASE must use HTTPS" ;;
    esac
  else
    case "$AWS_ROUTE_RAW_BASE" in
      https://*) ;;
      *) die "AWS_ROUTE_RAW_BASE must use HTTPS" ;;
    esac
  fi
}

fetch_file() {
  local relative_path="$1"
  local destination="$WORK_DIR/$relative_path"

  mkdir -p "$(dirname "$destination")"
  if [ -n "$AWS_ROUTE_SOURCE_DIR" ]; then
    [ -f "$AWS_ROUTE_SOURCE_DIR/$relative_path" ] || \
      die "source file not found: $AWS_ROUTE_SOURCE_DIR/$relative_path"
    cp "$AWS_ROUTE_SOURCE_DIR/$relative_path" "$destination"
  elif [ -n "$AWS_ROUTE_GITHUB_TOKEN" ]; then
    "$AWS_ROUTE_CURL_BIN" -fsSL \
      --proto '=https' \
      --proto-redir '=https' \
      --tlsv1.2 \
      --retry 3 \
      --connect-timeout 10 \
      --max-time 90 \
      -H 'Accept: application/vnd.github.raw+json' \
      -H "Authorization: Bearer $AWS_ROUTE_GITHUB_TOKEN" \
      -H "X-GitHub-Api-Version: $AWS_ROUTE_GITHUB_API_VERSION" \
      --get \
      --data-urlencode "ref=$AWS_ROUTE_REF" \
      "${AWS_ROUTE_GITHUB_API_BASE%/}/repos/${AWS_ROUTE_REPOSITORY}/contents/Scripts/aws/$relative_path" \
      -o "$destination"
  else
    "$AWS_ROUTE_CURL_BIN" -fsSL \
      --proto '=https' \
      --proto-redir '=https' \
      --tlsv1.2 \
      --retry 3 \
      --connect-timeout 10 \
      --max-time 90 \
      "$AWS_ROUTE_RAW_BASE/$relative_path" \
      -o "$destination"
  fi
  chmod 700 "$destination"
}

run_entry() {
  local component="$1"
  local action="$2"
  local entry_path="$3"
  shift 3
  local name value
  local sudo_environment=()

  case "$component:$action:$AWS_ROUTE_USE_SUDO:$(id -u)" in
    transit:help:*:*|landing:help:*:*|transit:*:0:*|transit:*:false:*|landing:*:0:*|landing:*:false:*|transit:*:*:0|landing:*:*:0)
      "$entry_path" "$@"
      return
      ;;
    transit:*:*:*|landing:*:*:*)
      command -v "$AWS_ROUTE_SUDO_BIN" >/dev/null 2>&1 || \
        die "$AWS_ROUTE_SUDO_BIN is required to run server components as root"
      for name in \
        AUTO_APPROVE INTERACTIVE NO_COLOR BACKUP_ROOT STATE_ROOT STATE_FILE \
        CONFIG_DIR CONFIG_FILE CREDENTIALS_FILE NODE_FILE UNIT_FILE LISTEN_PORT \
        SS_METHOD NODE_ADDRESS NODE_PORT NODE_NAME SING_BOX_BIN SING_BOX_VERSION \
        SS_PASSWORD NFT_FILE APPLY_FILE SYSCTL_FILE LANDING_PRIVATE_IP FORWARD_PORT \
        TRANSIT_INTERFACE TRANSIT_PRIVATE_IP; do
        value="${!name-}"
        [ -n "$value" ] && sudo_environment+=("$name=$value")
      done
      "$AWS_ROUTE_SUDO_BIN" env "${sudo_environment[@]}" "$entry_path" "$@"
      ;;
    *) "$entry_path" "$@" ;;
  esac
}

run_component() {
  local component="$1"
  shift
  local action="${1:-help}"
  local common_path entry_path

  if is_mutating_action "$component" "$action" && ! has_yes_option "$@"; then
    die "$component $action changes resources; rerun with --yes or AUTO_APPROVE=1"
  fi

  case "$component" in
    sg)
      common_path="cloud/aws-route-common.sh"
      entry_path="cloud/aws-route-ec2-sg.sh"
      ;;
    edge)
      common_path="cloud/aws-route-common.sh"
      entry_path="cloud/aws-route-edge-node.sh"
      ;;
    transit)
      common_path="server/route-local-common.sh"
      entry_path="server/deploy-transit.sh"
      ;;
    landing)
      common_path="server/route-local-common.sh"
      entry_path="server/deploy-landing-ss.sh"
      ;;
    *) die "unknown component: $component" ;;
  esac

  validate_source
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aws-route.XXXXXX")"
  trap cleanup EXIT
  fetch_file "$common_path"
  fetch_file "$entry_path"
  bash -n "$WORK_DIR/$common_path" "$WORK_DIR/$entry_path"
  unset AWS_ROUTE_GITHUB_TOKEN GH_TOKEN GITHUB_TOKEN

  if [ "$#" -eq 0 ]; then
    set -- help
  fi
  if [ ! -t 0 ]; then
    export INTERACTIVE="${INTERACTIVE:-0}"
  fi

  run_entry "$component" "$action" "$WORK_DIR/$entry_path" "$@"
}

component="${1:-help}"
case "$component" in
  help|-h|--help)
    show_help
    exit 0
    ;;
  ec2-sg) component="sg" ;;
  edge-node) component="edge" ;;
esac
shift

run_component "$component" "$@"
