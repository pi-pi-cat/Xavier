#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUICK_RUN="$ROOT_DIR/quick-run.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aws-route-test.XXXXXX")"

cleanup() {
  rm -rf "$TEST_DIR"
}

trap cleanup EXIT

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

cat >"$TEST_DIR/fake-curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

output=""
url=""
accept=0
authorization=0
api_version=0
ref=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      output="$2"
      shift 2
      ;;
    -H)
      case "$2" in
        'Accept: application/vnd.github.raw+json') accept=1 ;;
        'Authorization: Bearer test-token') authorization=1 ;;
        'X-GitHub-Api-Version: 2026-03-10') api_version=1 ;;
      esac
      shift 2
      ;;
    --data-urlencode)
      [ "$2" = 'ref=test-ref' ] && ref=1
      shift 2
      ;;
    https://*)
      url="$1"
      shift
      ;;
    *) shift ;;
  esac
done

[ -n "$output" ] || exit 10
relative_path="${url#*/contents/Scripts/aws/}"
[ "$relative_path" != "$url" ] || exit 11
cp "$FAKE_SOURCE_DIR/$relative_path" "$output"
printf '%s %s %s %s\n' "$accept" "$authorization" "$api_version" "$ref" >>"$FAKE_CURL_LOG"
EOF
chmod +x "$TEST_DIR/fake-curl"

output="$(
  FAKE_SOURCE_DIR="$ROOT_DIR" \
  FAKE_CURL_LOG="$TEST_DIR/curl.log" \
  AWS_ROUTE_CURL_BIN="$TEST_DIR/fake-curl" \
  AWS_ROUTE_GITHUB_TOKEN=test-token \
  AWS_ROUTE_REF=test-ref \
  "$QUICK_RUN" sg help
)"
printf '%s\n' "$output" | grep -Fq 'Singapore transit EC2' || \
  fail 'private repository API download did not dispatch the cloud script'
[ "$(wc -l <"$TEST_DIR/curl.log" | tr -d ' ')" = "2" ] || \
  fail 'private repository mode did not download both required scripts'
if grep -Fqv '1 1 1 1' "$TEST_DIR/curl.log"; then
  fail 'private repository download omitted a required GitHub API header or ref'
fi

if [ "$(id -u)" -ne 0 ]; then
  cat >"$TEST_DIR/fake-sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"$FAKE_SUDO_LOG"
EOF
  chmod +x "$TEST_DIR/fake-sudo"
  FAKE_SUDO_LOG="$TEST_DIR/sudo.log" \
    AWS_ROUTE_SOURCE_DIR="$ROOT_DIR" \
    AWS_ROUTE_GITHUB_TOKEN=must-not-reach-sudo \
    AWS_ROUTE_SUDO_BIN="$TEST_DIR/fake-sudo" \
    LANDING_PRIVATE_IP=10.20.1.10 \
    "$QUICK_RUN" transit status >/dev/null
  grep -Fq 'LANDING_PRIVATE_IP=10.20.1.10' "$TEST_DIR/sudo.log" || \
    fail 'server environment was not passed through sudo'
  if grep -Fq 'must-not-reach-sudo' "$TEST_DIR/sudo.log"; then
    fail 'GitHub token leaked into the server deployment command'
  fi
fi

printf 'PASS: quick-run dispatch and safety checks\n'
