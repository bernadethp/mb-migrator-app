#!/usr/bin/env bash
set -euo pipefail

role="${1:-}"
root="${2:-}"
expected_url="${3:-}"
expected_safety="${4:-ignored}"
rollback_dir="${5:-}"
source_url="${6:-}"
safety_sha256="${7:-}"

fail() {
  printf '[verification:error] %s\n' "$*" >&2
  exit 1
}

[[ "$role" == source || "$role" == destination ]] || fail "invalid verification role"
[[ "$root" =~ ^/[A-Za-z0-9._/-]+$ && -d "$root/wp-content" ]] || fail "invalid WordPress root"
command -v wp >/dev/null 2>&1 || fail "WP-CLI is unavailable"
command -v php >/dev/null 2>&1 || fail "PHP is unavailable"
command -v find >/dev/null 2>&1 || fail "find is unavailable"
command -v sort >/dev/null 2>&1 || fail "sort is unavailable"

if command -v sha256sum >/dev/null 2>&1; then
  hash_stream() { sha256sum | awk '{print $1}'; }
  hash_file() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
  hash_stream() { shasum -a 256 | awk '{print $1}'; }
  hash_file() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  fail "SHA-256 command is unavailable"
fi

wp_site() (
  cd "$root" || return 1
  wp --skip-plugins --skip-themes "$@"
)

wp_site core is-installed >/dev/null 2>&1 || fail "WordPress does not bootstrap"
home="$(wp_site option get home --quiet 2>/dev/null)" || fail "WordPress home is unavailable"
siteurl="$(wp_site option get siteurl --quiet 2>/dev/null)" || fail "WordPress siteurl is unavailable"
[[ "$home" =~ ^https?://[^[:space:]]+$ && "$siteurl" =~ ^https?://[^[:space:]]+$ ]] || fail "WordPress URLs are invalid"

content_json="$(wp_site post list \
  --post_type=post,page \
  --post_status=any \
  --fields=ID,post_type,post_status,post_name,post_title,post_content,post_excerpt,post_parent,menu_order \
  --orderby=ID --order=ASC --format=json 2>/dev/null)" || fail "content inventory is unavailable"
content_count="$(wp_site post list --post_type=post,page --post_status=any --format=count 2>/dev/null)" || fail "content count is unavailable"
[[ "$content_count" =~ ^[0-9]+$ ]] || fail "content count is invalid"
content_digest="$(printf '%s' "$content_json" | php -r '
  $rows = json_decode(stream_get_contents(STDIN), true, 512, JSON_THROW_ON_ERROR);
  $urls = array_values(array_filter(array_map(static fn ($url) => rtrim($url, "/"), array_slice($argv, 1))));
  $normalize = static function ($value) use (&$normalize, $urls) {
      if (is_array($value)) {
          foreach ($value as $key => $member) { $value[$key] = $normalize($member); }
          return $value;
      }
      return is_string($value) ? str_replace($urls, "__MB_SITE_URL__", $value) : $value;
  };
  echo hash("sha256", json_encode($normalize($rows), JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR));
' "$home" "$siteurl")"
[[ "$content_digest" =~ ^[a-f0-9]{64}$ ]] || fail "content digest is invalid"

uploads="$root/wp-content/uploads"
media_count=0
if [[ -d "$uploads" ]]; then
  media_count="$(find "$uploads" -type f -print0 | awk 'BEGIN { RS="\0" } NF { count++ } END { print count + 0 }')"
fi
media_digest="$({
  if [[ -d "$uploads" ]]; then
    while IFS= read -r -d '' file; do
      relative="${file#"$uploads"/}"
      printf '%s\0%s\0' "$relative" "$(hash_file "$file")"
    done < <(find "$uploads" -type f -print0 | LC_ALL=C sort -z)
  fi
} | hash_stream)"
[[ "$media_count" =~ ^[0-9]+$ && "$media_digest" =~ ^[a-f0-9]{64}$ ]] || fail "media inventory is invalid"

admin_count="$(wp_site user list --role=administrator --format=count 2>/dev/null)" || fail "administrator inventory is unavailable"
[[ "$admin_count" =~ ^[0-9]+$ ]] || fail "administrator count is invalid"

active_plugins="$(wp_site plugin list --status=active --field=name 2>/dev/null | LC_ALL=C sort)" || fail "active plugin inventory is unavailable"
active_plugins_count="$(printf '%s\n' "$active_plugins" | awk 'NF { count++ } END { print count + 0 }')"
active_plugins_digest="$(printf '%s' "$active_plugins" | hash_stream)"
active_theme="$(wp_site theme list --status=active --field=name 2>/dev/null | LC_ALL=C sort)" || fail "active theme inventory is unavailable"
active_theme_digest="$(printf '%s' "$active_theme" | hash_stream)"

safety_state=ignored
rollback_state=not_checked
old_url_matches=0
if [[ "$role" == destination ]]; then
  expected_url="${expected_url%/}"
  source_url="${source_url%/}"
  [[ "$expected_url" =~ ^https?://[^[:space:]]+$ ]] || fail "expected destination URL is invalid"
  [[ "$source_url" =~ ^https?://[^[:space:]]+$ ]] || fail "source URL is invalid"
  case "$expected_safety" in enabled|disabled) ;; *) fail "expected safety state is invalid" ;; esac
  guard="$root/wp-content/mu-plugins/mb-migrator-safety.php"
  if [[ -f "$guard" && ! -L "$guard" && -n "$safety_sha256" && "$(hash_file "$guard")" == "$safety_sha256" ]]; then
    safety_state=enabled
  elif [[ ! -e "$guard" && ! -L "$guard" ]]; then
    safety_state=disabled
  else
    safety_state=unknown
  fi

  if [[ -n "$rollback_dir" && "$rollback_dir" =~ ^/[A-Za-z0-9._/-]+$ && -d "$rollback_dir" && ! -L "$rollback_dir" \
    && -f "$rollback_dir/target-root" && ! -L "$rollback_dir/target-root" \
    && "$(<"$rollback_dir/target-root")" == "$(cd "$root" && pwd -P)" \
    && -f "$rollback_dir/added-files" && ! -L "$rollback_dir/added-files" \
    && ! -e "$rollback_dir/restored" ]]; then
    rollback_state=ready
  else
    rollback_state=unavailable
  fi

  if [[ "$source_url" != "$expected_url" ]]; then
    old_url_matches="$(wp_site search-replace "$source_url" "$expected_url" \
      --all-tables-with-prefix --skip-columns=guid --dry-run --precise --format=count 2>/dev/null)" || fail "serialized URL verification is unavailable"
    [[ "$old_url_matches" =~ ^[0-9]+$ ]] || fail "serialized URL verification is invalid"
  fi
fi

printf 'wordpress=installed\n'
printf 'home=%s\n' "$home"
printf 'siteurl=%s\n' "$siteurl"
printf 'content_count=%s\n' "$content_count"
printf 'content_sha256=%s\n' "$content_digest"
printf 'media_count=%s\n' "$media_count"
printf 'media_sha256=%s\n' "$media_digest"
printf 'administrator_count=%s\n' "$admin_count"
printf 'active_plugins_count=%s\n' "$active_plugins_count"
printf 'active_plugins_sha256=%s\n' "$active_plugins_digest"
printf 'active_theme_sha256=%s\n' "$active_theme_digest"
printf 'old_url_matches=%s\n' "$old_url_matches"
printf 'safety_state=%s\n' "$safety_state"
printf 'rollback_state=%s\n' "$rollback_state"
