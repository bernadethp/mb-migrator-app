#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mb-package-test.XXXXXX")"
export XDG_STATE_HOME="$TEST_ROOT/state"
SOURCE="$TEST_ROOT/source"
TARGET="$TEST_ROOT/target"
STAGED_TARGET="$TEST_ROOT/staged-target"
FAKE_BIN="$TEST_ROOT/bin"
CHURN_BIN="$TEST_ROOT/churn-bin"
PACKAGE="$TEST_ROOT/portable-site.tar.gz"
trap 'rm -rf "$TEST_ROOT"' EXIT

file_mode() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}

mkdir -p "$SOURCE/wp-content/plugins/sample-plugin" "$SOURCE/wp-content/themes/sample-theme" "$SOURCE/wp-content/uploads/2026/07"
mkdir -p "$SOURCE/wp-content/uploads/bb-platform-previews/example"
mkdir -p "$TARGET/wp-content/plugins" "$TARGET/wp-content/themes" "$TARGET/wp-content/uploads" "$FAKE_BIN" "$CHURN_BIN"
mkdir -p "$STAGED_TARGET/wp-content/plugins" "$STAGED_TARGET/wp-content/themes" "$STAGED_TARGET/wp-content/uploads"
printf '%s\n' '<?php // plugin' > "$SOURCE/wp-content/plugins/sample-plugin/plugin.php"
printf '%s\n' '/* theme */' > "$SOURCE/wp-content/themes/sample-theme/style.css"
printf '%s\n' 'package upload' > "$SOURCE/wp-content/uploads/2026/07/package.txt"
ln -s \
  /var/www/webroot/ROOT/wp-content/uploads/2026/07/package.txt \
  "$SOURCE/wp-content/uploads/bb-platform-previews/example/preview.txt"
printf '%s\n' 'verification' > "$SOURCE/verification.html"
printf '%s\n' '<?php core' > "$SOURCE/wp-load.php"
printf '%s\n' \
  '<?php' \
  "\$table_prefix = 'wp_';" > "$SOURCE/wp-config.php"
printf '%s\n' '<?php' "define('DB_NAME', 'target_db');" "\$table_prefix = 'wp_';" > "$TARGET/wp-config.php"
cp "$TARGET/wp-config.php" "$STAGED_TARGET/wp-config.php"

printf '%s\n' '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'if [[ "${1:-}" == "--help" ]]; then printf '\''  --column-statistics=#\n'\''; for ((i=0; i<5000; i++)); do printf '\''help padding %s\n'\'' "$i"; done; exit 0; fi' \
  '[[ " $* " == *" --column-statistics=0 "* ]]' \
  'cnf="${1#--defaults-extra-file=}"' \
  'grep -q '\''password="package-secret"'\'' "$cnf"' \
  'printf '\''/*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;\nDROP TABLE IF EXISTS `wp_options`;\nCREATE TABLE `wp_options` (`option_id` bigint);\nINSERT INTO `wp_options` VALUES (1);\n/*!50001 CREATE ALGORITHM=UNDEFINED */\n/*!50013 DEFINER=`source-user`@`%%` SQL SECURITY DEFINER */\n/*!50001 VIEW `wp_test_view` AS select 1 AS `value` */;\nCREATE DEFINER='\''source-user'\''@'\''source-host'\'' PROCEDURE `wp_test_proc`() SELECT 1;\n/*!40014 SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS */;\n'\''' > "$FAKE_BIN/mysqldump"
printf '%s\n' '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf '\''https://source.example.test\n'\''' > "$FAKE_BIN/mariadb"
chmod +x "$FAKE_BIN/mysqldump" "$FAKE_BIN/mariadb"

export DB_NAME="source_db"
export DB_USER="source_user"
export DB_PASSWORD="package-secret"
export DB_HOST="localhost"
REAL_TAR="$(command -v tar)"
export REAL_TAR
printf '%s\n' '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'LC_ALL=C "$REAL_TAR" "$@"' \
  'printf '\''tar: wp-content: file changed as we read it\n'\'' >&2' \
  'exit 1' > "$CHURN_BIN/tar"
chmod +x "$CHURN_BIN/tar"
PATH="$CHURN_BIN:$FAKE_BIN:$PATH" bash "$ROOT_DIR/lib/remote-source.sh" \
  archive-files "$SOURCE" native > "$TEST_ROOT/churn.tar.gz"
"$REAL_TAR" -tzf "$TEST_ROOT/churn.tar.gz" >/dev/null

PATH="$FAKE_BIN:$PATH" "$ROOT_DIR/bin/mb-migrator" export-site \
  --source-root="$SOURCE" \
  --output="$PACKAGE" \
  --db-method=native | tee "$TEST_ROOT/export.log"

