#!/usr/bin/env bash
set -euo pipefail
umask 077

ARCHIVE="${1:-}"
CHECKSUM="${2:-}"
EXPECTED_VERSION="${3:-}"
EXPECTED_REVISION="${4:-}"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/mb-migrator-release-verify.XXXXXX")"

cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT
fail() { printf 'Release verification failed: %s\n' "$*" >&2; exit 1; }

[[ -f "$ARCHIVE" && ! -L "$ARCHIVE" ]] || fail "archive is missing or unsafe"
[[ -f "$CHECKSUM" && ! -L "$CHECKSUM" ]] || fail "checksum is missing or unsafe"
[[ "$EXPECTED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || fail "expected version is invalid"
[[ "$EXPECTED_REVISION" =~ ^[a-f0-9]{40}$ ]] || fail "expected revision is invalid"
command -v tar >/dev/null 2>&1 || fail "tar is unavailable"
if command -v sha256sum >/dev/null 2>&1; then
  hash=(sha256sum)
elif command -v shasum >/dev/null 2>&1; then
  hash=(shasum -a 256)
else
  fail "sha256sum or shasum is unavailable"
fi

read -r expected_hash expected_name extra < "$CHECKSUM" || fail "checksum is unreadable"
[[ "$expected_hash" =~ ^[a-f0-9]{64}$ && "$expected_name" == "$(basename "$ARCHIVE")" && -z "${extra:-}" ]] || fail "checksum format is invalid"
actual_hash="$("${hash[@]}" "$ARCHIVE" | awk '{print $1}')"
[[ "$actual_hash" == "$expected_hash" ]] || fail "archive checksum does not match"

prefix="mb-migrator-$EXPECTED_VERSION"
while IFS= read -r entry; do
  [[ "$entry" == "$prefix" || "$entry" == "$prefix/"* ]] || fail "archive contains an unexpected path"
  [[ "$entry" != /* && "$entry" != *'/../'* && "$entry" != '../'* ]] || fail "archive contains an unsafe path"
done < <(tar -tzf "$ARCHIVE")
tar -xzf "$ARCHIVE" -C "$WORKDIR"
manifest="$WORKDIR/$prefix/RELEASE-MANIFEST"
[[ -f "$manifest" && ! -L "$manifest" ]] || fail "release manifest is missing"
grep -Fxq 'format=mb-migrator-release-v1' "$manifest" || fail "release format is unsupported"
grep -Fxq "version=$EXPECTED_VERSION" "$manifest" || fail "release version does not match"
grep -Fxq "revision=$EXPECTED_REVISION" "$manifest" || fail "release revision does not match"
[[ "$(bash "$WORKDIR/$prefix/bin/mb-migrator" --version)" == "mb-migrator $EXPECTED_VERSION" ]] || fail "tool version does not match"

printf 'Verified mb-migrator %s at %s (%s)\n' "$EXPECTED_VERSION" "$EXPECTED_REVISION" "$actual_hash"
