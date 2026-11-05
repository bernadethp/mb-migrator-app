#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/mb-portability-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/target/wp-content/plugins/sample" "$T/bin" "$T/backup-parent"
printf before > "$T/target/wp-content/plugins/sample/plugin.php"
printf '<?php\n' > "$T/target/wp-config.php"
# Synthetic WPE backup follows the vendor's documented wp-content/mysql.sql layout.
php -r '
$z = new ZipArchive(); $z->open($argv[1], ZipArchive::CREATE);
foreach (["wp-content/mysql.sql"=>"CREATE TABLE `wp_options` (`id` bigint);\n", "wp-content/plugins/sample/plugin.php"=>"after!", "wp-content/uploads/new.txt"=>"new", "wp-content/mu-plugins/wpengine-common/test.php"=>"excluded", "wp-content/mu-plugins/custom.php"=>"custom", "wp-content/object-cache.php"=>"excluded", "wp-includes/core.php"=>"excluded", "wp-config.php"=>"secret", "favicon.ico"=>"icon"] as $p=>$v) $z->addFromString("wrapped/".$p,$v);
$z->close();' "$T/backup.zip"
"$ROOT_DIR/bin/mb-migrator" restore "$T/backup.zip" --target-root="$T/target" --stage-dir="$T/stage" \
  --db-import=no --mu-plugins=copy --root-extras=copy --cleanup=no --rollback-dir="$T/rollback" --yes > "$T/restore.log"
grep -q 'Provider: wpengine' "$T/restore.log"
[[ "$(cat "$T/target/wp-content/plugins/sample/plugin.php")" == after! ]]
test -f "$T/target/wp-content/mu-plugins/custom.php"
test ! -e "$T/target/wp-content/mu-plugins/wpengine-common"
test ! -e "$T/target/wp-content/object-cache.php"
test ! -e "$T/target/wp-includes"
test ! -e "$T/stage/htdocs/wp-config.php"
[[ "$(cat "$T/rollback/files/wp-content/plugins/sample/plugin.php")" == before ]]
"$ROOT_DIR/bin/mb-migrator" rollback --target-root="$T/target" --rollback-dir="$T/rollback" --yes
[[ "$(cat "$T/target/wp-content/plugins/sample/plugin.php")" == before ]]
test ! -e "$T/target/wp-content/uploads/new.txt"
test ! -e "$T/target/favicon.ico"
# An unsafe path anywhere in the ZIP is rejected before extraction.
php -r '$z=new ZipArchive();$z->open($argv[1]);$z->addFromString("../escape", "bad");$z->close();' "$T/backup.zip"
if "$ROOT_DIR/bin/mb-migrator" restore "$T/backup.zip" --target-root="$T/target" --stage-dir="$T/bad-stage" --db-import=no --dry-run > "$T/bad.log" 2>&1; then
  echo 'Unsafe ZIP unexpectedly accepted' >&2; exit 1
fi
test ! -e "$T/escape"
# Managed WP-CLI wrappers support db query even when config get cannot parse dynamic constants.
cat > "$T/bin/wp" <<'WP'
#!/usr/bin/env bash
set -eu
[[ "$*" != *--path=* ]]
case "$*" in
  *'config get'*) exit 1 ;;
  *'db query SELECT 1'*) echo 1 ;;
  *'option get home'*|*'option get siteurl'*) echo https://live.example.test ;;
  *'db export '*) printf 'CREATE TABLE old_table (`id` int);\n' > "${@: -1}" ;;
  *'db import '*)
    if [[ -n "${TEST_FAIL_DB_IMPORT_ONCE:-}" && ! -e "$TEST_FAIL_DB_IMPORT_ONCE" ]]; then
      : > "$TEST_FAIL_DB_IMPORT_ONCE"
      exit 79
    fi
    cat "${@: -1}" > "$TEST_DB_IMPORTED" ;;
  eval\ *|*' eval '*) exit 0 ;;
  *) exit 80 ;;
