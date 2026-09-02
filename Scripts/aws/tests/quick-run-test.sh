#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUICK_RUN="$ROOT_DIR/quick-run.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_help() {
  local component="$1"
  local expected="$2"
  local output

  output="$(AWS_ROUTE_SOURCE_DIR="$ROOT_DIR" "$QUICK_RUN" "$component" help)"
  printf '%s\n' "$output" | grep -Fq "$expected" || \
    fail "$component help did not contain: $expected"
}

assert_help sg 'Create or reuse the Singapore transit EC2'
assert_help edge 'Interactive create asks only for a target Region and AZ'
assert_help transit 'configures only host-local forwarding'
assert_help landing 'configures a local sing-box Shadowsocks landing service'

output="$(AWS_ROUTE_SOURCE_DIR="$ROOT_DIR" "$QUICK_RUN" transit)"
printf '%s\n' "$output" | grep -Fq 'Usage:' || fail 'missing action did not default to help'

output="$(AWS_ROUTE_SOURCE_DIR="$ROOT_DIR" bash -s -- landing help <"$QUICK_RUN")"
printf '%s\n' "$output" | grep -Fq 'Shadowsocks landing service' || \
  fail 'stdin bootstrap execution did not dispatch landing help'

if AWS_ROUTE_SOURCE_DIR="$ROOT_DIR" "$QUICK_RUN" sg create >/dev/null 2>&1; then
  fail 'mutating cloud action was accepted without --yes'
fi
if AWS_ROUTE_SOURCE_DIR="$ROOT_DIR" bash -s -- transit install <"$QUICK_RUN" >/dev/null 2>&1; then
  fail 'stdin bootstrap accepted a mutating action without --yes'
fi
if AWS_ROUTE_SOURCE_DIR="$ROOT_DIR" "$QUICK_RUN" landing install >/dev/null 2>&1; then
  fail 'mutating server action was accepted without --yes'
fi
if AWS_ROUTE_RAW_BASE=http://example.com "$QUICK_RUN" sg help >/dev/null 2>&1; then
  fail 'insecure download URL was accepted'
fi
if AWS_ROUTE_SOURCE_DIR="$ROOT_DIR" "$QUICK_RUN" unknown help >/dev/null 2>&1; then
  fail 'unknown component was accepted'
fi

printf 'PASS: quick-run dispatch and safety checks\n'
