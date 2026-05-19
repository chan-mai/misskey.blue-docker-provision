#!/usr/bin/env bash
# Fix: summaly library reads `${dirname}/../../package.json` for User-Agent, but after
# rolldown bundling into /misskey/packages/backend/built/, the path resolves to
# /misskey/packages/package.json which does not exist → ENOENT on every url-preview
# request → OGP never shown. Fix adds one more `../` to reach /misskey/package.json.
set -euo pipefail

CONTAINER_NAME="${1:-misskeyblue-docker-provision-app-1}"
BUILT_DIR="/misskey/packages/backend/built"
PATCH_OLD='}/../../package.json'
PATCH_NEW='}/../../../package.json'

if ! command -v docker >/dev/null 2>&1; then
  echo "docker command not found" >&2
  exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
  echo "container not found: $CONTAINER_NAME" >&2
  exit 1
fi

echo "[1/7] find summaly bundle in container"
TARGET_BASENAME="$(docker exec "$CONTAINER_NAME" sh -c \
  "grep -rl 'SummalyBot' '$BUILT_DIR' 2>/dev/null | head -1")"
if [ -z "$TARGET_BASENAME" ]; then
  echo "summaly bundle not found in $BUILT_DIR" >&2
  exit 1
fi
TARGET_FILE="$TARGET_BASENAME"
echo "  target: $TARGET_FILE"

tmpdir="$(mktemp -d)"
local_file="$tmpdir/summaly-bundle.js"
backup_file="/tmp/summaly-bundle.js.bak.$(date +%Y%m%d-%H%M%S)"

cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

echo "[2/7] copy target file from container"
docker cp "${CONTAINER_NAME}:${TARGET_FILE}" "$local_file"
cp -f "$local_file" "$backup_file"

echo "[3/7] verify target pattern"
if ! grep -Fq "$PATCH_OLD" "$local_file"; then
  if grep -Fq "$PATCH_NEW" "$local_file"; then
    echo "already patched"
    echo "backup: $backup_file"
    exit 0
  fi
  echo "target pattern not found in $TARGET_FILE" >&2
  exit 1
fi

echo "[4/7] patch file"
python3 - "$local_file" "$PATCH_OLD" "$PATCH_NEW" <<'PYEOF'
import sys
path, old_s, new_s = sys.argv[1], sys.argv[2], sys.argv[3]
data = open(path, 'rb').read()
old, new = old_s.encode(), new_s.encode()
if old not in data:
    sys.exit(f"pattern not found: {old_s}")
data = data.replace(old, new)
open(path, 'wb').write(data)
PYEOF

echo "[5/7] verify patched content"
if grep -Fq "$PATCH_OLD" "$local_file"; then
  echo "patch verification failed: old pattern still exists" >&2
  exit 1
fi
if ! grep -Fq "$PATCH_NEW" "$local_file"; then
  echo "patch verification failed: new pattern not found" >&2
  exit 1
fi

echo "[6/7] copy patched file to container"
docker cp "$local_file" "${CONTAINER_NAME}:${TARGET_FILE}"

echo "[7/7] restart container and wait for healthy"
docker restart "$CONTAINER_NAME" >/dev/null

for i in $(seq 1 60); do
  status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)"
  echo "health[$i]: $status"
  if [ "$status" = "healthy" ] || [ "$status" = "running" ]; then
    echo "patch applied"
    echo "backup: $backup_file"
    exit 0
  fi
  sleep 2
done

echo "container did not become healthy in time" >&2
echo "backup: $backup_file"
exit 1
