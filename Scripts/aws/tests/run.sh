#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n \
  "$ROOT_DIR/quick-run.sh" \
  "$ROOT_DIR/cloud/aws-route-common.sh" \
  "$ROOT_DIR/cloud/aws-route-ec2-sg.sh" \
  "$ROOT_DIR/cloud/aws-route-edge-node.sh" \
  "$ROOT_DIR/server/route-local-common.sh" \
  "$ROOT_DIR/server/deploy-transit.sh" \
  "$ROOT_DIR/server/deploy-landing-ss.sh" \
  "$ROOT_DIR/tests/aws-route-common-test.sh" \
  "$ROOT_DIR/tests/route-local-test.sh" \
  "$ROOT_DIR/tests/quick-run-test.sh"

"$ROOT_DIR/tests/aws-route-common-test.sh"
"$ROOT_DIR/tests/route-local-test.sh"
"$ROOT_DIR/tests/quick-run-test.sh"

printf 'PASS: all AWS route tests\n'
