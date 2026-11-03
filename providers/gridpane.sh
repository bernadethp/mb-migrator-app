#!/usr/bin/env bash

GRIDPANE_DB_DIR=""
GRIDPANE_WEB_ROOT=""
GRIDPANE_ROOT_EXTRA_FILES=()
GRIDPANE_ROOT_EXTRA_CANDIDATES=()
GRIDPANE_MU_PLUGINS_PRESENT=0
GRIDPANE_ARCHIVED_ASSETS_DIR=""
GRIDPANE_WP_CONFIG_PATH=""
GRIDPANE_USER_CONFIGS_PATH=""

gridpane_detect() {
  local index_file="$1"
  grep -Eq '^\./database-[^/]+/|^database-[^/]+/' "$index_file" && \
    grep -Eq '^\./htdocs/wp-content/|^htdocs/wp-content/' "$index_file"
}

gridpane_load_layout() {
  local index_file="$1"
  local root_file root_name root_files_list

  GRIDPANE_DB_DIR="$(awk '{ line=$0; sub(/^\.\//, "", line); split(line, parts, "/"); if (parts[1] ~ /^database-/ && parts[2] != "") { print parts[1]; exit } }' "$index_file")"
  GRIDPANE_WEB_ROOT="htdocs"
  GRIDPANE_ROOT_EXTRA_FILES=()
  GRIDPANE_ROOT_EXTRA_CANDIDATES=()
  GRIDPANE_MU_PLUGINS_PRESENT=0
  GRIDPANE_ARCHIVED_ASSETS_DIR=""
  GRIDPANE_WP_CONFIG_PATH=""
  GRIDPANE_USER_CONFIGS_PATH=""

  [[ -n "$GRIDPANE_DB_DIR" ]] || die "Could not find GridPane database-* directory in archive"
  grep -Eq '^\./htdocs/wp-content/|^htdocs/wp-content/' "$index_file" || die "Could not find htdocs/wp-content in archive"
  GRIDPANE_ARCHIVED_ASSETS_DIR="$(awk '{ line=$0; sub(/^\.\//, "", line); split(line, parts, "/"); if (parts[1] ~ /-archived-assets$/ && parts[2] != "") { print parts[1]; exit } }' "$index_file")"

  if grep -Eq '^\./htdocs/wp-config\.php$|^htdocs/wp-config\.php$' "$index_file"; then
    GRIDPANE_WP_CONFIG_PATH="htdocs/wp-config.php"
  elif [[ -n "$GRIDPANE_ARCHIVED_ASSETS_DIR" ]] && grep -Eq "^\\./${GRIDPANE_ARCHIVED_ASSETS_DIR}/wp-config\\.php$|^${GRIDPANE_ARCHIVED_ASSETS_DIR}/wp-config\\.php$" "$index_file"; then
    GRIDPANE_WP_CONFIG_PATH="$GRIDPANE_ARCHIVED_ASSETS_DIR/wp-config.php"
  fi

  if [[ -n "$GRIDPANE_ARCHIVED_ASSETS_DIR" ]] && grep -Eq "^\\./${GRIDPANE_ARCHIVED_ASSETS_DIR}/user-configs\\.php$|^${GRIDPANE_ARCHIVED_ASSETS_DIR}/user-configs\\.php$" "$index_file"; then
    GRIDPANE_USER_CONFIGS_PATH="$GRIDPANE_ARCHIVED_ASSETS_DIR/user-configs.php"
  fi

  if grep -Eq '^\./htdocs/wp-content/mu-plugins(/|$)|^htdocs/wp-content/mu-plugins(/|$)' "$index_file"; then
    GRIDPANE_MU_PLUGINS_PRESENT=1
  fi

  root_files_list="${index_file}.root-files.$$"
  grep -E '^\./htdocs/[^/]+$|^htdocs/[^/]+$' "$index_file" > "$root_files_list" || true

  while IFS= read -r root_file; do
    root_file="${root_file#./}"
    root_name="${root_file#htdocs/}"

    if gridpane_is_auto_root_extra "$root_name"; then
      GRIDPANE_ROOT_EXTRA_FILES+=("$root_file")
    elif ! gridpane_is_core_root_file "$root_name"; then
      GRIDPANE_ROOT_EXTRA_CANDIDATES+=("$root_file")
    fi
  done < "$root_files_list"
  rm -f "$root_files_list"

  report "GridPane database directory: $GRIDPANE_DB_DIR"
  report "GridPane web root: $GRIDPANE_WEB_ROOT"
  report "GridPane archived assets directory: ${GRIDPANE_ARCHIVED_ASSETS_DIR:-none}"
  report "GridPane wp-config source: ${GRIDPANE_WP_CONFIG_PATH:-none}"
  report "GridPane user-configs source: ${GRIDPANE_USER_CONFIGS_PATH:-none}"
  report "GridPane mu-plugins present: $GRIDPANE_MU_PLUGINS_PRESENT"
  if [[ "${#GRIDPANE_ROOT_EXTRA_FILES[@]}" -gt 0 ]]; then
    report "GridPane auto root extra files: ${GRIDPANE_ROOT_EXTRA_FILES[*]}"
  else
    report "GridPane auto root extra files: none"
  fi
  if [[ "${#GRIDPANE_ROOT_EXTRA_CANDIDATES[@]}" -gt 0 ]]; then
    report "GridPane root extra candidates: ${GRIDPANE_ROOT_EXTRA_CANDIDATES[*]}"
  else
    report "GridPane root extra candidates: none"
  fi
}

