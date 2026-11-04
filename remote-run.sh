#!/usr/bin/env bash
set -euo pipefail

REPO="${MB_MIGRATOR_REPO:-bernadethp/mb-migrator-app}"
REF="${MB_MIGRATOR_REF:-}"
RELEASE_VERSION="${MB_MIGRATOR_VERSION:-}"
EXPECTED_REVISION="${MB_MIGRATOR_REVISION:-}"
TMP_PARENT="${MB_MIGRATOR_TMPDIR:-${TMPDIR:-/tmp}}"
WORKDIR="$(mktemp -d "$TMP_PARENT/mb-migrator.XXXXXX")"

cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf '[mb-migrator:error] Required command not found: %s\n' "$1" >&2
    exit 1
  }
}

download() {
  local url="$1" output="$2"
  if command -v curl >/dev/null 2>&1; then
    curl --proto '=https' --tlsv1.2 -fsSL "$url" -o "$output"
  elif command -v wget >/dev/null 2>&1; then
    wget --https-only -qO "$output" "$url"
  else
    printf '[mb-migrator:error] Required command not found: curl or wget\n' >&2
    exit 1
  fi
}

need_cmd tar
[[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || {
  printf '[mb-migrator:error] Invalid repository name.\n' >&2
  exit 1
}
if [[ -n "$RELEASE_VERSION" ]]; then
  [[ -z "$REF" ]] || { printf '[mb-migrator:error] Choose a release version or a development revision, not both.\n' >&2; exit 1; }
  [[ "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || { printf '[mb-migrator:error] Invalid release version.\n' >&2; exit 1; }
  [[ "$EXPECTED_REVISION" =~ ^[a-f0-9]{40}$ ]] || { printf '[mb-migrator:error] MB_MIGRATOR_REVISION must be the release commit SHA.\n' >&2; exit 1; }
elif [[ ! "$REF" =~ ^[a-f0-9]{40}$ ]]; then
  printf '[mb-migrator:error] Development execution requires MB_MIGRATOR_REF set to a full 40-character commit SHA.\n' >&2
  exit 1
else
  printf '[mb-migrator:warn] Running immutable development revision %s; this is not a supported release.\n' "$REF" >&2
fi

ARCHIVE="$WORKDIR/source.tar.gz"
if [[ -n "$RELEASE_VERSION" ]]; then
  asset="mb-migrator-$RELEASE_VERSION.tar.gz"
  url="https://github.com/$REPO/releases/download/v$RELEASE_VERSION/$asset"
  checksum="$WORKDIR/$asset.sha256"
  download "$url" "$ARCHIVE"
  download "$url.sha256" "$checksum"
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
  else
    printf '[mb-migrator:error] Required command not found: sha256sum or shasum\n' >&2
    exit 1
  fi
  read -r expected expected_name extra < "$checksum" || { printf '[mb-migrator:error] Release checksum is unreadable.\n' >&2; exit 1; }
  [[ "$expected" =~ ^[a-f0-9]{64}$ && "$expected_name" == "$asset" && -z "${extra:-}" && "$actual" == "$expected" ]] || {
    printf '[mb-migrator:error] Release checksum verification failed.\n' >&2
    exit 1
  }
else
  download "https://api.github.com/repos/$REPO/tarball/$REF" "$ARCHIVE"
fi

tar -xzf "$ARCHIVE" -C "$WORKDIR" --strip-components=1
if [[ -n "$RELEASE_VERSION" ]]; then
  manifest="$WORKDIR/RELEASE-MANIFEST"
  [[ -f "$manifest" && ! -L "$manifest" ]] || { printf '[mb-migrator:error] Release manifest is missing.\n' >&2; exit 1; }
  grep -Fxq 'format=mb-migrator-release-v1' "$manifest" \
    && grep -Fxq "version=$RELEASE_VERSION" "$manifest" \
    && grep -Fxq "revision=$EXPECTED_REVISION" "$manifest" || {
      printf '[mb-migrator:error] Release identity verification failed.\n' >&2
      exit 1
    }
fi
chmod +x "$WORKDIR/bin/mb-migrator" "$WORKDIR/bin/mb-live-migrate" "$WORKDIR/bin/mb-package" "$WORKDIR/bin/mb-push-migrate" "$WORKDIR/bin/mb-relay-migrate" "$WORKDIR/bin/mb-relay-doctor" "$WORKDIR/bin/mb-relay-verify" "$WORKDIR/bin/wp-export-migrate"
bash "$WORKDIR/bin/mb-migrator" "$@"
