#!/usr/bin/env bash
# Fix: notificationTimeline XADD fails because ULID's 80-bit random as BigInt always exceeds
# Redis Stream's uint64 sequence limit (2^64-1), causing ~65536 retries per notification
# (~10 second delay). The fix truncates the BigInt to 64 bits via BigInt.asUintN(64, n).
set -euo pipefail

CONTAINER_NAME="${1:-misskeyblue-docker-provision-app-1}"
TARGET_FILE="/misskey/packages/backend/built/ApNoteService-BQAIFY8k.js"
PATCH_OLD='toXListId(e){let{date:t,additional:n}=this.idService.parseFull(e);return t.toString()+`-`+n.toString()}'
PATCH_NEW='toXListId(e){let{date:t,additional:n}=this.idService.parseFull(e);return t.toString()+`-`+BigInt.asUintN(64,n).toString()}'

if ! command -v docker >/dev/null 2>&1; then
  echo "docker command not found" >&2
  exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
  echo "container not found: $CONTAINER_NAME" >&2
  exit 1
fi

tmpdir="$(mktemp -d)"
local_file="$tmpdir/ApNoteService.js"
backup_file="/tmp/ApNoteService.js.bak.$(date +%Y%m%d-%H%M%S)"

cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

echo "[1/6] copy target file from container"
docker cp "${CONTAINER_NAME}:${TARGET_FILE}" "$local_file"
cp -f "$local_file" "$backup_file"

echo "[2/6] verify target pattern"
if ! grep -Fq "$PATCH_OLD" "$local_file"; then
  if grep -Fq "$PATCH_NEW" "$local_file"; then
    echo "already patched"
    echo "backup: $backup_file"
    exit 0
  fi
  echo "target pattern not found in $TARGET_FILE" >&2
  exit 1
fi

echo "[3/6] patch file"
perl -0777 -i -pe "s|\Q$PATCH_OLD\E|$PATCH_NEW|g" "$local_file"

echo "[4/6] verify patched content"
if grep -Fq "$PATCH_OLD" "$local_file"; then
  echo "patch verification failed: old pattern still exists" >&2
  exit 1
fi
if ! grep -Fq "$PATCH_NEW" "$local_file"; then
  echo "patch verification failed: new pattern not found" >&2
  exit 1
fi

echo "[5/6] copy patched file to container"
docker cp "$local_file" "${CONTAINER_NAME}:${TARGET_FILE}"

echo "[6/6] restart container and wait for healthy"
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
