#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mb-security-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

validate_archive() {
  local archive="$1" stage="$2"
  mkdir -p "$stage"
  ROOT_DIR="$ROOT_DIR" ARCHIVE_INDEX="" bash -c '
    set -euo pipefail
    source "$ROOT_DIR/lib/util.sh"
    source "$ROOT_DIR/lib/archive.sh"
    archive_index "$1" "$2"
  ' _ "$archive" "$stage"
}

expect_rejected() {
  local name="$1" archive="$2"
  if validate_archive "$archive" "$TEST_ROOT/stage-$name" >"$TEST_ROOT/$name.log" 2>&1; then
    printf 'Unsafe archive unexpectedly accepted: %s\n' "$name" >&2
    exit 1
  fi
}

mkdir -p "$TEST_ROOT/valid/htdocs/wp-content/plugins/sample" "$TEST_ROOT/valid/database-package"
printf 'plugin\n' > "$TEST_ROOT/valid/htdocs/wp-content/plugins/sample/plugin.php"
printf 'SELECT 1;\n' > "$TEST_ROOT/valid/database-package/site.sql"
tar -czf "$TEST_ROOT/valid.tar.gz" -C "$TEST_ROOT/valid" .
validate_archive "$TEST_ROOT/valid.tar.gz" "$TEST_ROOT/stage-valid"

cp -a "$TEST_ROOT/valid" "$TEST_ROOT/symlink"
ln -s /etc/passwd "$TEST_ROOT/symlink/htdocs/wp-content/plugins/escape"
tar -czf "$TEST_ROOT/symlink.tar.gz" -C "$TEST_ROOT/symlink" .
expect_rejected symlink "$TEST_ROOT/symlink.tar.gz"
grep -q 'link target is unsafe' "$TEST_ROOT/symlink.log"

cp -a "$TEST_ROOT/valid" "$TEST_ROOT/case"
printf 'A\n' > "$TEST_ROOT/case/htdocs/wp-content/plugins/Case.php"
printf 'a\n' > "$TEST_ROOT/case/htdocs/wp-content/plugins/case.php"
tar -czf "$TEST_ROOT/case.tar.gz" -C "$TEST_ROOT/case" .
expect_rejected case "$TEST_ROOT/case.tar.gz"
grep -q 'case-colliding path' "$TEST_ROOT/case.log"

printf 'escape\n' > "$TEST_ROOT/escape"
tar -czf "$TEST_ROOT/traversal.tar.gz" -C "$TEST_ROOT" --transform='s|^escape$|../escape|' escape
expect_rejected traversal "$TEST_ROOT/traversal.tar.gz"
grep -q 'path traversal' "$TEST_ROOT/traversal.log"

tar -cf "$TEST_ROOT/duplicate.tar" -C "$TEST_ROOT/valid" .
tar -rf "$TEST_ROOT/duplicate.tar" -C "$TEST_ROOT/valid" htdocs/wp-content/plugins/sample/plugin.php
gzip "$TEST_ROOT/duplicate.tar"
expect_rejected duplicate "$TEST_ROOT/duplicate.tar.gz"
grep -q 'duplicate path' "$TEST_ROOT/duplicate.log"

if MB_MIGRATOR_MAX_ARCHIVE_ENTRIES=1 validate_archive "$TEST_ROOT/valid.tar.gz" "$TEST_ROOT/stage-entry-limit" >"$TEST_ROOT/entry-limit.log" 2>&1; then
  printf 'Archive entry limit was not enforced\n' >&2
  exit 1
fi
grep -q 'too many entries' "$TEST_ROOT/entry-limit.log"

if MB_MIGRATOR_MAX_ARCHIVE_BYTES=1 validate_archive "$TEST_ROOT/valid.tar.gz" "$TEST_ROOT/stage-byte-limit" >"$TEST_ROOT/byte-limit.log" 2>&1; then
  printf 'Archive byte limit was not enforced\n' >&2
  exit 1
fi
grep -q 'too many uncompressed bytes' "$TEST_ROOT/byte-limit.log"

printf 'security smoke test passed\n'
