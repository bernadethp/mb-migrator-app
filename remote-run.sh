#!/usr/bin/env bash
set -euo pipefail

REPO="${MB_MIGRATOR_REPO:-bernadethp/mb-migrator-app}"
REF="${MB_MIGRATOR_REF:-}"
RELEASE_VERSION="${MB_MIGRATOR_VERSION:-}"
EXPECTED_REVISION="${MB_MIGRATOR_REVISION:-}"
TMP_PARENT="${MB_MIGRATOR_TMPDIR:-${TMPDIR:-/tmp}}"
WORKDIR="$(mktemp -d "$TMP_PARENT/mb-migrator.XXXXXX")"

cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf '[mb-migrator:error] Required command not found: %s\n' "$1" >&2
    exit 1
  }
}

validate_archive() {
  local archive="$1" expected_prefix="${2:-}"
  local names="$WORKDIR/archive-names" metadata="$WORKDIR/archive-metadata"
  local entry normalized folded type line prefix="" declared_bytes
  local -a entries=() metadata_lines=() parts=()
  local -A exact_paths=() folded_paths=()

  LC_ALL=C tar --quoting-style=escape -tzf "$archive" > "$names"
  LC_ALL=C tar --numeric-owner --quoting-style=escape -tvzf "$archive" > "$metadata"
  mapfile -t entries < "$names"
  mapfile -t metadata_lines < "$metadata"
  [[ "${#entries[@]}" -gt 0 && "${#entries[@]}" -eq "${#metadata_lines[@]}" && "${#entries[@]}" -le 20000 ]] || {
    printf '[mb-migrator:error] Downloaded archive has an unsafe entry count.\n' >&2
    exit 1
  }
  declared_bytes="$(LC_ALL=C awk '$3 !~ /^[0-9]+$/ { exit 2 } { total += $3 } END { printf "%.0f\n", total }' "$metadata")" || {
    printf '[mb-migrator:error] Downloaded archive metadata is malformed.\n' >&2
    exit 1
  }
  [[ "$declared_bytes" =~ ^[0-9]+$ && "$declared_bytes" -le 536870912 ]] || {
    printf '[mb-migrator:error] Downloaded archive exceeds the extraction limit.\n' >&2
    exit 1
  }

  for index in "${!entries[@]}"; do
    entry="${entries[$index]}"
    line="${metadata_lines[$index]}"
    type="${line:0:1}"
    [[ "$type" == - || "$type" == d ]] || {
      printf '[mb-migrator:error] Downloaded archive contains a link or special file.\n' >&2
      exit 1
    }
    [[ "$entry" != *\\* && "$entry" != /* ]] || {
      printf '[mb-migrator:error] Downloaded archive contains an unsafe path.\n' >&2
      exit 1
    }
    normalized="${entry%/}"
    IFS='/' read -r -a parts <<< "$normalized"
    [[ "${#parts[@]}" -ge 1 ]] || exit 1
    for part in "${parts[@]}"; do
      [[ -n "$part" && "$part" != . && "$part" != .. ]] || {
        printf '[mb-migrator:error] Downloaded archive contains path traversal.\n' >&2
        exit 1
      }
    done
    if [[ -z "$prefix" ]]; then prefix="${parts[0]}"; fi
    [[ "${parts[0]}" == "$prefix" ]] || {
      printf '[mb-migrator:error] Downloaded archive contains multiple roots.\n' >&2
      exit 1
    }
    [[ -z "${exact_paths[$normalized]+present}" ]] || {
      printf '[mb-migrator:error] Downloaded archive contains a duplicate path.\n' >&2
      exit 1
    }
    exact_paths[$normalized]=1
    folded="${normalized,,}"
    [[ -z "${folded_paths[$folded]+present}" || "${folded_paths[$folded]}" == "$normalized" ]] || {
      printf '[mb-migrator:error] Downloaded archive contains a case-colliding path.\n' >&2
      exit 1
    }
    folded_paths[$folded]="$normalized"
  done
  [[ -z "$expected_prefix" || "$prefix" == "$expected_prefix" ]] || {
    printf '[mb-migrator:error] Downloaded archive identity is invalid.\n' >&2
    exit 1
  }
}

download() {
  local url="$1" output="$2"
  if command -v curl >/dev/null 2>&1; then
    curl --proto '=https' --tlsv1.2 -fsSL "$url" -o "$output"
  elif command -v wget >/dev/null 2>&1; then
    wget --https-only -qO "$output" "$url"
  else
    printf '[mb-migrator:error] Required command not found: curl or wget\n' >&2
    exit 1
  fi
}

need_cmd tar
[[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || {
  printf '[mb-migrator:error] Invalid repository name.\n' >&2
  exit 1
}
if [[ -n "$RELEASE_VERSION" ]]; then
  [[ -z "$REF" ]] || { printf '[mb-migrator:error] Choose a release version or a development revision, not both.\n' >&2; exit 1; }
  [[ "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || { printf '[mb-migrator:error] Invalid release version.\n' >&2; exit 1; }
  [[ "$EXPECTED_REVISION" =~ ^[a-f0-9]{40}$ ]] || { printf '[mb-migrator:error] MB_MIGRATOR_REVISION must be the release commit SHA.\n' >&2; exit 1; }
elif [[ ! "$REF" =~ ^[a-f0-9]{40}$ ]]; then
  printf '[mb-migrator:error] Development execution requires MB_MIGRATOR_REF set to a full 40-character commit SHA.\n' >&2
  exit 1
else
  printf '[mb-migrator:warn] Running immutable development revision %s; this is not a supported release.\n' "$REF" >&2
fi

ARCHIVE="$WORKDIR/source.tar.gz"
if [[ -n "$RELEASE_VERSION" ]]; then
  asset="mb-migrator-$RELEASE_VERSION.tar.gz"
  url="https://github.com/$REPO/releases/download/v$RELEASE_VERSION/$asset"
  checksum="$WORKDIR/$asset.sha256"
  download "$url" "$ARCHIVE"
  download "$url.sha256" "$checksum"
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
  else
    printf '[mb-migrator:error] Required command not found: sha256sum or shasum\n' >&2
    exit 1
  fi
  read -r expected expected_name extra < "$checksum" || { printf '[mb-migrator:error] Release checksum is unreadable.\n' >&2; exit 1; }
  [[ "$expected" =~ ^[a-f0-9]{64}$ && "$expected_name" == "$asset" && -z "${extra:-}" && "$actual" == "$expected" ]] || {
    printf '[mb-migrator:error] Release checksum verification failed.\n' >&2
    exit 1
  }
else
  download "https://api.github.com/repos/$REPO/tarball/$REF" "$ARCHIVE"
fi

expected_prefix=""
[[ -z "$RELEASE_VERSION" ]] || expected_prefix="mb-migrator-$RELEASE_VERSION"
validate_archive "$ARCHIVE" "$expected_prefix"
tar --no-same-owner --no-same-permissions -xzf "$ARCHIVE" -C "$WORKDIR" --strip-components=1
if [[ -n "$RELEASE_VERSION" ]]; then
  manifest="$WORKDIR/RELEASE-MANIFEST"
  [[ -f "$manifest" && ! -L "$manifest" ]] || { printf '[mb-migrator:error] Release manifest is missing.\n' >&2; exit 1; }
  grep -Fxq 'format=mb-migrator-release-v1' "$manifest" \
    && grep -Fxq "version=$RELEASE_VERSION" "$manifest" \
    && grep -Fxq "revision=$EXPECTED_REVISION" "$manifest" || {
      printf '[mb-migrator:error] Release identity verification failed.\n' >&2
      exit 1
    }
fi
for executable in bin/mb-migrator bin/mb-live-migrate bin/mb-package bin/mb-push-migrate bin/mb-relay-migrate bin/mb-relay-doctor bin/mb-relay-verify bin/wp-export-migrate; do
  [[ -f "$WORKDIR/$executable" && ! -L "$WORKDIR/$executable" ]] || {
    printf '[mb-migrator:error] Downloaded archive has an unsafe executable layout.\n' >&2
    exit 1
  }
done
chmod +x "$WORKDIR/bin/mb-migrator" "$WORKDIR/bin/mb-live-migrate" "$WORKDIR/bin/mb-package" "$WORKDIR/bin/mb-push-migrate" "$WORKDIR/bin/mb-relay-migrate" "$WORKDIR/bin/mb-relay-doctor" "$WORKDIR/bin/mb-relay-verify" "$WORKDIR/bin/wp-export-migrate"
bash "$WORKDIR/bin/mb-migrator" "$@"