gridpane_is_auto_root_extra() {
  local root_name="$1"
  [[ "$root_name" =~ [Vv][Ii][Rr][Uu][Ss][-_]?[Dd][Ii][Ee] || "$root_name" =~ ^[Vv][Dd][Cc][Oo][Nn][Nn][Ee][Cc][Tt]-[^/]+\.php$ ]]
}

gridpane_is_core_root_file() {
  local root_name="$1"

  case "$root_name" in
    index.php|license.txt|readme.html|wp-*.php|xmlrpc.php)
      return 0
      ;;
  esac

  return 1
}

gridpane_select_optional_paths() {
  local mu_plugins_mode="$1"
  local root_extras_mode="$2"
  local candidate

  INCLUDE_MU_PLUGINS=0

  if [[ "$GRIDPANE_MU_PLUGINS_PRESENT" -eq 1 ]]; then
    log "Exported wp-content/mu-plugins detected"
    case "$mu_plugins_mode" in
      copy)
        INCLUDE_MU_PLUGINS=1
        report "Selected mu-plugins: copy"
        ;;
      skip)
        report "Selected mu-plugins: skip"
        ;;
      ask)
        if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
          log "Would ask whether to copy exported wp-content/mu-plugins"
          report "Selected mu-plugins: ask deferred by dry-run"
        elif confirm "Copy exported wp-content/mu-plugins? They can be platform-specific."; then
          INCLUDE_MU_PLUGINS=1
          report "Selected mu-plugins: copy"
        else
          report "Selected mu-plugins: skip"
        fi
        ;;
    esac
  fi

  if [[ "${#GRIDPANE_ROOT_EXTRA_CANDIDATES[@]}" -eq 0 ]]; then
    report "Selected root extra candidates: none"
    return 0
  fi

  log "Detected ${#GRIDPANE_ROOT_EXTRA_CANDIDATES[@]} non-core root file candidate(s)"

  case "$root_extras_mode" in
    copy)
      GRIDPANE_ROOT_EXTRA_FILES+=("${GRIDPANE_ROOT_EXTRA_CANDIDATES[@]}")
      report "Selected root extra candidates: all"
      ;;
    skip)
      report "Selected root extra candidates: skip all"
      ;;
    ask)
      for candidate in "${GRIDPANE_ROOT_EXTRA_CANDIDATES[@]}"; do
        if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
          log "Would ask whether to copy root-level file: $candidate"
          report "Root extra candidate deferred by dry-run: $candidate"
        elif confirm "Copy non-core root file $candidate?"; then
          GRIDPANE_ROOT_EXTRA_FILES+=("$candidate")
          report "Selected root extra candidate: $candidate"
        else
          report "Skipped root extra candidate: $candidate"
        fi
      done
      ;;
  esac
}

gridpane_extract() {
  local archive="$1"
  local stage_dir="$2"
  local include_mu_plugins="$3"

  local paths=(
    "$GRIDPANE_DB_DIR"
    "$GRIDPANE_WEB_ROOT/wp-content/plugins"
    "$GRIDPANE_WEB_ROOT/wp-content/themes"
    "$GRIDPANE_WEB_ROOT/wp-content/uploads"
  )

  if [[ -n "$GRIDPANE_WP_CONFIG_PATH" ]]; then
    paths+=("$GRIDPANE_WP_CONFIG_PATH")
  fi

  if [[ -n "$GRIDPANE_USER_CONFIGS_PATH" ]]; then
    paths+=("$GRIDPANE_USER_CONFIGS_PATH")
  fi

  if [[ "$include_mu_plugins" -eq 1 ]]; then
    paths+=("$GRIDPANE_WEB_ROOT/wp-content/mu-plugins")
  fi

  if [[ "${#GRIDPANE_ROOT_EXTRA_FILES[@]}" -gt 0 ]]; then
    paths+=("${GRIDPANE_ROOT_EXTRA_FILES[@]}")
  fi

  archive_extract_existing_paths "$archive" "$stage_dir" "${paths[@]}"
}

gridpane_publish_layout() {
  PROVIDER_DB_DIR="$GRIDPANE_DB_DIR"
  PROVIDER_WEB_ROOT="$GRIDPANE_WEB_ROOT"
  PROVIDER_ROOT_EXTRA_FILES=()
  if [[ "${#GRIDPANE_ROOT_EXTRA_FILES[@]}" -gt 0 ]]; then
    PROVIDER_ROOT_EXTRA_FILES=("${GRIDPANE_ROOT_EXTRA_FILES[@]}")
  fi
  PROVIDER_WP_CONFIG_PATH="$GRIDPANE_WP_CONFIG_PATH"
  PROVIDER_USER_CONFIGS_PATH="$GRIDPANE_USER_CONFIGS_PATH"
}
