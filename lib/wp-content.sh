#!/usr/bin/env bash

merge_wp_content() {
  local source_wp_content="$1"
  local dest_wp_content="$2"

  [[ -d "$source_wp_content" ]] || die "Source wp-content not found: $source_wp_content"
  [[ -d "$dest_wp_content" ]] || die "Destination wp-content not found: $dest_wp_content"

  PROTECTED_WEB_LINKS=""
  if [[ "${DRY_RUN:-0}" -ne 1 && "${REPLACE_MANAGED_SYMLINKS:-0}" -ne 1 ]]; then
    PROTECTED_WEB_LINKS="$(mktemp "${TMPDIR:-/tmp}/mb-protected-links.XXXXXX")"
    find "$dest_wp_content" -type l -print > "$PROTECTED_WEB_LINKS"
  fi
  log "Overlaying staged plugins, themes, and uploads onto the destination"
  merge_wp_content_subdir "$source_wp_content" "$dest_wp_content" "plugins"
  merge_wp_content_subdir "$source_wp_content" "$dest_wp_content" "themes"
  merge_wp_content_subdir "$source_wp_content" "$dest_wp_content" "uploads"

  if [[ "${INCLUDE_MU_PLUGINS:-0}" -eq 1 ]]; then
    merge_wp_content_subdir "$source_wp_content" "$dest_wp_content" "mu-plugins"
  fi

  if [[ "${DRY_RUN:-0}" -ne 1 ]]; then
    materialize_internal_web_symlinks "$source_wp_content" "$dest_wp_content"
    [[ -z "$PROTECTED_WEB_LINKS" ]] || rm -f "$PROTECTED_WEB_LINKS"
  fi
}

