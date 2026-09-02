#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER_DIR="$ROOT_DIR/server"
LOG_PREFIX="route-local-test"
NO_COLOR=1
# shellcheck source=../server/route-local-common.sh
source "$SERVER_DIR/route-local-common.sh"

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

validate_ipv4_value 10.20.1.180 || fail "valid IPv4 rejected"
if validate_ipv4_value 10.20.999.180; then fail "invalid IPv4 accepted"; fi
if validate_ipv4_value 10.20.1; then fail "short IPv4 accepted"; fi
is_private_ipv4 172.31.38.217 || fail "private IPv4 rejected"
if is_private_ipv4 8.8.8.8; then fail "public IPv4 accepted as private"; fi

validate_port_value 8388 || fail "valid port rejected"
if validate_port_value 0; then fail "zero port accepted"; fi
if validate_port_value 65536; then fail "out-of-range port accepted"; fi

validate_password_value 7d2fe2273776cda80ab0806261fe4fd649e7ff5bf005e6ad || fail "valid password rejected"
if validate_password_value short; then fail "short password accepted"; fi
if validate_password_value 'password with spaces'; then fail "unsafe password accepted"; fi

assert_equal 'YWVzLTEyOC1nY206cGFzc3dvcmQ' \
  "$(base64url_encode 'aes-128-gcm:password')" \
  'SS userinfo encoding'
assert_equal 'Lagos-SS' "$(safe_fragment 'Lagos SS')" 'node name fragment'
assert_equal '[2001:db8::1]' "$(format_endpoint '2001:db8::1')" 'IPv6 endpoint formatting'
assert_equal 'secret12...1234' "$(mask_secret secret1234)" 'secret masking'

AUTO_APPROVE=1
confirm_exact "test" "unused" || fail "AUTO_APPROVE did not approve exact confirmation"
AUTO_APPROVE=0

"$SERVER_DIR/deploy-transit.sh" --help >/dev/null
"$SERVER_DIR/deploy-landing-ss.sh" --help >/dev/null

bash -n "$SERVER_DIR/route-local-common.sh" \
  "$SERVER_DIR/deploy-transit.sh" \
  "$SERVER_DIR/deploy-landing-ss.sh"

if grep -En '(^|[[:space:]])aws[[:space:]]+(configure|sts|ec2|lightsail)|169\.254\.169\.254' \
  "$SERVER_DIR/route-local-common.sh" \
  "$SERVER_DIR/deploy-transit.sh" \
  "$SERVER_DIR/deploy-landing-ss.sh"; then
  fail 'deployment scripts contain AWS CLI or metadata calls'
fi

printf 'PASS: local route helpers and deployment script safety checks\n'
