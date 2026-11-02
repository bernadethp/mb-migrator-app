#!/usr/bin/env bash
set -euo pipefail

REPO="${MB_MIGRATOR_REPO:-bernadethp/mb-migrator-app}"
REF="${MB_MIGRATOR_REF:-main}"
TMP_PARENT="${MB_MIGRATOR_TMPDIR:-${TMPDIR:-/tmp}}"
WORKDIR="$(mktemp -d "$TMP_PARENT/mb-migrator.XXXXXX")"

cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf '[mb-migrator:error] Required command not found: %s\n' "$1" >&2
    exit 1
  }
}

need_cmd tar

ARCHIVE="$WORKDIR/source.tar.gz"
URL="https://api.github.com/repos/$REPO/tarball/$REF"

if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$URL" -o "$ARCHIVE"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "$ARCHIVE" "$URL"
else
  printf '[mb-migrator:error] Required command not found: curl or wget\n' >&2
  exit 1
fi

tar -xzf "$ARCHIVE" -C "$WORKDIR" --strip-components=1
chmod +x "$WORKDIR/bin/mb-migrator" "$WORKDIR/bin/mb-live-migrate" "$WORKDIR/bin/mb-package" "$WORKDIR/bin/mb-push-migrate" "$WORKDIR/bin/mb-relay-migrate" "$WORKDIR/bin/mb-relay-doctor" "$WORKDIR/bin/wp-export-migrate"
bash "$WORKDIR/bin/mb-migrator" "$@"
