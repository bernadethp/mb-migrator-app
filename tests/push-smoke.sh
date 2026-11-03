#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mb-push-test.XXXXXX")"
STATE_DIR="$TEST_ROOT/state"
SOURCE="$TEST_ROOT/source"
FAKE_BIN="$TEST_ROOT/bin"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$SOURCE/wp-content/plugins/sample-plugin" "$FAKE_BIN"
printf '%s\n' '<?php // plugin' > "$SOURCE/wp-content/plugins/sample-plugin/plugin.php"
printf '%s\n' '<?php' "\$table_prefix = 'wp_';" > "$SOURCE/wp-config.php"

printf '%s\n' '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'if [[ -n "${MB_MIGRATOR_DESTINATION_PASSWORD:-}" ]]; then' \
  '  [[ " $* " == *" BatchMode=no "* ]] || exit 81' \
  '  [[ "${SSH_ASKPASS_REQUIRE:-}" == "force" ]] || exit 82' \
  '  [[ -x "${SSH_ASKPASS:-}" ]] || exit 83' \
  '  [[ "$("$SSH_ASKPASS")" == "$MB_MIGRATOR_DESTINATION_PASSWORD" ]] || exit 84' \
  'fi' \
  '[[ " $* " == *" -G "* ]] && exit 1' \
  'command_text="${!#}"' \
  'case "$command_text" in' \
  '  true) exit 0 ;;' \
  '  *"command -v rsync"*) printf '\''/usr/bin/rsync\n'\'' ;;' \
  '  *"__MB_TARGET_ROOT__"*) printf '\''__MB_TARGET_ROOT__=/srv/htdocs\n'\'' ;;' \
  '  *"option"*get*siteurl*) printf '\''%s\n'\'' "$command_text" > "$PUSH_URL_MARKER"; printf '\''https://destination-push.example.test\n'\'' ;;' \
  '  *"option"*get*home*) [[ "${PUSH_VERIFY_FAIL:-0}" != "1" ]] || exit 1; printf '\''__MB_HOME__=https://destination-push.example.test\n'\'' ;;' \
  '  *"rsync-"*"__MB_REMOTE_DIR__"*) if [[ "$command_text" =~ rsync-([a-f0-9]{20}) ]]; then pairing="${BASH_REMATCH[1]}"; else exit 1; fi; reused=0; [[ ! -e "$PUSH_REMOTE_CACHE_MARKER" ]] || reused=1; : > "$PUSH_REMOTE_CACHE_MARKER"; printf '\''__MB_REMOTE_DIR__=/home/destination/.local/state/mb-migrator/incoming/rsync-%s\n__MB_CACHE_REUSED__=%s\n'\'' "$pairing" "$reused" ;;' \
  '  *"__MB_REMOTE_DIR__"*) printf '\''__MB_REMOTE_DIR__=/home/destination/.local/state/mb-migrator/incoming/push.test123\n'\'' ;;' \
  '  *"mkdir -p"*"staged-site"*) exit 0 ;;' \
  '  *"df -Pk"*) printf '\''__MB_FREE_KB__=10485760\n'\'' ;;' \
  '  *"__MB_PRUNED_ARTIFACTS__"*) printf '\''__MB_PRUNED_ARTIFACTS__=0\n'\'' ;;' \
  '  *"database-package/site.sql"*) cat > "$PUSH_DB_MARKER" ;;' \
  '  *"core"*"is-installed"*) printf '\''__MB_HOME__=https://destination-push.example.test\n'\'' ;;' \
  '  *"rm -f"*) printf '\''%s\n'\'' "$command_text" > "$PUSH_CLEANUP_MARKER" ;;' \
  '  *"remote-run.sh"*) printf '\''%s\n'\'' "$command_text" > "$PUSH_IMPORT_MARKER" ;;' \
  '  *) printf '\''unexpected fake ssh command: %s\n'\'' "$command_text" >&2; exit 1 ;;' \
  'esac' > "$FAKE_BIN/ssh"

printf '%s\n' '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'if [[ -n "${MB_MIGRATOR_DESTINATION_PASSWORD:-}" ]]; then [[ " $* " == *" BatchMode=no "* ]] || exit 81; fi' \
  'printf '\''%s\n'\'' "$*" >> "$PUSH_SCP_MARKER"' > "$FAKE_BIN/scp"

printf '%s\n' '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'if [[ "${1:-}" == "--info=help" ]]; then printf '\''progress2\n'\''; exit 0; fi' \
  'if [[ -n "${MB_MIGRATOR_DESTINATION_PASSWORD:-}" ]]; then [[ " $* " == *" BatchMode=no "* ]] || exit 81; fi' \
  'printf '\''%s\n'\'' "$*" >> "$PUSH_RSYNC_MARKER"' \
  'if [[ ! -e "$PUSH_RSYNC_RETRY_MARKER" ]]; then : > "$PUSH_RSYNC_RETRY_MARKER"; printf '\''simulated broken pipe\n'\'' >&2; exit 12; fi' > "$FAKE_BIN/rsync"

