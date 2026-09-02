#!/usr/bin/env bash

set -Eeuo pipefail

AWS_ROUTE_REPOSITORY="${AWS_ROUTE_REPOSITORY:-pi-pi-cat/Xavier}"
AWS_ROUTE_REF="${AWS_ROUTE_REF:-main}"
AWS_ROUTE_SOURCE_DIR="${AWS_ROUTE_SOURCE_DIR:-}"
AWS_ROUTE_RAW_BASE="${AWS_ROUTE_RAW_BASE:-https://raw.githubusercontent.com/${AWS_ROUTE_REPOSITORY}/${AWS_ROUTE_REF}/Scripts/aws}"
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
bootstrap script. Set AWS_ROUTE_REF to a tag or commit SHA to pin downloads.
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
  case "$AWS_ROUTE_RAW_BASE" in
    https://*) ;;
    *) die "AWS_ROUTE_RAW_BASE must use HTTPS" ;;
  esac
  command -v curl >/dev/null 2>&1 || die "curl is required"
}

fetch_file() {
  local relative_path="$1"
  local destination="$WORK_DIR/$relative_path"

  mkdir -p "$(dirname "$destination")"
  if [ -n "$AWS_ROUTE_SOURCE_DIR" ]; then
    [ -f "$AWS_ROUTE_SOURCE_DIR/$relative_path" ] || \
      die "source file not found: $AWS_ROUTE_SOURCE_DIR/$relative_path"
    cp "$AWS_ROUTE_SOURCE_DIR/$relative_path" "$destination"
  else
    curl -fsSL \
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

  if [ "$#" -eq 0 ]; then
    set -- help
  fi
  if [ ! -t 0 ]; then
    export INTERACTIVE="${INTERACTIVE:-0}"
  fi

  "$WORK_DIR/$entry_path" "$@"
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