materialize_internal_web_symlinks() {
  local source_wp_content="$1"
  local dest_wp_content="$2"
  local link_list source_link link_target relative_path dest_link dest_target
  local pass progress converted=0 unresolved=0

  link_list="$dest_wp_content/.mb-migrator-symlinks.$$"
  find "$source_wp_content" -type l -print > "$link_list"

  for _pass in 1 2 3 4 5; do
    progress=0
    while IFS= read -r source_link; do
      link_target="$(readlink "$source_link")"
      case "$link_target" in
        /*/wp-content/*) relative_path="${link_target#*/wp-content/}" ;;
        *) continue ;;
      esac
      case "/$relative_path/" in
        */../*|*/./*) continue ;;
      esac

      dest_link="$dest_wp_content/${source_link#"$source_wp_content/"}"
      dest_target="$dest_wp_content/$relative_path"
      if [[ -n "${PROTECTED_WEB_LINKS:-}" ]] && grep -Fxq "$dest_link" "$PROTECTED_WEB_LINKS"; then continue; fi
      [[ -L "$dest_link" && -f "$dest_target" ]] || continue

      ln -f "$dest_target" "$dest_link"
      converted=$((converted + 1))
      progress=$((progress + 1))
    done < "$link_list"
    [[ "$progress" -gt 0 ]] || break
  done

  while IFS= read -r source_link; do
    link_target="$(readlink "$source_link")"
    case "$link_target" in
      /*/wp-content/*)
        dest_link="$dest_wp_content/${source_link#"$source_wp_content/"}"
        [[ ! -L "$dest_link" ]] || unresolved=$((unresolved + 1))
        ;;
    esac
  done < "$link_list"
  rm -f "$link_list"

  if [[ "$converted" -gt 0 ]]; then
    log "Converted $converted legacy absolute web symlink(s) to nginx-compatible hard links"
    report "Converted legacy absolute web symlinks to hard links: $converted"
  fi
  if [[ "$unresolved" -gt 0 ]]; then
    warn "$unresolved legacy absolute web symlink(s) still have missing destination targets"
    report "Legacy absolute web symlinks with missing targets: $unresolved"
  fi
}

merge_wp_content_subdir() {
  local source_wp_content="$1"
  local dest_wp_content="$2"
  local subdir="$3"
  local src="$source_wp_content/$subdir"
  local dest="$dest_wp_content/$subdir"

  if [[ ! -d "$src" ]]; then
    log "No exported wp-content/$subdir directory; skipping"
    return 0
  fi

  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    log "Would merge $src -> $dest"
    return 0
  fi

  mkdir -p "$dest"

  local item name dest_item item_list protected excluded
  local -a backup_args
  item_list="$dest/.mb-migrator-items.$$"
  find "$src" -mindepth 1 -maxdepth 1 -print > "$item_list"

  while IFS= read -r item; do
    name="$(basename "$item")"
    dest_item="$dest/$name"

    if [[ "$subdir" == "plugins" ]] && is_platform_plugin_excluded "$name"; then
      log "Skipping platform-managed plugin: $name"
      report "Skipped platform-managed plugin: $name"
      continue
    fi

    if [[ "$subdir" == "mu-plugins" ]] && is_platform_mu_plugin_excluded "$name"; then
      report "Skipped platform MU plugin: $name"
      continue
    fi

    if [[ -L "$dest_item" && "${REPLACE_MANAGED_SYMLINKS:-0}" -ne 1 ]]; then
      log "Preserving destination symlink: $dest_item"
      report "Preserved destination symlink: $dest_item"
      continue
    fi

    backup_args=()
    if [[ -n "${PROTECTED_WEB_LINKS:-}" ]]; then
      while IFS= read -r protected; do
        case "$protected" in
          "$dest_item"/*)
            excluded="${protected#"$dest_item"/}"
            excluded="$(printf '%s' "$excluded" | sed 's/[][?*\\]/\\&/g')"
            backup_args+=("--exclude=/$excluded") ;;
        esac
      done < "$PROTECTED_WEB_LINKS"
    fi
    if [[ -n "${ROLLBACK_DIR:-}" ]]; then
      rollback_record_added "$item" "$dest_item" "wp-content/$subdir/$name"
      if [[ ! -d "$item" ]]; then backup_args+=(--backup "--backup-dir=$ROLLBACK_DIR/files/wp-content/$subdir"); fi
    fi
    if [[ -d "$item" ]]; then
      if [[ -n "${ROLLBACK_DIR:-}" ]]; then
        backup_args+=(--backup "--backup-dir=$ROLLBACK_DIR/files/wp-content/$subdir/$name")
      fi
      mkdir -p "$dest_item"
      rsync -rlt --checksum "${backup_args[@]}" --perms --chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r \
        --no-owner --no-group --omit-dir-times "$item/" "$dest_item/"
    else
      rsync -rlt --checksum "${backup_args[@]}" --perms --chmod=Fu=rw,Fgo=r \
        --no-owner --no-group --omit-dir-times "$item" "$dest/"
    fi
  done < "$item_list"
  rm -f "$item_list"

  report "Merged wp-content/$subdir from $src to $dest"
}

is_platform_mu_plugin_excluded() {
  case "$1" in
    mu-plugin.php|wpengine-*|wpe-*|force-strong-passwords|slt-force-strong-passwords.php|stop-long-comments.php|mb-migrator-safety.php|mb-wanp-staging-guard.php) return 0 ;;
  esac
  return 1
}

is_platform_plugin_excluded() {
  local plugin_slug="$1"

  case "$plugin_slug" in
    nginx-helper|redis-cache|redis-object-cache|redis-cache-pro|gridpane-redis-object-cache|wp-redis|wp-redis-cache|object-cache-pro|*redis*object*cache*)
      return 0
      ;;
  esac

  return 1
}

copy_web_root_files() {
  local source_web_root="$1"
  local target_root="$2"
  shift 2

  if [[ "$#" -eq 0 ]]; then
    log "No selected root-level extra files to copy"
    return 0
  fi

  [[ -d "$source_web_root" ]] || die "Source web root not found: $source_web_root"
  [[ -d "$target_root" ]] || die "Target root not found: $target_root"

  log "Copying root-level extra files"

  local archive_path relative_name source_file target_file
  for archive_path in "$@"; do
    relative_name="${archive_path#*/}"
    source_file="$source_web_root/$relative_name"
    target_file="$target_root/$relative_name"

    if [[ ! -f "$source_file" ]]; then
      log "Expected root-level file not found after extraction: $source_file"
      report "Missing extracted root-level file: $source_file"
      continue
    fi

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
      log "Would copy $source_file -> $target_file"
      continue
    fi

    if [[ -L "$target_file" && "${REPLACE_MANAGED_SYMLINKS:-0}" -ne 1 ]]; then
      report "Preserved destination root symlink: $target_file"
      continue
    fi
    local -a backup_args=()
    if [[ -n "${ROLLBACK_DIR:-}" ]]; then
      rollback_record_added "$source_file" "$target_file" "$relative_name"
      backup_args=(--backup "--backup-dir=$ROLLBACK_DIR/files")
    fi
    rsync -lt --checksum "${backup_args[@]}" --perms --chmod=Fu=rw,Fgo=r \
      --no-owner --no-group --omit-dir-times "$source_file" "$target_file"
    report "Copied root-level file from $source_file to $target_file"
  done
}
