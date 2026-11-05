#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/mb-relay-test.XXXXXX")"
# shellcheck disable=SC2154 # status is assigned inside this EXIT trap.
trap 'status=$?; if [[ "$status" -ne 0 ]]; then cat "$T/"*.log >&2; fi; rm -rf "$T"' EXIT
export RELAY_TEST_ROOT="$T"
mkdir -p "$T/source/wp-content/uploads" "$T/target/wp-content" "$T/bin" "$T/home"
printf 'test-key\n' > "$T/source-key"
printf 'test-key\n' > "$T/destination-key"
printf 'source host key\n' > "$T/source-known-hosts"
printf 'destination host key\n' > "$T/destination-known-hosts"
printf '<?php\n' > "$T/source/wp-config.php"
printf '<?php\n' > "$T/target/wp-config.php"
printf first > "$T/source/wp-content/uploads/test.txt"
ln -s test.txt "$T/source/wp-content/uploads/alias.txt"
cat > "$T/bin/wp" <<'WP'
#!/usr/bin/env bash
set -eu
case "$*" in
  *'option get home --quiet'*|*'option get siteurl --quiet'*) exit 64 ;;
  *'core is-installed --network'*) exit 1 ;;
  *'core is-installed'*) exit 0 ;;
  *'post list '*--format=count*) [[ "${RELAY_TARGET_MODIFIED:-0}" == 1 ]] && echo 4 || echo 2 ;;
  *'post list '*--format=json*) printf '[{"ID":1,"post_type":"page","post_status":"publish","post_name":"evidence","post_title":"Evidence","post_content":"Marker","post_excerpt":"","post_parent":0,"menu_order":0}]\n' ;;
  *'user list --role=administrator --format=count'*) echo 1 ;;
  *'user list --format=count'*) echo 1 ;;
  *'plugin list --status=active --field=name'*) echo sample-plugin ;;
  *'theme list --status=active --field=name'*) echo sample-theme ;;
  *'search-replace '*--format=count*) echo 0 ;;
  *'db query SELECT 1'*) echo 1 ;;
  *'db export '*)
    [[ "${RELAY_FAIL_DATABASE:-0}" != 1 ]] || exit 77
    while [[ "$1" != export ]]; do shift; done
    printf 'CREATE TABLE `wp_options` (`id` int);\n' > "$2" ;;
  *'option get siteurl'*|*'option get home'*) echo https://source.example.test ;;
  *) exit 1 ;;
esac
WP
# These stand-ins execute the real collectors and importer on local fixtures.
# They also prove that SSH is initiated only by the intermediary.
cat > "$T/bin/ssh" <<'SSH'
#!/usr/bin/env bash
set -eu
while [[ "${1:-}" == -* ]]; do shift 2; done
host="$1"; shift
case "$host" in source@test|dest@test) ;; *) exit 91 ;; esac
[[ -z "${RELAY_TEST_INSIDE_SSH:-}" ]] || exit 92
export RELAY_TEST_INSIDE_SSH=1
export HOME="$RELAY_TEST_ROOT/home"
if [[ "${1:-}" == bash && "${2:-}" == -s ]]; then
  # The source collector is real; use the fixture root supplied by the command.
  exec "$@"
fi
# Strip the login shell solely to keep the fixture PATH in this isolated test.
if [[ "$*" == 'bash -lc '* ]]; then
  [[ "${RELAY_FAIL_RESTORE:-0}" != 1 ]] || exit 78
  eval "set -- $*"
  exec bash -c "$3"
fi
exec bash -c "$*"
SSH
REAL_RSYNC="$(command -v rsync)"
cat > "$T/bin/rsync" <<'RSYNC'
#!/usr/bin/env bash
set -eu
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -e) shift 2; continue ;;
    source@test:*|dest@test:*) args+=("${1#*:}") ;;
    *) args+=("$1") ;;
  esac
  shift
done
exec "$RELAY_REAL_RSYNC" "${args[@]}"
RSYNC
cat > "$T/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -eu
printf '200'
CURL
chmod +x "$T/bin/"*
export RELAY_REAL_RSYNC="$REAL_RSYNC"
export PATH="$T/bin:$PATH"
if grep -Fq '< <(' "$ROOT_DIR/lib/remote-verification.sh"; then
  echo 'Remote verification must not require /dev/fd process substitution' >&2; exit 1
fi
version_output="$("$ROOT_DIR/bin/mb-migrator" --version)"
[[ "$version_output" == "mb-migrator $(<"$ROOT_DIR/VERSION")" ]]
doctor_output="$("$ROOT_DIR/bin/mb-migrator" relay-doctor source@test \
  --destination=dest@test --source-root="$T/source" --target-root="$T/target" \
  --source-identity="$T/source-key" --destination-identity="$T/destination-key" \
  --source-known-hosts="$T/source-known-hosts" --destination-known-hosts="$T/destination-known-hosts" \
  --json)"
