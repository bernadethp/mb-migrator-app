#!/usr/bin/env bash

wp_config_report() {
  local source_config="$1"
  local target_config="$2"
  local stage_dir="$3"

  wp_config_report_named "wp-config.php" "$source_config" "$target_config" "$stage_dir" "wp-config"
}

wp_config_report_named() {
  local label="$1"
  local source_config="$2"
  local target_config="$3"
  local stage_dir="$4"
  local output_slug="$5"
  local extra_file="$stage_dir/$output_slug-extra-from-export.txt"
  local diff_file="$stage_dir/$output_slug.diff"

  if [[ ! -f "$source_config" ]]; then
    log "No exported $label found"
    report "No exported $label found"
    return 0
  fi

  if [[ ! -f "$target_config" ]]; then
    log "Target $label not found; exported config is staged at $source_config"
    report "Target $label not found; exported config: $source_config"
    return 0
  fi

  log "Generating $label report"
  perl -ne 'print if /^\s*define\s*\(/ || /^\s*\$table_prefix\s*=/' "$source_config" > "$extra_file.export"
  perl -ne 'print if /^\s*define\s*\(/ || /^\s*\$table_prefix\s*=/' "$target_config" > "$extra_file.target"
  sort "$extra_file.export" > "$extra_file.export.sorted"
  sort "$extra_file.target" > "$extra_file.target.sorted"
  comm -23 "$extra_file.export.sorted" "$extra_file.target.sorted" > "$extra_file" || true
  diff -u "$target_config" "$source_config" > "$diff_file" || true

  report "$label exported constants not present in target: $extra_file"
  report "$label full diff: $diff_file"
  log "$label extra constants report: $extra_file"
  log "$label diff: $diff_file"
}

wp_config_migrate() {
  local source_config="$1"
  local target_config="$2"

  wp_config_migrate_named "wp-config.php" "$source_config" "$target_config"
}

wp_config_migrate_named() {
  local label="$1"
  local source_config="$2"
  local target_config="$3"

  [[ -f "$source_config" ]] || die "Exported $label not found: $source_config"

  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    log "Would replace $target_config with $source_config"
    return 0
  fi

  confirm "Replace target $label with exported $label?" || die "$label migration cancelled"

  local backup
  backup="$target_config.backup-$(date +%Y%m%d%H%M%S)"
  if [[ -f "$target_config" ]]; then
    cp -p "$target_config" "$backup"
    log "Backed up target $label to $backup"
    report "Backed up target $label to $backup"
  fi
  cp -p "$source_config" "$target_config"
  log "Migrated exported $label to $target_config"
  report "Migrated exported $label to $target_config"
}
