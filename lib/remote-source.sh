#!/usr/bin/env bash
set -euo pipefail

command_name="${1:-}"
source_root="${2:-}"
db_method="${3:-auto}"
source_config=""

fail() {
  printf '[source-collector:error] %s\n' "$*" >&2
  exit 1
}

[[ "$source_root" == /* ]] || fail "source root must be absolute"
[[ -d "$source_root/wp-content" ]] || fail "wp-content not found: $source_root/wp-content"

if [[ -r "$source_root/wp-config.php" ]]; then
  source_config="$source_root/wp-config.php"
elif [[ "$(basename "$source_root")" == "htdocs" && -r "$(dirname "$source_root")/wp-config.php" ]]; then
  source_config="$(dirname "$source_root")/wp-config.php"
else
  fail "wp-config.php is not readable in the source root or its GridPane parent: $source_root"
fi

source_wp() (
  cd "$source_root" || return 1
  wp "$@"
)

config_value() {
  local key="$1" type="${2:-constant}" value=""
  if command -v wp >/dev/null 2>&1; then
    if value="$(source_wp --skip-plugins --skip-themes config get "$key" --type="$type" --quiet 2>/dev/null)"; then
      printf '%s' "$value"
      return 0
    fi
  fi
  command -v php >/dev/null 2>&1 || return 1
  php -n -r '
    $text = file_get_contents($argv[1]);
    $key = preg_quote($argv[2], "/");
    $kind = $argv[3];
    if ($kind === "variable") {
      $pattern = "/\\$" . $key . "\\s*=\\s*([\\x27\\x22])((?:\\\\.|(?!\\1).)*)\\1\\s*;/s";
    } else {
      $pattern = "/define\\s*\\(\\s*[\\x27\\x22]" . $key . "[\\x27\\x22]\\s*,\\s*([\\x27\\x22])((?:\\\\.|(?!\\1).)*)\\1\\s*\\)/s";
    }
    if (preg_match($pattern, $text, $m)) { echo stripcslashes($m[2]); exit(0); }
    $envPattern = "/define\\s*\\(\\s*[\\x27\\x22]" . $key . "[\\x27\\x22]\\s*,\\s*getenv\\s*\\(\\s*([\\x27\\x22])([^\\x27\\x22]+)\\1\\s*\\)\\s*\\)/s";
    if ($kind === "constant" && preg_match($envPattern, $text, $m)) {
      $v = getenv($m[2]); if ($v !== false) { echo $v; exit(0); }
    }
    if ($kind === "constant") {
      $v = getenv($argv[2]); if ($v !== false) { echo $v; exit(0); }
    }
    exit(1);
  ' "$source_config" "$key" "$type"
}

is_multisite() {
  local value=""
  if command -v wp >/dev/null 2>&1 && source_wp --skip-plugins --skip-themes core is-installed --network >/dev/null 2>&1; then
    return 0
  fi
  value="$(config_value MULTISITE 2>/dev/null || true)"
  case "$value" in 1|true|TRUE) return 0 ;; esac
  grep -Eq "define[[:space:]]*\([[:space:]]*['\"]MULTISITE['\"][[:space:]]*,[[:space:]]*(true|TRUE|1)[[:space:]]*\)" "$source_config" && return 0
  return 1
}

ini_escape() {
  local value="$1"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || fail "database settings cannot contain newlines"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

create_native_config() {
  local cnf="$1" db_user db_password db_host host port socket
  NATIVE_DB_NAME="$(config_value DB_NAME)" || fail "could not resolve DB_NAME from wp-config.php"
  db_user="$(config_value DB_USER)" || fail "could not resolve DB_USER from wp-config.php"
  db_password="$(config_value DB_PASSWORD)" || fail "could not resolve DB_PASSWORD from wp-config.php"
  db_host="$(config_value DB_HOST)" || fail "could not resolve DB_HOST from wp-config.php"
  host="$db_host"; port=""; socket=""
  if [[ "$db_host" == *:/* ]]; then host="${db_host%%:*}"; socket="${db_host#*:}"
  elif [[ "$db_host" == *:* && "${db_host##*:}" =~ ^[0-9]+$ ]]; then host="${db_host%:*}"; port="${db_host##*:}"; fi

  chmod 600 "$cnf"
  {
    printf '[client]\nuser="%s"\npassword="%s"\nhost="%s"\n' "$(ini_escape "$db_user")" "$(ini_escape "$db_password")" "$(ini_escape "$host")"
    [[ -z "$port" ]] || printf 'port=%s\n' "$port"
    [[ -z "$socket" ]] || printf 'socket="%s"\n' "$(ini_escape "$socket")"
  } > "$cnf"
}

dump_supports_column_statistics() {
  local dump_bin="$1" dump_help
  dump_help="$("$dump_bin" --help 2>&1 || true)"
  case "$dump_help" in
    *--column-statistics*) return 0 ;;
    *) return 1 ;;
  esac
}

native_dump() (
  local dump_bin cnf
  local -a dump_args
  if command -v mariadb-dump >/dev/null 2>&1; then dump_bin="$(command -v mariadb-dump)"
  elif command -v mysqldump >/dev/null 2>&1; then dump_bin="$(command -v mysqldump)"
  else fail "neither mariadb-dump nor mysqldump is available"; fi
  cnf="$(mktemp "${TMPDIR:-/tmp}/mb-migrator-db.XXXXXX")"
  trap 'rm -f "$cnf"' EXIT
  create_native_config "$cnf"
  dump_args=(
    "--defaults-extra-file=$cnf"
    --single-transaction
    --quick
    --skip-lock-tables
    --hex-blob
    --default-character-set=utf8mb4
    --skip-add-drop-table
  )
  if dump_supports_column_statistics "$dump_bin"; then
    dump_args+=(--column-statistics=0)
  fi
  "$dump_bin" "${dump_args[@]}" "$NATIVE_DB_NAME"
  rm -f "$cnf"
)

get_source_url() (
  local value="" client_bin cnf prefix
  if command -v wp >/dev/null 2>&1; then
    if value="$(source_wp --skip-plugins --skip-themes option get home --quiet 2>/dev/null)" && [[ -n "$value" ]]; then
      printf '%s\n' "$value"
      return 0
    fi
  fi
  if command -v mariadb >/dev/null 2>&1; then client_bin="$(command -v mariadb)"
  elif command -v mysql >/dev/null 2>&1; then client_bin="$(command -v mysql)"
  else return 1; fi
  prefix="$(config_value table_prefix variable)" || return 1
  [[ "$prefix" =~ ^[A-Za-z0-9_]+$ ]] || fail "unsafe table prefix in wp-config.php"
  cnf="$(mktemp "${TMPDIR:-/tmp}/mb-migrator-db.XXXXXX")"
  trap 'rm -f "$cnf"' EXIT
  create_native_config "$cnf"
  value="$("$client_bin" --defaults-extra-file="$cnf" --batch --skip-column-names "$NATIVE_DB_NAME" -e "SELECT option_value FROM ${prefix}options WHERE option_name='home' LIMIT 1" 2>/dev/null)" || return 1
  rm -f "$cnf"; trap - EXIT
  [[ -n "$value" ]] || return 1
  printf '%s\n' "$value"
)

export_database() (
  local dump_file wp_dump_bin=""
  local -a wp_export_args
  dump_file="$(mktemp "${TMPDIR:-/tmp}/mb-migrator-export.sql.XXXXXX")"
  chmod 600 "$dump_file"
  trap 'rm -f "$dump_file"' EXIT
  if [[ "$db_method" != "native" ]] && command -v wp >/dev/null 2>&1; then
    wp_export_args=(--skip-plugins --skip-themes --quiet db export "$dump_file")
    if command -v mysqldump >/dev/null 2>&1; then
      wp_dump_bin="$(command -v mysqldump)"
      if dump_supports_column_statistics "$wp_dump_bin"; then
        wp_export_args+=(--column-statistics=0)
      fi
    fi
    if source_wp "${wp_export_args[@]}" >&2; then
      cat "$dump_file"
      return 0
    fi
    [[ "$db_method" == "auto" ]] || fail "WP-CLI database export failed"
    printf '[source-collector:warn] WP-CLI export failed; using native dump\n' >&2
  fi
  [[ "$db_method" != "wp-cli" ]] || fail "WP-CLI is unavailable"
  native_dump
)

check_database_export() {
  local wp_ok=0 native_ok=0 ignored
  if command -v wp >/dev/null 2>&1 && source_wp --skip-plugins --skip-themes db query "SELECT 1" --skip-column-names >/dev/null 2>&1; then
    wp_ok=1
  fi
  if command -v php >/dev/null 2>&1 && { command -v mariadb-dump >/dev/null 2>&1 || command -v mysqldump >/dev/null 2>&1; }; then
    native_ok=1
    for ignored in DB_NAME DB_USER DB_PASSWORD DB_HOST; do
      config_value "$ignored" >/dev/null 2>&1 || native_ok=0
    done
  fi
  case "$db_method" in
    wp-cli) [[ "$wp_ok" -eq 1 ]] || fail "WP-CLI cannot read the source database configuration" ;;
    native) [[ "$native_ok" -eq 1 ]] || fail "native export requires PHP, a dump client, and resolvable wp-config.php credentials" ;;
    auto) [[ "$wp_ok" -eq 1 || "$native_ok" -eq 1 ]] || fail "no usable WP-CLI or native database export path was found" ;;
    *) fail "invalid database method: $db_method" ;;
  esac
}

is_core_root_file() {
  case "$1" in index.php|license.txt|readme.html|wp-*.php|xmlrpc.php) return 0 ;; esac
  return 1
}

is_migration_artifact_root_file() {
  case "$1" in
    wordpress-package-*.tar.gz|wordpress-package-*.tar.gz.sha256|db-backup-before-import-*.sql|mb-migrator-report-*.txt)
      return 0
      ;;
  esac
  return 1
}

archive_files() {
  local include_content="$1" item name tar_status=0 tar_errors
  local paths=()
  [[ "$include_content" -eq 0 ]] || paths+=("wp-content")
  while IFS= read -r item; do
    name="${item#./}"
    is_core_root_file "$name" || is_migration_artifact_root_file "$name" || paths+=("$name")
  done < <(cd "$source_root" && find . -mindepth 1 -maxdepth 1 -type f -print | LC_ALL=C sort)
  tar_errors="$(mktemp "${TMPDIR:-/tmp}/mb-migrator-tar-errors.XXXXXX")"
  trap 'rm -f "$tar_errors"' RETURN
  if [[ "${#paths[@]}" -gt 0 ]]; then
    tar -czf - -C "$source_root" -- "${paths[@]}" 2> "$tar_errors" || tar_status=$?
  else
    tar -czf - -C "$source_root" --files-from /dev/null 2> "$tar_errors" || tar_status=$?
  fi
  if [[ "$tar_status" -eq 1 ]] && [[ -s "$tar_errors" ]] &&
     ! grep -Ev '^tar: (\./)?wp-content: file changed as we read it$' "$tar_errors" | grep -q .; then
    printf '[source-collector:warn] wp-content changed during collection; continuing with the valid live snapshot\n' >&2
    tar_status=0
  elif [[ "$tar_status" -ne 0 ]]; then
    cat "$tar_errors" >&2
  fi
  rm -f "$tar_errors"
  trap - RETURN
  return "$tar_status"
}

case "$command_name" in
  preflight)
    command -v tar >/dev/null 2>&1 || fail "tar is unavailable"
    is_multisite && fail "WordPress Multisite is not supported"
    check_database_export
    printf 'source_root=%s\n' "$source_root"
    printf 'source_config=%s\n' "$source_config"
    printf 'wp_cli=%s\n' "$(command -v wp 2>/dev/null || printf unavailable)"
    printf 'rsync=%s\n' "$(command -v rsync 2>/dev/null || printf unavailable)"
    files_kb="$(du -sk "$source_root" 2>/dev/null | awk 'NR == 1 {print $1}')"
    [[ "$files_kb" =~ ^[0-9]+$ ]] || fail "source file size could not be measured"
    printf 'files_kb=%s\n' "$files_kb"
    ;;
  export-db) export_database ;;
  get-url) get_source_url ;;
  archive-files) archive_files 1 ;;
  archive-root) archive_files 0 ;;
  *) fail "unknown remote command: $command_name" ;;
esac
