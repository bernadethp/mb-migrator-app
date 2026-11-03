#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT_DIR"

for command in bash git php shellcheck; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'Required validation tool is unavailable: %s\n' "$command" >&2
    exit 2
  fi
done

printf 'bash: %s\n' "${BASH_VERSION}"
printf 'php: %s\n' "$(php -r 'echo PHP_VERSION;')"
printf 'shellcheck: %s\n' "$(shellcheck --version | awk '/^version:/ { print $2 }')"

mapfile -t shell_files < <(
  git ls-files '*.sh' 'bin/*' 'remote-run.sh' |
    while IFS= read -r file; do
      if [[ "$file" == *.sh ]] || head -n 1 "$file" | grep -q '^#!.*\(ba\)\?sh'; then
        printf '%s\n' "$file"
      fi
    done
)

if ((${#shell_files[@]} == 0)); then
  printf 'No shell files were discovered.\n' >&2
  exit 1
fi

printf 'Checking Bash syntax in %d files...\n' "${#shell_files[@]}"
bash -n "${shell_files[@]}"

printf 'Checking PHP helper syntax...\n'
php -l lib/migration-safety.php
php -l lib/wpengine-zip.php

printf 'Running ShellCheck...\n'
shellcheck -x -S warning "${shell_files[@]}"

smoke_suites=(
  tests/smoke.sh
  tests/live-smoke.sh
  tests/native-db-smoke.sh
  tests/package-smoke.sh
  tests/portability-smoke.sh
  tests/push-smoke.sh
  tests/relay-smoke.sh
)

for suite in "${smoke_suites[@]}"; do
  printf 'Running %s...\n' "$suite"
  bash "$suite"
done

printf 'All validation checks passed.\n'