printf '%s\n' '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'host="${!#}"' \
  'public_key="$(awk '\''{print $1 " " $2; exit}'\'' "$PUSH_SCAN_KEY")"' \
  'printf '\''[%s]:3022 %s\n'\'' "$host" "$public_key"' > "$FAKE_BIN/ssh-keyscan"

printf '%s\n' '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'cnf="${1#--defaults-extra-file=}"' \
  'grep -q '\''password="push-secret"'\'' "$cnf"' \
  'printf '\''DROP TABLE IF EXISTS `wp_options`;\nCREATE TABLE `wp_options` (`option_id` bigint);\nINSERT INTO `wp_options` VALUES (1);\n'\''' > "$FAKE_BIN/mariadb-dump"

printf '%s\n' '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf '\''https://source-push.example.test\n'\''' > "$FAKE_BIN/mariadb"
chmod +x "$FAKE_BIN/ssh" "$FAKE_BIN/scp" "$FAKE_BIN/ssh-keyscan" "$FAKE_BIN/mariadb-dump" "$FAKE_BIN/mariadb" "$FAKE_BIN/rsync"

export DB_NAME="push_source"
export DB_USER="push_user"
export DB_PASSWORD="push-secret"
export DB_HOST="localhost"
export PUSH_IMPORT_MARKER="$TEST_ROOT/import-command"
export PUSH_CLEANUP_MARKER="$TEST_ROOT/cleanup-command"
export PUSH_SCP_MARKER="$TEST_ROOT/scp-command"
export PUSH_RSYNC_MARKER="$TEST_ROOT/rsync-command"
export PUSH_DB_MARKER="$TEST_ROOT/streamed-db.sql"
export PUSH_URL_MARKER="$TEST_ROOT/url-command"
export PUSH_REMOTE_CACHE_MARKER="$TEST_ROOT/remote-cache"
export PUSH_RSYNC_RETRY_MARKER="$TEST_ROOT/rsync-retried"
export MB_MIGRATOR_SSH_DIR="$TEST_ROOT/ssh"
export MB_MIGRATOR_SKIP_HTTP_VERIFY=1

prepare_output="$(PATH="$FAKE_BIN:$PATH" "$ROOT_DIR/bin/mb-migrator" push-pair prepare "--state-dir=$STATE_DIR")"
pairing_id="$(printf '%s\n' "$prepare_output" | awk -F': ' '/Pairing ID:/{print $2; exit}')"
[[ "$pairing_id" =~ ^[a-f0-9]{20}$ ]]
test -s "$STATE_DIR/push-pairings/$pairing_id/id_ed25519"
test -s "$STATE_DIR/push-pairings/$pairing_id/id_ed25519.pub"
export PUSH_SCAN_KEY="$STATE_DIR/push-pairings/$pairing_id/id_ed25519.pub"

PATH="$FAKE_BIN:$PATH" "$ROOT_DIR/bin/mb-migrator" push-pair complete \
  "$pairing_id" newuser@new.example.test \
  --port=3022 \
  "--state-dir=$STATE_DIR"
test -s "$MB_MIGRATOR_SSH_DIR/known_hosts"
[[ "$(<"$STATE_DIR/push-pairings/current-pairing")" == "$pairing_id" ]]

MB_MIGRATOR_DESTINATION_PASSWORD=gateway-secret PATH="$FAKE_BIN:$PATH" \
  "$ROOT_DIR/bin/mb-migrator" push-pair complete \
    "$pairing_id" newuser@new.example.test \
    --port=3022 \
    "--state-dir=$STATE_DIR"

MB_MIGRATOR_DESTINATION_PASSWORD=gateway-secret PATH="$FAKE_BIN:$PATH" \
  "$ROOT_DIR/bin/mb-migrator" push-site \
  "--state-dir=$STATE_DIR" \
  "--source-root=$SOURCE" \
  --source-db-method=native \
  --target-db-method=native \
  --db-import=yes \
  --mu-plugins=skip \
  --root-extras=skip \
  --cleanup=no \
  --yes

test -s "$PUSH_SCP_MARKER"
test -s "$PUSH_RSYNC_MARKER"
test -s "$PUSH_DB_MARKER"
test -s "$PUSH_URL_MARKER"
test -s "$PUSH_IMPORT_MARKER"
test -s "$PUSH_CLEANUP_MARKER"
grep -q 'import-staged' "$PUSH_IMPORT_MARKER"
grep -q 'staged-site' "$PUSH_IMPORT_MARKER"
grep -q "rsync-$pairing_id/staged-site" "$PUSH_IMPORT_MARKER"
[[ "$(wc -l < "$PUSH_RSYNC_MARKER")" -eq 5 ]]
grep -q -- '--info=name0,progress2' "$PUSH_RSYNC_MARKER"
grep -q -- '--link-dest=/srv/htdocs/wp-content' "$PUSH_RSYNC_MARKER"
grep -q -- '--partial-dir=.mb-migrator-partial' "$PUSH_RSYNC_MARKER"
grep -q -- '--timeout=120' "$PUSH_RSYNC_MARKER"
grep -q 'cd' "$PUSH_URL_MARKER"
grep -q 'siteurl' "$PUSH_URL_MARKER"
grep -q -- '--target-root=/srv/htdocs' "$PUSH_IMPORT_MARKER"
grep -q -- '--new-url=https://destination-push.example.test' "$PUSH_IMPORT_MARKER"

