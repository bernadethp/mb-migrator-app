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
  *'core is-installed --network'*) exit 1 ;;
  *'core is-installed'*) exit 0 ;;
  *'post list '*--format=count*) [[ "${RELAY_TARGET_MODIFIED:-0}" == 1 ]] && echo 4 || echo 2 ;;
  *'user list --format=count'*) echo 1 ;;
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
chmod +x "$T/bin/"*
export RELAY_REAL_RSYNC="$REAL_RSYNC"
export PATH="$T/bin:$PATH"
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
    --db-import=no --mu-plugins=skip --root-extras=skip --yes
}
run_relay > "$T/first.log"
[[ "$(cat "$T/target/wp-content/uploads/test.txt")" == first ]]
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
printf 'relay smoke test passed\n'
