#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mb-release-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
REVISION="$(git -C "$ROOT_DIR" rev-parse HEAD)"

"$ROOT_DIR/scripts/build-release.sh" "$TEST_ROOT/one" >/dev/null
"$ROOT_DIR/scripts/build-release.sh" "$TEST_ROOT/two" >/dev/null
archive="$TEST_ROOT/one/mb-migrator-$VERSION.tar.gz"
checksum="$archive.sha256"
cmp "$archive" "$TEST_ROOT/two/mb-migrator-$VERSION.tar.gz"
cmp "$checksum" "$TEST_ROOT/two/mb-migrator-$VERSION.tar.gz.sha256"
"$ROOT_DIR/scripts/verify-release.sh" "$archive" "$checksum" "$VERSION" "$REVISION" >/dev/null

cp "$archive" "$TEST_ROOT/tampered.tar.gz"
cp "$checksum" "$TEST_ROOT/tampered.tar.gz.sha256"
printf corrupt >> "$TEST_ROOT/tampered.tar.gz"
if "$ROOT_DIR/scripts/verify-release.sh" "$TEST_ROOT/tampered.tar.gz" "$TEST_ROOT/tampered.tar.gz.sha256" "$VERSION" "$REVISION" >/dev/null 2>&1; then
  printf 'Tampered release unexpectedly verified.\n' >&2; exit 1
fi
if "$ROOT_DIR/scripts/verify-release.sh" "$archive" "$TEST_ROOT/missing.sha256" "$VERSION" "$REVISION" >/dev/null 2>&1; then
  printf 'Release without checksum unexpectedly verified.\n' >&2; exit 1
fi
if "$ROOT_DIR/scripts/verify-release.sh" "$archive" "$checksum" '9.9.9' "$REVISION" >/dev/null 2>&1; then
  printf 'Wrong release version unexpectedly verified.\n' >&2; exit 1
fi
wrong_revision="$(printf 'f%.0s' {1..40})"
if "$ROOT_DIR/scripts/verify-release.sh" "$archive" "$checksum" "$VERSION" "$wrong_revision" >/dev/null 2>&1; then
  printf 'Wrong release revision unexpectedly verified.\n' >&2; exit 1
fi

mkdir -p "$TEST_ROOT/bin"
cat > "$TEST_ROOT/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
url=""; output=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[[ -n "$url" && -n "$output" ]]
if [[ "$url" == *.sha256 ]]; then
  [[ "${RELEASE_CHECKSUM_MISSING:-0}" != 1 ]] || exit 22
  cp "$RELEASE_CHECKSUM_FIXTURE" "$output"
else
  cp "$RELEASE_ARCHIVE_FIXTURE" "$output"
fi
CURL
chmod +x "$TEST_ROOT/bin/curl"
release_output="$(PATH="$TEST_ROOT/bin:$PATH" RELEASE_ARCHIVE_FIXTURE="$archive" RELEASE_CHECKSUM_FIXTURE="$checksum" \
  MB_MIGRATOR_VERSION="$VERSION" MB_MIGRATOR_REVISION="$REVISION" bash "$ROOT_DIR/remote-run.sh" --version)"
[[ "$release_output" == "mb-migrator $VERSION" ]]
if PATH="$TEST_ROOT/bin:$PATH" RELEASE_ARCHIVE_FIXTURE="$TEST_ROOT/tampered.tar.gz" RELEASE_CHECKSUM_FIXTURE="$checksum" \
  MB_MIGRATOR_VERSION="$VERSION" MB_MIGRATOR_REVISION="$REVISION" bash "$ROOT_DIR/remote-run.sh" --version >/dev/null 2>&1; then
  printf 'Remote runner accepted modified release bytes.\n' >&2; exit 1
fi
if PATH="$TEST_ROOT/bin:$PATH" RELEASE_ARCHIVE_FIXTURE="$archive" RELEASE_CHECKSUM_FIXTURE="$checksum" RELEASE_CHECKSUM_MISSING=1 \
  MB_MIGRATOR_VERSION="$VERSION" MB_MIGRATOR_REVISION="$REVISION" bash "$ROOT_DIR/remote-run.sh" --version >/dev/null 2>&1; then
  printf 'Remote runner accepted a missing checksum.\n' >&2; exit 1
fi
if MB_MIGRATOR_REF=main bash "$ROOT_DIR/remote-run.sh" --version >/dev/null 2>&1; then
  printf 'Remote runner accepted a mutable development ref.\n' >&2; exit 1
fi

printf 'release smoke test passed\n'
