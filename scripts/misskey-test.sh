#!/usr/bin/env bash
# 空DBへのマイグレーションとapp healthcheck確認
set -euo pipefail

cd "$(dirname "$0")/../test"

project=misskey-blue-test
compose() {
  docker compose -p "$project" -f compose.yaml "$@"
}

cleanup() {
  compose down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

cleanup
if ! compose up -d --wait --wait-timeout "${WAIT_TIMEOUT:-600}" app; then
  compose ps -a
  compose logs --no-color
  echo "app did not become healthy" >&2
  exit 1
fi
compose ps
echo "app is healthy"