esac
WP
chmod +x "$T/bin/wp"
export TEST_DB_IMPORTED="$T/imported.sql"
PATH="$T/bin:$PATH" "$ROOT_DIR/bin/mb-migrator" doctor --target-root="$T/target" --import-db --target-db-method=wp-cli > "$T/doctor.log"
PATH="$T/bin:$PATH" "$ROOT_DIR/bin/mb-migrator" safety enable --target-root="$T/target"
PATH="$T/bin:$PATH" "$ROOT_DIR/bin/mb-migrator" safety status --target-root="$T/target" > "$T/status.log"
grep -q 'Safety ENABLED' "$T/status.log"
if PATH="$T/bin:$PATH" "$ROOT_DIR/bin/mb-migrator" safety disable --target-root="$T/target" --live-url=https://wrong.example.test --yes > "$T/disable.log" 2>&1; then
  echo 'Mismatched live URL unexpectedly accepted' >&2; exit 1
fi
test -f "$T/target/wp-content/mu-plugins/mb-migrator-safety.php"
PATH="$T/bin:$PATH" "$ROOT_DIR/bin/mb-migrator" safety disable --target-root="$T/target" --live-url=https://live.example.test --yes
test ! -e "$T/target/wp-content/mu-plugins/mb-migrator-safety.php"
# Same size and mtime must still be compared by content.
mkdir -p "$T/source/plugins/sample"
printf 'after!' > "$T/source/plugins/sample/plugin.php"
touch -r "$T/target/wp-content/plugins/sample/plugin.php" "$T/source/plugins/sample/plugin.php"
bash -c '
set -euo pipefail
source "$1/lib/util.sh"; source "$1/lib/rollback.sh"; source "$1/lib/wp-content.sh"
ROLLBACK_DIR="$2/checksum-rollback"; rollback_prepare "$2/target"
merge_wp_content "$2/source" "$2/target/wp-content"
' bash "$ROOT_DIR" "$T"
[[ "$(cat "$T/target/wp-content/plugins/sample/plugin.php")" == after! ]]
# Nested platform links must survive both overlay and legacy link conversion.
mkdir -p "$T/platform"
printf sentinel > "$T/platform/owned.php"
ln -s "$T/platform/owned.php" "$T/target/wp-content/plugins/sample/managed.php"
printf incoming > "$T/source/plugins/sample/managed.php"
bash -c '
set -euo pipefail
source "$1/lib/util.sh"; source "$1/lib/rollback.sh"; source "$1/lib/wp-content.sh"
ROLLBACK_DIR="$2/nested-rollback"; rollback_prepare "$2/target"
merge_wp_content "$2/source" "$2/target/wp-content"
' bash "$ROOT_DIR" "$T"
test -L "$T/target/wp-content/plugins/sample/managed.php"
[[ "$(cat "$T/platform/owned.php")" == sentinel ]]
# Exercise database backup and rollback through the managed WP-CLI interface.
php -r '$z=new ZipArchive();$z->open($argv[1]);$z->deleteName("../escape");$z->close();' "$T/backup.zip"
PATH="$T/bin:$PATH" "$ROOT_DIR/bin/mb-migrator" restore "$T/backup.zip" --target-root="$T/target" --stage-dir="$T/db-stage" \
  --db-import=yes --target-db-method=wp-cli --mu-plugins=skip --root-extras=skip --cleanup=no --rollback-dir="$T/db-rollback" --safety=enable --yes > "$T/db-restore.log"
grep -q 'CREATE TABLE `wp_options`' "$TEST_DB_IMPORTED"
test -f "$T/db-rollback/database-before.sql"
test ! -e "$T/target/db-backup-before-import.sql"
# An interrupted rollback must fail visibly without marking its retained
# evidence as restored. Repeating the exact guarded rollback then completes.
if TEST_FAIL_DB_IMPORT_ONCE="$T/rollback-db-failed-once" PATH="$T/bin:$PATH" \
  "$ROOT_DIR/bin/mb-migrator" rollback --target-root="$T/target" --rollback-dir="$T/db-rollback" --yes \
  > "$T/interrupted-rollback.log" 2>&1; then
  echo 'Interrupted rollback unexpectedly completed' >&2; exit 1
fi
test -f "$T/rollback-db-failed-once"
test ! -e "$T/db-rollback/restored"
test -f "$T/db-rollback/database-before.sql"
test -f "$T/db-rollback/target-root"
test -f "$T/db-rollback/added-files"
PATH="$T/bin:$PATH" "$ROOT_DIR/bin/mb-migrator" rollback --target-root="$T/target" --rollback-dir="$T/db-rollback" --yes
grep -q 'CREATE TABLE old_table' "$TEST_DB_IMPORTED"
test -f "$T/db-rollback/restored"
test -f "$T/target/wp-content/mu-plugins/mb-migrator-safety.php"
printf 'portability smoke test passed\n'
