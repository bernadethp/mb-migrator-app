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
names="$WORKDIR/archive-names"
metadata="$WORKDIR/archive-metadata"
LC_ALL=C tar --quoting-style=escape -tzf "$ARCHIVE" > "$names"
LC_ALL=C tar --numeric-owner --quoting-style=escape -tvzf "$ARCHIVE" > "$metadata"
mapfile -t entries < "$names"
mapfile -t metadata_lines < "$metadata"
[[ "${#entries[@]}" -gt 0 && "${#entries[@]}" -eq "${#metadata_lines[@]}" && "${#entries[@]}" -le 20000 ]] || fail "archive has an unsafe entry count"
declared_bytes="$(LC_ALL=C awk '$3 !~ /^[0-9]+$/ { exit 2 } { total += $3 } END { printf "%.0f\n", total }' "$metadata")" || fail "archive metadata is malformed"
[[ "$declared_bytes" =~ ^[0-9]+$ && "$declared_bytes" -le 536870912 ]] || fail "archive exceeds the extraction limit"
declare -A exact_paths=() folded_paths=()
for index in "${!entries[@]}"; do
  entry="${entries[$index]}"
  type="${metadata_lines[$index]:0:1}"
  [[ "$type" == - || "$type" == d ]] || fail "archive contains a link or special file"
  [[ "$entry" == "$prefix" || "$entry" == "$prefix/"* ]] || fail "archive contains an unexpected path"
  [[ "$entry" != *\\* && "$entry" != /* ]] || fail "archive contains an unsafe path"
  normalized="${entry%/}"
  IFS='/' read -r -a parts <<< "$normalized"
  for part in "${parts[@]}"; do
    [[ -n "$part" && "$part" != . && "$part" != .. ]] || fail "archive contains path traversal"
  done
  [[ -z "${exact_paths[$normalized]+present}" ]] || fail "archive contains a duplicate path"
  exact_paths[$normalized]=1
  folded="${normalized,,}"
  [[ -z "${folded_paths[$folded]+present}" || "${folded_paths[$folded]}" == "$normalized" ]] || fail "archive contains a case-colliding path"
  folded_paths[$folded]="$normalized"
done
tar --no-same-owner --no-same-permissions -xzf "$ARCHIVE" -C "$WORKDIR"
manifest="$WORKDIR/$prefix/RELEASE-MANIFEST"
[[ -f "$manifest" && ! -L "$manifest" ]] || fail "release manifest is missing"
grep -Fxq 'format=mb-migrator-release-v1' "$manifest" || fail "release format is unsupported"
grep -Fxq "version=$EXPECTED_VERSION" "$manifest" || fail "release version does not match"
grep -Fxq "revision=$EXPECTED_REVISION" "$manifest" || fail "release revision does not match"
[[ -f "$WORKDIR/$prefix/bin/mb-migrator" && ! -L "$WORKDIR/$prefix/bin/mb-migrator" ]] || fail "release executable layout is unsafe"
[[ "$(bash "$WORKDIR/$prefix/bin/mb-migrator" --version)" == "mb-migrator $EXPECTED_VERSION" ]] || fail "tool version does not match"

printf 'Verified mb-migrator %s at %s (%s)\n' "$EXPECTED_VERSION" "$EXPECTED_REVISION" "$actual_hash"
