#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
OUTPUT_DIR="${1:-$ROOT_DIR/dist}"
VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
REVISION="$(git -C "$ROOT_DIR" rev-parse HEAD)"
SOURCE_DATE_EPOCH="$(git -C "$ROOT_DIR" show -s --format=%ct "$REVISION")"
NAME="mb-migrator-$VERSION"
ARCHIVE="$OUTPUT_DIR/$NAME.tar.gz"
CHECKSUM="$ARCHIVE.sha256"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/mb-migrator-release.XXXXXX")"

cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || {
  printf 'VERSION is not a supported semantic version: %s\n' "$VERSION" >&2
  exit 1
}
[[ "$REVISION" =~ ^[a-f0-9]{40}$ ]] || { printf 'Could not resolve an exact Git revision.\n' >&2; exit 1; }
for command in git tar gzip; do
  command -v "$command" >/dev/null 2>&1 || { printf 'Required release tool is unavailable: %s\n' "$command" >&2; exit 1; }
done
if command -v sha256sum >/dev/null 2>&1; then
  hash=(sha256sum)
elif command -v shasum >/dev/null 2>&1; then
  hash=(shasum -a 256)
else
  printf 'Required release tool is unavailable: sha256sum or shasum\n' >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR" "$WORKDIR/stage/$NAME"
git -C "$ROOT_DIR" archive --format=tar "$REVISION" | tar -xf - -C "$WORKDIR/stage/$NAME"
cat > "$WORKDIR/stage/$NAME/RELEASE-MANIFEST" <<EOF
format=mb-migrator-release-v1
version=$VERSION
revision=$REVISION
EOF
chmod 0644 "$WORKDIR/stage/$NAME/RELEASE-MANIFEST"
find "$WORKDIR/stage/$NAME" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +

mkdir -p "$OUTPUT_DIR"
temp_archive="$WORKDIR/$NAME.tar.gz"
tar --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 --numeric-owner --format=gnu \
  -cf - -C "$WORKDIR/stage" "$NAME" | gzip -n -9 > "$temp_archive"
chmod 0644 "$temp_archive"
mv "$temp_archive" "$ARCHIVE"
digest="$("${hash[@]}" "$ARCHIVE" | awk '{print $1}')"
printf '%s  %s\n' "$digest" "$(basename "$ARCHIVE")" > "$CHECKSUM"
chmod 0644 "$CHECKSUM"

printf 'archive=%s\nchecksum=%s\nversion=%s\nrevision=%s\n' "$ARCHIVE" "$CHECKSUM" "$VERSION" "$REVISION"