grep -q '"status":"ready"' <<< "$doctor_output"
grep -q '"schema_version":1' <<< "$doctor_output"
grep -q '"content_state":"clean"' <<< "$doctor_output"
test ! -e "$T/state"
if RELAY_TARGET_MODIFIED=1 "$ROOT_DIR/bin/mb-migrator" relay-doctor source@test \
  --destination=dest@test --source-root="$T/source" --target-root="$T/target" \
  --source-identity="$T/source-key" --destination-identity="$T/destination-key" \
  --source-known-hosts="$T/source-known-hosts" --destination-known-hosts="$T/destination-known-hosts" \
  --json > "$T/modified-doctor.log"; then
  echo 'Modified destination unexpectedly passed preflight' >&2; exit 1
fi
grep -q 'migration.destination_not_fresh' "$T/modified-doctor.log"
run_relay() {
  "$ROOT_DIR/bin/mb-migrator" relay source@test --destination=dest@test --source-root="$T/source" \
    --target-root="$T/target" --state-dir="$T/state" \
    --source-identity="$T/source-key" --destination-identity="$T/destination-key" \
    --source-known-hosts="$T/source-known-hosts" --destination-known-hosts="$T/destination-known-hosts" \
    --db-import=no --mu-plugins=skip --root-extras=skip --yes "$@"
}
run_relay > "$T/first.log"
[[ "$(cat "$T/target/wp-content/uploads/test.txt")" == first ]]
verify_relay() {
  "$ROOT_DIR/bin/mb-migrator" relay-verify source@test --destination=dest@test --source-root="$T/source" \
    --target-root="$T/target" --run-id=019a4dc8-d9ff-73f2-8e98-2e6905994c10 \
    --expected-url=https://source.example.test --expected-safety=disabled \
    --source-identity="$T/source-key" --destination-identity="$T/destination-key" \
    --source-known-hosts="$T/source-known-hosts" --destination-known-hosts="$T/destination-known-hosts" \
    --json
}
verify_relay > "$T/verified.json"
php -r 'json_decode(file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR);' "$T/verified.json"
grep -q '"status":"verified"' "$T/verified.json"
grep -q '"run_id":"019a4dc8-d9ff-73f2-8e98-2e6905994c10"' "$T/verified.json"
grep -q '"media":true' "$T/verified.json"
grep -q '"rollback":true' "$T/verified.json"
grep -q '"public_https":true' "$T/verified.json"
printf corrupt > "$T/target/wp-content/uploads/test.txt"
if verify_relay > "$T/corrupt-verification.json"; then
  echo 'Corrupt destination media unexpectedly verified' >&2; exit 1
fi
php -r 'json_decode(file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR);' "$T/corrupt-verification.json"
grep -q '"status":"failed"' "$T/corrupt-verification.json"
grep -q '"media":false' "$T/corrupt-verification.json"
printf other > "$T/source/wp-content/uploads/test.txt"
printf new > "$T/source/wp-content/uploads/new.txt"
run_relay > "$T/second.log"
[[ "$(cat "$T/target/wp-content/uploads/test.txt")" == other ]]
test -f "$T/target/wp-content/uploads/new.txt"
test -L "$T/target/wp-content/uploads/alias.txt"
grep -q 'Relay migration completed' "$T/second.log"
# A failed fresh database export must not import the previous cached snapshot.
printf later > "$T/source/wp-content/uploads/test.txt"
if RELAY_FAIL_DATABASE=1 run_relay > "$T/failed-export.log" 2>&1; then
  echo 'Failed database export unexpectedly imported' >&2; exit 1
fi
[[ "$(cat "$T/target/wp-content/uploads/test.txt")" == other ]]
# No local lock remains after the handled failure.
test "$(find "$T/state" -name lock -type d | wc -l | tr -d ' ')" == 0
relay_work="$(find "$T/state" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
test -n "$relay_work"
if RELAY_FAIL_RESTORE=1 run_relay > "$T/failed-restore.log" 2>&1; then
  echo 'Failed destination restore unexpectedly completed' >&2; exit 1
fi
test -f "$relay_work/lock/owner"
grep -q '^phase=restore$' "$relay_work/lock/owner"
if run_relay --recover-stale-lock > "$T/ambiguous-restore-recovery.log" 2>&1; then
  echo 'Ambiguous destination restore lock was unexpectedly recovered' >&2; exit 1
fi
grep -q 'reconcile the destination and rollback point manually' "$T/ambiguous-restore-recovery.log"
rm -f "$relay_work/lock/owner"
rmdir "$relay_work/lock"
mkdir "$relay_work/lock"
printf 'host=%s\npid=%s\nphase=transfer\n' "$(uname -n)" "$$" > "$relay_work/lock/owner"
if run_relay --recover-stale-lock > "$T/active-lock.log" 2>&1; then
  echo 'Active relay lock was unexpectedly recovered' >&2; exit 1
fi
grep -q 'owned by active PID' "$T/active-lock.log"
printf 'host=%s\npid=2147483647\nphase=transfer\n' "$(uname -n)" > "$relay_work/lock/owner"
if run_relay > "$T/stale-lock-without-confirmation.log" 2>&1; then
  echo 'Stale relay lock was recovered without explicit confirmation' >&2; exit 1
fi
grep -q -- '--recover-stale-lock' "$T/stale-lock-without-confirmation.log"
run_relay --recover-stale-lock > "$T/recovered-lock.log" 2>&1
grep -q 'Recovered relay lock from dead PID' "$T/recovered-lock.log"
test ! -d "$relay_work/lock"
printf 'relay smoke test passed\n'