test -s "$PACKAGE"
test -s "$PACKAGE.sha256"
grep -q 'Collected WordPress files:' "$TEST_ROOT/export.log"
tar -tzf "$PACKAGE" | grep -q '^mb-wordpress-package-manifest$'
tar -tzf "$PACKAGE" | grep -q '^database-package/site.sql$'
tar -tzf "$PACKAGE" | grep -q '^htdocs/wp-content/plugins/sample-plugin/plugin.php$'
if tar -tzf "$PACKAGE" | grep -q 'wp-config.php'; then
  printf 'portable package unexpectedly contains wp-config.php\n' >&2
  exit 1
fi
if tar -tzf "$PACKAGE" | grep -q 'wp-load.php'; then
  printf 'portable package unexpectedly contains WordPress core\n' >&2
  exit 1
fi

cp "$PACKAGE" "$TEST_ROOT/corrupt.tar.gz"
cp "$PACKAGE.sha256" "$TEST_ROOT/corrupt.tar.gz.sha256"
printf 'corrupt' >> "$TEST_ROOT/corrupt.tar.gz"
if PATH="$FAKE_BIN:$PATH" "$ROOT_DIR/bin/mb-migrator" import-site "$TEST_ROOT/corrupt.tar.gz" \
  --target-root="$TARGET" --db-import=no >/dev/null 2>&1; then
  printf 'corrupt package unexpectedly passed checksum verification\n' >&2
  exit 1
fi

PATH="$FAKE_BIN:$PATH" "$ROOT_DIR/bin/mb-migrator" import-site "$PACKAGE" \
  --target-root="$TARGET" \
  --new-url=https://destination.example.test \
  --db-import=no \
  --root-extras=copy \
  --mu-plugins=skip \
  --cleanup=no \
  --yes

test -f "$TARGET/wp-content/plugins/sample-plugin/plugin.php"
test -f "$TARGET/wp-content/themes/sample-theme/style.css"
test -f "$TARGET/wp-content/uploads/2026/07/package.txt"
test -f "$TARGET/wp-content/uploads/bb-platform-previews/example/preview.txt"
test ! -L "$TARGET/wp-content/uploads/bb-platform-previews/example/preview.txt"
[[ "$(file_mode "$TARGET/wp-content/uploads/bb-platform-previews/example/preview.txt")" == "644" ]]
test -f "$TARGET/verification.html"
[[ "$(file_mode "$TARGET/wp-content/plugins/sample-plugin")" == "755" ]]
[[ "$(file_mode "$TARGET/wp-content/plugins/sample-plugin/plugin.php")" == "644" ]]
[[ "$(file_mode "$TARGET/wp-content/uploads/2026/07/package.txt")" == "644" ]]
[[ "$(file_mode "$TARGET/verification.html")" == "644" ]]
PRIVATE_STAGE="$(find "$XDG_STATE_HOME/mb-migrator/staging" -mindepth 1 -maxdepth 1 -type d -name 'restore-*' -print -quit)"
test -n "$PRIVATE_STAGE"
test ! -e "$TARGET/restore-portable-site"
[[ "$(file_mode "$PRIVATE_STAGE")" == "700" ]]
[[ "$(file_mode "$PRIVATE_STAGE/migration-report.txt")" == "600" ]]
grep -q 'Source URL read from package manifest: https://source.example.test' "$PRIVATE_STAGE/migration-report.txt"
grep -q 'URL rewrite pending' "$PRIVATE_STAGE/migration-report.txt"
COMBINED_SQL="$(find "$PRIVATE_STAGE" -name '*-combined-phpmyadmin-import.sql' -print -quit)"
test -n "$COMBINED_SQL"
if grep -Eqi '\bDEFINER[[:space:]]*=' "$COMBINED_SQL"; then
  printf 'combined SQL unexpectedly retained a source DEFINER clause\n' >&2
  exit 1
fi
grep -q 'SQL SECURITY DEFINER' "$COMBINED_SQL"

STAGED_PACKAGE="$TEST_ROOT/staged-package"
mkdir -p "$STAGED_PACKAGE"
tar -xzf "$PACKAGE" -C "$STAGED_PACKAGE"
PATH="$FAKE_BIN:$PATH" "$ROOT_DIR/bin/mb-migrator" import-staged "$STAGED_PACKAGE" \
  --target-root="$STAGED_TARGET" \
  --new-url=https://staged-destination.example.test \
  --db-import=no \
  --root-extras=copy \
  --mu-plugins=skip \
  --cleanup=no \
  --yes

test -f "$STAGED_TARGET/wp-content/plugins/sample-plugin/plugin.php"
test -f "$STAGED_TARGET/wp-content/uploads/2026/07/package.txt"
test -f "$STAGED_TARGET/verification.html"
grep -q 'Source URL read from package manifest: https://source.example.test' \
  "$STAGED_PACKAGE/migration-report.txt"

printf 'portable package smoke test passed\n'
