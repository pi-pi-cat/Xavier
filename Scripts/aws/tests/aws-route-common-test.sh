#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLOUD_DIR="$ROOT_DIR/cloud"
LOG_PREFIX="aws-route-test"
NO_COLOR=1
# shellcheck source=../cloud/aws-route-common.sh
source "$CLOUD_DIR/aws-route-common.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_equal() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [ "$expected" = "$actual" ] || fail "$label: expected '$expected', got '$actual'"
}

validate_cidr "10.20.0.0/16" || fail "valid CIDR rejected"
if validate_cidr "10.20.999.0/16"; then
  fail "invalid IPv4 CIDR accepted"
fi
if validate_cidr "10.20.0.0/40"; then
  fail "invalid prefix accepted"
fi

cidrs_overlap "10.20.0.0/16" "10.20.1.0/24" || fail "overlap not detected"
if cidrs_overlap "10.20.0.0/16" "10.21.0.0/16"; then
  fail "non-overlapping CIDRs reported as overlapping"
fi

cidr_contains "10.20.0.0/16" "10.20.1.0/24" || fail "CIDR containment not detected"
if cidr_contains "10.20.0.0/16" "10.21.1.0/24"; then
  fail "invalid CIDR containment accepted"
fi

assert_equal "10.22.0.0/16" \
  "$(choose_free_vpc_cidr '10.20.0.0/16 10.21.12.0/24')" \
  "automatic VPC CIDR"
assert_equal "10.20.3.0/24" \
  "$(choose_free_subnet_cidr '10.20.0.0/16' '10.20.1.0/24 10.20.2.0/24')" \
  "automatic subnet CIDR"

candidate_file="$(new_temp_file aws-route-candidates.XXXXXX)"
awk 'BEGIN {for (i=1; i<=20000; i++) print "type-" i, 2, 1024}' >"$candidate_file"
candidate_names="$(instance_candidate_names "$candidate_file" 10)"
assert_equal "10" "$(word_count "$candidate_names")" "candidate list limit"
assert_equal "type-10" "$(printf '%s\n' "$candidate_names" | awk 'END {print}')" "candidate list last item"

INTERACTIVE=0
AUTO_APPROVE=0
if confirm_action "should not pass" no; then
  fail "non-interactive destructive confirmation was accepted without --yes"
fi
AUTO_APPROVE=1
confirm_action "explicit approval" no || fail "AUTO_APPROVE did not approve confirmation"

"$CLOUD_DIR/aws-route-ec2-sg.sh" --help >/dev/null
"$CLOUD_DIR/aws-route-edge-node.sh" --help >/dev/null

printf 'PASS: aws-route common helpers and CLI help\n'
