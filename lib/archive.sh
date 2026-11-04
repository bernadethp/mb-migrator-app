#!/usr/bin/env bash

ARCHIVE_INDEX=""

archive_validate_tar_index() {
  local archive="$1"
  local metadata="$2"
  local max_entries="${MB_MIGRATOR_MAX_ARCHIVE_ENTRIES:-500000}"
  local max_bytes="${MB_MIGRATOR_MAX_ARCHIVE_BYTES:-1099511627776}"
  local -a entries=() metadata_lines=() parts=()
  local index entry normalized folded type line part declared_bytes link_target link_relative
  local -A exact_paths=() folded_paths=()

  [[ "$max_entries" =~ ^[0-9]+$ && "$max_entries" -gt 0 ]] || die "Invalid archive entry safety limit"
  [[ "$max_bytes" =~ ^[0-9]+$ && "$max_bytes" -gt 0 ]] || die "Invalid archive byte safety limit"

  LC_ALL=C tar --numeric-owner --quoting-style=escape -tvzf "$archive" > "$metadata"
  mapfile -t entries < "$ARCHIVE_INDEX"
  mapfile -t metadata_lines < "$metadata"
  [[ "${#entries[@]}" -eq "${#metadata_lines[@]}" ]] || die "Archive contains an unsafe or ambiguous filename"
  (( ${#entries[@]} <= max_entries )) || die "Archive contains too many entries"

  declared_bytes="$(LC_ALL=C awk '
    $3 !~ /^[0-9]+$/ { exit 2 }
    { total += $3 }
    END { if (total >= 0) printf "%.0f\n", total }
  ' "$metadata")" || die "Archive metadata is malformed"
  [[ "$declared_bytes" =~ ^[0-9]+$ ]] || die "Archive byte size is unavailable"
  (( declared_bytes <= max_bytes )) || die "Archive declares too many uncompressed bytes"

  for index in "${!entries[@]}"; do
    entry="${entries[$index]}"
    line="${metadata_lines[$index]}"
    type="${line:0:1}"
    case "$type" in -|d|l) ;; *) die "Archive special files are not supported" ;; esac
    [[ "$entry" != *\\* ]] || die "Archive contains an unsafe path"
    if LC_ALL=C grep -q '[[:cntrl:]]' <<< "$entry"; then
      die "Archive contains an unsafe filename"
    fi
    normalized="$entry"
    while [[ "$normalized" == ./* ]]; do normalized="${normalized#./}"; done
    normalized="${normalized%/}"
    [[ -n "$normalized" ]] || continue
    [[ "$normalized" != /* ]] || die "Archive contains an absolute path"
    IFS='/' read -r -a parts <<< "$normalized"
    for part in "${parts[@]}"; do
      [[ -n "$part" && "$part" != . && "$part" != .. ]] || die "Archive contains path traversal"
    done
    if [[ "$type" == l ]]; then
      [[ "$line" == *" $entry -> "* ]] || die "Archive link metadata is ambiguous"
      link_target="${line#*" $entry -> "}"
      case "$normalized" in */wp-content/*) ;; *) die "Archive link is outside wp-content" ;; esac
      case "$link_target" in
        /*/wp-content/*) link_relative="${link_target#*/wp-content/}" ;;
        *) die "Archive link target is unsafe" ;;
      esac
      [[ -n "$link_relative" && "$link_relative" != /* && "$link_relative" != *\\* ]] || die "Archive link target is unsafe"
      IFS='/' read -r -a parts <<< "$link_relative"
      for part in "${parts[@]}"; do
        [[ -n "$part" && "$part" != . && "$part" != .. ]] || die "Archive link target is unsafe"
      done
    fi
    [[ -z "${exact_paths[$normalized]+present}" ]] || die "Archive contains a duplicate path"
    exact_paths[$normalized]=1
    folded="${normalized,,}"
    if [[ -n "${folded_paths[$folded]+present}" && "${folded_paths[$folded]}" != "$normalized" ]]; then
      die "Archive contains a case-colliding path"
    fi
    folded_paths[$folded]="$normalized"
  done
}

archive_index() {
  local archive="$1"
  local stage_dir="$2"
  local archive_metadata
  ARCHIVE_INDEX="$stage_dir/.archive-index.txt"

  if [[ -s "$ARCHIVE_INDEX" ]]; then
    log "Using existing archive index: $ARCHIVE_INDEX"
    return 0
  fi

  log "Indexing archive contents"
  case "$archive" in
    *.zip|*.ZIP) php "$ROOT_DIR/lib/wpengine-zip.php" index "$archive" > "$ARCHIVE_INDEX" ;;
    *)
      tar --quoting-style=escape -tzf "$archive" > "$ARCHIVE_INDEX"
      archive_metadata="$stage_dir/.archive-metadata.txt"
      archive_validate_tar_index "$archive" "$archive_metadata"
      rm -f "$archive_metadata"
      ;;
  esac
}

archive_has_path_prefix() {
  local prefix="$1"
  grep -Eq "^\./${prefix}(/|$)|^${prefix}(/|$)" "$ARCHIVE_INDEX"
}

archive_extract_existing_paths() {
  local archive="$1"
  local stage_dir="$2"
  shift 2

  local paths=()
  local path
  for path in "$@"; do
    if grep -Eq "^${path}(/|$)" "$ARCHIVE_INDEX"; then
      paths+=("$path")
    elif grep -Eq "^\./${path}(/|$)" "$ARCHIVE_INDEX"; then
      paths+=("./$path")
    else
      log "Archive path not present, skipping: $path"
    fi
  done

  if [[ "${#paths[@]}" -eq 0 ]]; then
    die "No requested archive paths exist"
  fi

  log "Extracting selected archive paths"
  case "$archive" in
    *.zip|*.ZIP) php "$ROOT_DIR/lib/wpengine-zip.php" extract "$archive" "$stage_dir" "${paths[@]}" ;;
    *) tar -xzf "$archive" -C "$stage_dir" "${paths[@]}" ;;
  esac
}