rm -f "$PUSH_CLEANUP_MARKER"
if PUSH_VERIFY_FAIL=1 PATH="$FAKE_BIN:$PATH" "$ROOT_DIR/bin/mb-migrator" push-site \
  "--pairing=$pairing_id" \
  "--state-dir=$STATE_DIR" \
  "--source-root=$SOURCE" \
  --source-db-method=native \
  --target-db-method=native \
  --db-import=yes \
  --mu-plugins=skip \
  --root-extras=skip \
  --cleanup=no \
  --yes >"$TEST_ROOT/verification-failure.log" 2>&1; then
  printf 'push migration unexpectedly succeeded after destination verification failed\n' >&2
  exit 1
fi
grep -q 'Destination WordPress verification failed; migration was not marked complete' "$TEST_ROOT/verification-failure.log"
if grep -q 'Push migration completed' "$TEST_ROOT/verification-failure.log"; then
  printf 'failed destination verification was reported as complete\n' >&2
  exit 1
fi
test ! -e "$PUSH_CLEANUP_MARKER"

mv "$PUSH_IMPORT_MARKER" "$TEST_ROOT/rsync-import-command"
: > "$PUSH_SCP_MARKER"
PATH="$FAKE_BIN:$PATH" "$ROOT_DIR/bin/mb-migrator" push-site \
  "--pairing=$pairing_id" \
  "--state-dir=$STATE_DIR" \
  "--source-root=$SOURCE" \
  --source-db-method=native \
  --transport=package \
  --target-root=/srv/htdocs \
  --new-url=https://destination-push.example.test \
  --target-db-method=native \
  --db-import=yes \
  --mu-plugins=skip \
  --root-extras=skip \
  --cleanup=no \
  --yes

grep -q 'import-site' "$PUSH_IMPORT_MARKER"
grep -q 'wordpress-package.tar.gz' "$PUSH_SCP_MARKER"
grep -q 'wordpress-package.tar.gz.sha256' "$PUSH_SCP_MARKER"

GUIDED_STATE="$TEST_ROOT/guided-state"
: > "$PUSH_RSYNC_MARKER"
guided_prepare_output="$(PATH="$FAKE_BIN:$PATH" "$ROOT_DIR/bin/mb-migrator" push-pair prepare "--state-dir=$GUIDED_STATE")"
guided_pending_id="$(printf '%s\n' "$guided_prepare_output" | awk -F': ' '/Pairing ID:/{print $2; exit}')"
[[ "$guided_pending_id" =~ ^[a-f0-9]{20}$ ]]
export PUSH_SCAN_KEY="$GUIDED_STATE/push-pairings/$guided_pending_id/id_ed25519.pub"

printf '\nguideduser@guided.example.test\n3022\n' |
  PATH="$FAKE_BIN:$PATH" "$ROOT_DIR/bin/mb-migrator" push \
    "--state-dir=$GUIDED_STATE" \
    "--source-root=$SOURCE" \
    --source-db-method=native \
    --target-db-method=native \
    --target-root=/srv/htdocs \
    --new-url=https://destination-push.example.test \
    --transport=rsync \
    --db-import=yes \
    --mu-plugins=skip \
    --root-extras=skip \
    --cleanup=no \
    --yes

guided_pairing_id="$(<"$GUIDED_STATE/push-pairings/current-pairing")"
[[ "$guided_pairing_id" =~ ^[a-f0-9]{20}$ ]]
[[ "$guided_pairing_id" == "$guided_pending_id" ]]
[[ ! -e "$GUIDED_STATE/push-pairings/pending-pairing" ]]
[[ "$(<"$GUIDED_STATE/push-pairings/$guided_pairing_id/destination")" == "guideduser@guided.example.test" ]]
[[ "$(<"$GUIDED_STATE/push-pairings/$guided_pairing_id/port")" == "3022" ]]
grep -q 'import-staged' "$PUSH_IMPORT_MARKER"

PATH="$FAKE_BIN:$PATH" "$ROOT_DIR/bin/mb-migrator" push \
  "--state-dir=$GUIDED_STATE" \
  "--source-root=$SOURCE" \
  --source-db-method=native \
  --target-db-method=native
[[ "$(<"$GUIDED_STATE/push-pairings/current-pairing")" == "$guided_pairing_id" ]]

printf 'outbound push smoke test passed\n'
