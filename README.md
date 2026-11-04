# MB Migrator App Engine

`mb-migrator` restores WordPress provider exports into a MightyBox-style WordPress document root.

This is the independent command-line engine used by the MightyBox Assisted
Migration application. It is maintained separately from
`mightybox-io/mb-migrator`; its remote-run examples resolve only to this
repository and never default to a mutable branch.

Print the exact tool version with `mb-migrator --version`.

Before opening a pull request, run the same syntax, ShellCheck and seven-suite
smoke gate used by GitHub Actions:

```bash
./scripts/validate.sh
```

The command fails explicitly when a required local runtime is unavailable; a
missing tool is never reported as a passing or skipped check.

## Versioned and verified distribution

Supported releases use deterministic `mb-migrator-VERSION.tar.gz` archives, a
SHA-256 sidecar, an embedded version/revision manifest, and GitHub build
provenance. The tag workflow runs the complete validation gate before it builds,
verifies, attests and publishes assets. Do not create `v1.0.0` until the MightyBox
Milestone 14 security and live-acceptance gates authorize it.

Build the same bytes twice from one revision and verify them locally:

```bash
./scripts/build-release.sh dist-one
./scripts/build-release.sh dist-two
cmp dist-one/mb-migrator-0.1.0.tar.gz dist-two/mb-migrator-0.1.0.tar.gz
./scripts/verify-release.sh \
  dist-one/mb-migrator-0.1.0.tar.gz \
  dist-one/mb-migrator-0.1.0.tar.gz.sha256 \
  0.1.0 FULL_40_CHARACTER_RELEASE_COMMIT_SHA
```

After a supported release exists, remote execution requires both its semantic
version and exact release commit. It refuses a missing/malformed checksum,
modified archive, version mismatch or revision mismatch before running code:

```bash
MB_MIGRATOR_VERSION=1.0.0 \
MB_MIGRATOR_REVISION=FULL_40_CHARACTER_RELEASE_COMMIT_SHA \
bash -c "$(curl -fsSL https://raw.githubusercontent.com/bernadethp/mb-migrator-app/v1.0.0/remote-run.sh)" -- --version
```

The bootstrap also validates the downloaded tar metadata before extraction. It
rejects links, special files, traversal, multiple roots, duplicate or
case-colliding paths, more than 20,000 entries, and more than 512 MiB of
declared uncompressed content. Extraction does not restore archive ownership or
permissions, and every executable entry must be a regular file.

Operators can independently verify the published archive provenance with
`gh attestation verify mb-migrator-1.0.0.tar.gz --repo bernadethp/mb-migrator-app`.
Development execution is separate: `MB_MIGRATOR_REF` must be a full 40-character
commit SHA and the runner prints a prominent non-release warning.

It is built for migration work where a single provider export archive contains site files plus split SQL database dumps. The first supported provider adapter is GridPane-style SFTP exports. The project is intentionally modular so support for other providers can be added behind provider adapters.

It can also pull a single-site WordPress installation directly from a legacy MightyBox host over SSH. The live workflow is controlled entirely from the new host; the legacy host does not need a copy of this repository.

## Portable WordPress Packages

The portable package workflow works with any source and destination hosts where you can run shell commands. The hosts do not need direct network connectivity:

1. Run `export-site` on the old host.
2. Transfer the package and its checksum manually.
3. Run `import-site` on the new host.

The commands can be run without cloning this repository.

On the old host, create the package:

```bash
MB_MIGRATOR_REF=4fc933afe55c49a9a3b8914a2e70fc0f18cac137 bash -c "$(curl -fsSL https://raw.githubusercontent.com/bernadethp/mb-migrator-app/4fc933afe55c49a9a3b8914a2e70fc0f18cac137/remote-run.sh)" -- \
  export-site \
  --source-root=/path/to/wordpress \
  --output="$HOME/wordpress-package.tar.gz"
```

Database export defaults to `auto`, which tries WP-CLI first and then native `mariadb-dump`/`mysqldump` using credentials resolved from `wp-config.php`. Force a method when troubleshooting:

```bash
--db-method=wp-cli
--db-method=native
```

When a MySQL `mysqldump` client connects to a MariaDB server, the migrator detects client support for column statistics and adds `--column-statistics=0`. This avoids failures caused by MariaDB not providing MySQL's `information_schema.COLUMN_STATISTICS` table.

The export produces:

```text
wordpress-package.tar.gz
wordpress-package.tar.gz.sha256
```

Transfer both files using `scp`, SFTP, your laptop, or any other approved method. For example, from a workstation that can reach both hosts:

```bash
scp -P 3022 user@old-host:~/wordpress-package.tar.gz* .
scp wordpress-package.tar.gz* user@new-host:~/
```

On the new host, verify and import the package:

```bash
MB_MIGRATOR_REF=4fc933afe55c49a9a3b8914a2e70fc0f18cac137 bash -c "$(curl -fsSL https://raw.githubusercontent.com/bernadethp/mb-migrator-app/4fc933afe55c49a9a3b8914a2e70fc0f18cac137/remote-run.sh)" -- \
  import-site "$HOME/wordpress-package.tar.gz" \
  --target-root=/srv/htdocs \
  --new-url=https://new.example.com
```

`import-site` verifies the checksum when the sidecar is present, reads the old URL from the package manifest when it was detectable, and then uses the normal guarded restore pipeline. If export could not detect the source URL, pass `--old-url` together with `--new-url`. Import prompts for database import, `mu-plugins`, root extras, and cleanup unless explicit policies are supplied.

For an unattended import:

```bash
MB_MIGRATOR_REF=4fc933afe55c49a9a3b8914a2e70fc0f18cac137 bash -c "$(curl -fsSL https://raw.githubusercontent.com/bernadethp/mb-migrator-app/4fc933afe55c49a9a3b8914a2e70fc0f18cac137/remote-run.sh)" -- \
  import-site "$HOME/wordpress-package.tar.gz" \
  --target-root=/srv/htdocs \
  --new-url=https://new.example.com \
  --target-db-method=auto \
  --mu-plugins=skip \
  --root-extras=copy \
  --db-import=yes \
  --cleanup=no \
  --yes
```

Portable packages contain the database, `wp-content`, non-core root-file candidates, and source URL metadata. They exclude WordPress core and `wp-config.php`. Package files use mode `0600`, and temporary work directories use mode `0700`. The source host needs temporary free space for an extracted copy of the selected site files plus the final compressed package.

While collecting site files, the exporter reports the compressed archive size and elapsed time every five seconds, followed by a final size and duration. This is activity progress rather than a percentage because compression ratios vary across site content. Set `MB_MIGRATOR_PROGRESS_INTERVAL` to a positive number of seconds to change the reporting interval.

On a live site, GNU tar may report that the `wp-content` directory changed while it was being traversed. The exporter accepts a valid archive when that is the only warning and reports that the live snapshot may not include entries created during collection. Changed file contents, unreadable files, invalid archives, and all other tar failures remain fatal.

## Outbound SSH Push Migration

Use the outbound push workflow when the old host cannot accept inbound SSH but can connect outward to the new host. Pairing is prepared on the old host before the destination username exists. The private key never leaves the old host; install only the generated public key on the new SSH account.

For the normal guided migration, run this single command on the old host:

```bash
MB_MIGRATOR_REF=4fc933afe55c49a9a3b8914a2e70fc0f18cac137 bash -c "$(curl -fsSL https://raw.githubusercontent.com/bernadethp/mb-migrator-app/4fc933afe55c49a9a3b8914a2e70fc0f18cac137/remote-run.sh)" -- push
```

The wizard:

1. Creates a private migration key on the old host and prints only its public key.
2. Pauses while you create or open the destination SSH account and install the public key.
3. Waits for you to press Enter, then asks for the destination `USER@HOST` and SSH port.
4. Verifies and saves the pairing without asking you to copy a pairing ID.
5. Uses `/var/www/webroot/ROOT` as the source when it exists, discovers the destination WordPress root and URL, and begins the migration.

You may supply known values up front while keeping the guided pause:

```bash
MB_MIGRATOR_REF=4fc933afe55c49a9a3b8914a2e70fc0f18cac137 bash -c "$(curl -fsSL https://raw.githubusercontent.com/bernadethp/mb-migrator-app/4fc933afe55c49a9a3b8914a2e70fc0f18cac137/remote-run.sh)" -- \
  push \
  --destination=USER@NEW-HOST \
  --port=22 \
  --source-root=/var/www/webroot/ROOT \
  --source-db-method=auto \
  --target-db-method=auto
```

For a GridPane source, pass the site's `htdocs` directory. The migrator detects
GridPane's standard parent-level `wp-config.php` without copying that file into
the migration package:

```bash
MB_MIGRATOR_REF=4fc933afe55c49a9a3b8914a2e70fc0f18cac137 bash -c "$(curl -fsSL https://raw.githubusercontent.com/bernadethp/mb-migrator-app/4fc933afe55c49a9a3b8914a2e70fc0f18cac137/remote-run.sh)" -- \
  push \
  --source-root=/var/www/example.com/htdocs \
  --destination=USER@NEW-HOST \
  --port=22
```

An in-document-root `wp-config.php` takes precedence when both locations exist.
The parent fallback is used only when the source directory itself is named
`htdocs`.

If the destination SSH gateway requires a password after public-key
authentication, load it without placing it in shell history and clear it after
the run:

```bash
read -r -s -p "Destination SSH password: " MB_MIGRATOR_DESTINATION_PASSWORD
printf '\n'
export MB_MIGRATOR_DESTINATION_PASSWORD

mb-migrator push --source-root=/var/www/example.com/htdocs

unset MB_MIGRATOR_DESTINATION_PASSWORD
```

The password remains in the source process environment only. It is not written
to migration state, reports, command arguments, or the destination.

The first connection records a previously unseen destination SSH host key using OpenSSH's `accept-new` policy. On older clients that lack `accept-new`, the migrator retrieves and displays the new key fingerprint before storing it, then connects with strict verification. Previously recorded keys must still match, so changed host keys are rejected.

`push-site` detects `/srv/htdocs` on the destination, falling back to the destination account's `~/htdocs` when needed. Pass `--target-root` only to override discovery. It runs destination commands through a login shell so hosting-platform PATH and environment setup is available. From inside the detected root it runs `wp option get siteurl`, falling back to `wp option get home`, and uses that value as the new URL for serialized-safe search-replace; pass `--new-url` only to override it.

When `rsync` is available on both hosts, `push-site` transfers files directly into a private staging directory on the destination. The rsync staging cache is stable for the saved pairing, so retries and catch-up runs compare against the prior transfer and send only missing or changed files. Files already identical to the destination are hard-linked into the cache where supported, reducing additional disk use. The cache is retained automatically unless `--cleanup=yes` is explicitly requested. A reused cache first gets a short incremental refresh; if substantial work causes that long-lived session to fail, WordPress content automatically switches to small, independently committed batches so only the active batch reconnects. Set `RSYNC_BATCH_SIZE` between 25 and 5000 to override the default of 250 files. After a batched initial transfer, one short comparison pass catches live changes without repeatedly authenticating for every batch. Prior `wordpress-package-*.tar.gz` archives and checksum files in the source web root are excluded automatically. The migrator displays concise batch/byte progress when supported, then streams a fresh database dump over SSH. SSH keepalives are enabled, interrupted rsync operations reconnect up to four times while retaining partial files, metadata transfers reconnect up to three times, and an interrupted database stream restarts safely through a temporary destination file. Before file transfer, the source content size and destination free space are displayed when available. Persistent failures identify whether to inspect SSH stability, destination disk space, quota, or the source database. The staged files go through the same guarded importer used by portable packages; this preserves prompts, managed-plugin exclusions, database backup/import, and serialized-safe URL replacement. It never uses rsync `--delete`, so source deletions are not propagated to the destination.

After a successful URL replacement, the importer flushes the WordPress object cache. The outbound workflow then verifies that WordPress is installed, reports the resulting home URL, and performs a non-fatal HTTP check when `curl` is available. Set `MB_MIGRATOR_SKIP_HTTP_VERIFY=1` only when the destination is intentionally not publicly reachable.

If either host lacks `rsync`, automatic mode falls back to building and transferring the portable tar package. Use `--transport=rsync` to require direct transfer or `--transport=package` to force the older package workflow:

```bash
MB_MIGRATOR_REF=4fc933afe55c49a9a3b8914a2e70fc0f18cac137 bash -c "$(curl -fsSL https://raw.githubusercontent.com/bernadethp/mb-migrator-app/4fc933afe55c49a9a3b8914a2e70fc0f18cac137/remote-run.sh)" -- \
  push-site \
  --transport=rsync \
  --source-db-method=auto \
  --target-db-method=auto
```

Successful runs remove temporary transfer data when destination cleanup is accepted. When destination cleanup is declined, its staging directory and report remain available. When an import fails, the private incoming directory is retained and its remote path is printed for recovery.

Pairing state is private and persists under `~/.local/state/mb-migrator/push-pairings` by default. A successfully completed pairing becomes the current pairing, so later `push-site` catch-up runs do not require its ID. Pass `--pairing=PAIRING_ID` only to select a different saved pairing. Use `--state-dir` consistently when a different state location is required. Force native source export with `--source-db-method=native` when source WP-CLI is unavailable.

For scripting, troubleshooting, or resuming one particular phase, the original low-level commands remain available:

```bash
mb-migrator push-pair prepare
mb-migrator push-pair complete PAIRING_ID USER@NEW-HOST --port=22
mb-migrator push-site --pairing=PAIRING_ID --source-root=/var/www/webroot/ROOT
```

Running `mb-migrator push-pair` without `prepare` or `complete` is also an alias for the guided `push` flow.
If the wizard is interrupted before SSH verification, rerunning `push` resumes
the pending key instead of generating a replacement.
If pairing succeeded but the migration was interrupted, rerunning `push`
continues with that verified pairing. Pass `--new-pairing` only when you
intentionally want to connect a different destination account.

## Live Legacy MightyBox Migration

Legacy sites are expected at `/var/www/webroot/ROOT` by default. Run the migrator from the new host as the user that can write the destination WordPress root.

### One-Line Remote Use

The repository does not need to be cloned onto the new host. Each command downloads a temporary copy of the migrator, while SSH keys, migration state, and retained snapshots remain in the new host user's private state directory.

Pair the new host with the legacy host:

```bash
MB_MIGRATOR_REF=4fc933afe55c49a9a3b8914a2e70fc0f18cac137 bash -c "$(curl -fsSL https://raw.githubusercontent.com/bernadethp/mb-migrator-app/4fc933afe55c49a9a3b8914a2e70fc0f18cac137/remote-run.sh)" -- \
  pair user@legacy-host
```

Preflight both hosts:

```bash
MB_MIGRATOR_REF=4fc933afe55c49a9a3b8914a2e70fc0f18cac137 bash -c "$(curl -fsSL https://raw.githubusercontent.com/bernadethp/mb-migrator-app/4fc933afe55c49a9a3b8914a2e70fc0f18cac137/remote-run.sh)" -- \
  doctor \
  --source=user@legacy-host \
  --source-root=/var/www/webroot/ROOT \
  --target-root=/srv/htdocs
```

Run the migration:

```bash
MB_MIGRATOR_REF=4fc933afe55c49a9a3b8914a2e70fc0f18cac137 bash -c "$(curl -fsSL https://raw.githubusercontent.com/bernadethp/mb-migrator-app/4fc933afe55c49a9a3b8914a2e70fc0f18cac137/remote-run.sh)" -- \
  pull user@legacy-host \
  --source-root=/var/www/webroot/ROOT \
  --target-root=/srv/htdocs \
  --new-url=https://new.example.com
```

Run the same migration again as a catch-up before cutover:

```bash
MB_MIGRATOR_REF=4fc933afe55c49a9a3b8914a2e70fc0f18cac137 bash -c "$(curl -fsSL https://raw.githubusercontent.com/bernadethp/mb-migrator-app/4fc933afe55c49a9a3b8914a2e70fc0f18cac137/remote-run.sh)" -- \
  pull user@legacy-host \
  --source-root=/var/www/webroot/ROOT \
  --target-root=/srv/htdocs \
  --continue-existing
```

Development remote execution requires `MB_MIGRATOR_REF` to be an immutable full
40-character commit SHA. Branches, tags and abbreviated revisions are refused.

Pair the hosts first:

```bash
./bin/mb-migrator pair user@legacy-host
```

The command creates a dedicated Ed25519 key and attempts to install it with `ssh-copy-id`. If password-based installation is unavailable, it prints a public-key command to run from an authorized SSH session on the legacy host. Existing keys can be used with `--identity-file`.

Preflight both hosts without transferring the site:

```bash
./bin/mb-migrator doctor \
  --source=user@legacy-host \
  --source-root=/var/www/webroot/ROOT \
  --target-root=/srv/htdocs
```

Pull and restore the site:

```bash
./bin/mb-migrator pull user@legacy-host \
  --source-root=/var/www/webroot/ROOT \
  --target-root=/srv/htdocs \
  --old-url=https://legacy.example.com \
  --new-url=https://example.com \
  --db-import=yes \
  --yes
```

When `--new-url` is supplied without `--old-url`, the migrator tries to read the source home URL with WP-CLI and then with a native database query. Serialized-safe URL replacement runs on the new host. If WP-CLI is unavailable there, migration completes with a prominent “URL rewrite pending” warning and the follow-up command is written to the report.

### Catch-up Runs

Migration state is identified by source host, SSH port, source root, and target root. Repeating the same pull interactively prompts to continue the existing migration, restart it, or cancel. For unattended operation, choose explicitly:

```bash
./bin/mb-migrator pull user@legacy-host \
  --target-root=/srv/htdocs \
  --continue-existing \
  --db-import=yes \
  --yes
```

A catch-up always takes a fresh full database dump. When `rsync` exists on both hosts, only new and changed files cross SSH. Otherwise, the migrator automatically retransfers a complete tar snapshot. Source deletions are never propagated to the destination.

Detected or supplied old/new URLs are saved in the private migration state and automatically reused during catch-up, so importing the fresh database does not undo the destination URL rewrite.

An outbound push is marked complete only after the destination can bootstrap
WordPress with WP-CLI and returns a valid HTTP(S) home URL. If that required
verification fails, the command exits non-zero and retains the transferred
private migration data for diagnosis and retry. The optional public HTTP check
remains advisory because a destination may intentionally be private before
cutover.

Use `--restart` to delete only the matching migration state and begin again. In an interactive session the exact state path is shown before restart. `--yes` by itself never selects this destructive action.

### Database Fallback

Source export and target backup/import support:

```text
--source-db-method=auto|wp-cli|native
--target-db-method=auto|wp-cli|native
```

`auto` tries WP-CLI first and falls back to `mariadb-dump`/`mysqldump` or `mariadb`/`mysql`. Native mode resolves `DB_NAME`, `DB_USER`, `DB_PASSWORD`, and `DB_HOST` without bootstrapping WordPress. It supports quoted literals and simple `getenv('NAME')` expressions in `wp-config.php`, plus exact-name environment variables such as those injected by a hosting platform. Host ports and Unix sockets are supported. Unsupported dynamic expressions fail preflight with the unresolved setting named.

Credentials are written only to temporary mode-`0600` client files and are never placed in process arguments, reports, snapshots, or saved migration state. The live snapshot also excludes `wp-config.php`.

### State and Consistency

Private state defaults to `$XDG_STATE_HOME/mb-migrator` or `$HOME/.local/state/mb-migrator`. State directories use mode `0700`; keys, dumps, manifests, and snapshots use mode `0600`. Successful snapshots are retained by default for retry and audit. Pass `--snapshot=delete` to remove the snapshot after a successful restore.

Version one supports WordPress single-site installations. Multisite is rejected during preflight. A live site can change while files and database are collected, so the recommended cutover is an initial pull followed by a catch-up immediately before DNS or proxy cutover, after pausing content changes when possible.

## One-Line Remote Run

Run without installing the repo first:

```bash
MB_MIGRATOR_REF=4fc933afe55c49a9a3b8914a2e70fc0f18cac137 bash -c "$(curl -fsSL https://raw.githubusercontent.com/bernadethp/mb-migrator-app/4fc933afe55c49a9a3b8914a2e70fc0f18cac137/remote-run.sh)" -- restore /path/to/export.tar.gz --target-root=/srv/htdocs --dry-run
```

The remote runner downloads the repo into a temporary directory, runs `bin/mb-migrator`, then removes the temporary directory when it exits.

Use an exact development commit by setting `MB_MIGRATOR_REF`:

```bash
MB_MIGRATOR_REF=4fc933afe55c49a9a3b8914a2e70fc0f18cac137 bash -c "$(curl -fsSL https://raw.githubusercontent.com/bernadethp/mb-migrator-app/4fc933afe55c49a9a3b8914a2e70fc0f18cac137/remote-run.sh)" -- restore /path/to/export.tar.gz --target-root=/srv/htdocs --dry-run
```

## Local Usage

```bash
./bin/mb-migrator --help
```

Run a preflight check from the SSH shell before restoring:

```bash
./bin/mb-migrator doctor \
  --target-root=/srv/htdocs \
  --archive=/path/to/export.tar.gz
```

Dry run first:

```bash
./bin/mb-migrator restore /path/to/export.tar.gz \
  --target-root=/srv/htdocs \
  --dry-run
```

Restore files and build the combined SQL file:

```bash
./bin/mb-migrator restore /path/to/export.tar.gz \
  --target-root=/srv/htdocs
```

Restore, automatically import the DB, and run serialized-safe search-replace:

```bash
./bin/mb-migrator restore /path/to/export.tar.gz \
  --target-root=/srv/htdocs \
  --old-url=https://old.example.com \
  --new-url=https://new.example.com \
  --db-import=yes \
  --search-replace
```

The old command name still works for compatibility:

```bash
./bin/wp-export-migrate --help
```

## What It Does

For GridPane-style exports, `mb-migrator` will:

- Detect the provider layout from the archive contents.
- Extract selected paths into a timestamped staging directory.
- Merge `wp-content/plugins`, `wp-content/themes`, and `wp-content/uploads` into the target site.
- Preserve existing destination symlinks by default, which avoids replacing platform-managed plugin/theme symlinks.
- Detect and copy root-level Virusdie connector files such as `vdconnect-*.php` automatically.
- Detect other non-core root files and ask one-by-one before copying them by default.
- Detect `wp-content/mu-plugins` and ask separately before copying because `mu-plugins` are often platform-specific.
- Combine split SQL database files into one importable SQL file.
- Generate `wp-config.php` reports and diffs without changing the target config by default.
- Optionally import the combined SQL with WP-CLI.
- Optionally run serialized-safe WP-CLI search-replace.
- Write a migration report into the staging directory.

## Supported Provider Layouts

### GridPane

Expected archive shape:

```text
database-*/
htdocs/wp-content/plugins/
htdocs/wp-content/themes/
htdocs/wp-content/uploads/
site-name-archived-assets/wp-config.php
site-name-archived-assets/user-configs.php
```

The database directory may contain many `*-schema.sql` and table data `.sql` files, such as mydumper-style exports.

Some GridPane exports may include `htdocs/wp-config.php`; when both locations exist, `htdocs/wp-config.php` is preferred. Otherwise, `*-archived-assets/wp-config.php` is used for config reporting and optional migration.

## SQL Combining Rules

The combined SQL file is suitable for phpMyAdmin or `wp db import`:

- All `*-schema.sql` files are written first.
- A `DROP TABLE IF EXISTS` statement is inserted before every `CREATE TABLE` statement.
- All non-schema data `.sql` files are appended after schemas.
- `CREATE DATABASE` statements are removed.
- `USE database_name` statements are removed.
- Source `FOREIGN_KEY_CHECKS` statements are removed.
- Source-account `DEFINER=user@host` clauses are removed from views, routines, triggers, and events so imports do not require destination `SET USER` privileges. `SQL SECURITY DEFINER` behavior is preserved.
- One `FOREIGN_KEY_CHECKS=0` statement is written at the top.
- One `FOREIGN_KEY_CHECKS=1` statement is written at the end.
- `SET time_zone = '+00:00';` is written using normal quoted SQL syntax.

The verifier fails the run if:

- `DROP TABLE IF EXISTS` count does not match `CREATE TABLE` count.
- Any `CREATE DATABASE` statement remains.
- Any `USE` statement remains.
- Foreign key checks are not disabled/enabled exactly once.
- Any source `DEFINER=` clause remains.
- An unquoted `TIME_ZONE=+00:00` style statement remains.

## Progress Labels

Console messages use workflow and phase labels instead of a generic importer prefix. Examples include `[push:connect]`, `[push:files]`, `[push:database]`, `[restore:inspect]`, and `[restore:cleanup]`. Warnings, errors, and prompts keep the active phase, such as `[restore:database:error]`, so failures identify where they occurred.

## File Restore Behavior

### wp-content

The importer merges these directories by default:

```text
wp-content/plugins
wp-content/themes
wp-content/uploads
```

It does not delete destination files. Existing destination symlinks are preserved unless `--replace-managed-symlinks` is passed. Copied web directories are normalized to mode `755` and copied web files to `644`, preventing the migrator's private staging umask from making restored assets unreadable by the web server.

Absolute symlinks that point back into the source site's own `wp-content` are converted to destination hard links when the corresponding media exists. This supports generated BuddyBoss previews on nginx hosts without duplicating the underlying file data. Links whose source media is missing remain staged and are reported.

The importer also skips platform-managed cache/server-helper plugins during plugin merges. These should be managed by the target platform rather than copied from the source export.

Skipped plugin slugs include:

```text
nginx-helper
redis-cache
redis-object-cache
redis-cache-pro
gridpane-redis-object-cache
wp-redis
wp-redis-cache
object-cache-pro
*redis*object*cache*
```

### Virusdie Connector Files

Root-level Virusdie files are copied automatically when detected.

Detected patterns include:

```text
vdconnect-*.php
*virusdie*
*virus-die*
*virus_die*
```

### Other Root Files

Non-core files in `htdocs/` are treated as root extras.

Examples might include:

```text
sitemap.xml
robots.txt
google*.html
custom-verification-file.html
```

Default behavior is one-by-one prompting:

```bash
--root-extras=ask
```

For automation:

```bash
--root-extras=copy
--root-extras=skip
```

### mu-plugins

`wp-content/mu-plugins` is handled separately because it can contain provider/platform-specific code.

Default behavior:

```bash
--mu-plugins=ask
```

Automation options:

```bash
--mu-plugins=copy
--mu-plugins=skip
```

Compatibility alias:

```bash
--include-mu-plugins
```

That is equivalent to:

```bash
--mu-plugins=copy
```

## wp-config.php Handling

By default, the target `wp-config.php` is not changed.

The importer writes these files into the staging directory:

```text
wp-config.diff
wp-config-extra-from-export.txt
user-configs.diff
user-configs-extra-from-export.txt
```

For GridPane exports, config files are usually extracted from the `*-archived-assets` folder:

```text
*-archived-assets/wp-config.php
*-archived-assets/user-configs.php
```

To replace the target config files with the exported config files, pass:

```bash
--migrate-config
```

The existing target config file is backed up first, and each replacement requires confirmation unless `--yes` is also passed.

## Database Import

By default, the importer asks whether to import the generated SQL into the database configured by the target `wp-config.php`. The default answer is yes:

```bash
--db-import=ask
```

For unattended imports:

```bash
--db-import=yes
```

To build the combined SQL but skip import:

```bash
--db-import=no
```

Compatibility aliases:

- `--import-db` means `--db-import=yes`.
- `--no-import-db` means `--db-import=no`.

Before import, the current DB is exported with:

```bash
wp db export
```

Skip that backup only when you already have a current DB backup:

```bash
--skip-db-backup
```

By default, the importer asks whether to clean up migration artifacts after a successful run:

```bash
--cleanup=ask
```

The cleanup prompt explicitly lists the paths that will be deleted, typically:

- The source export archive.
- The staging directory, including extracted files and generated artifacts.
- The combined SQL file when it lives outside the staging directory.

A copy of the migration report is preserved in the target root before deleting the staging directory.

For unattended cleanup:

```bash
--cleanup=yes
```

To leave all migration artifacts in place:

```bash
--cleanup=no
```

Legacy cleanup flags are still accepted as aliases for `--cleanup=yes`:

- `--delete-sql-after-import`
- `--delete-stage-after-success`
- `--delete-archive-after-success`

## Search-Replace

Run serialized-safe URL replacement after import:

```bash
--old-url=https://old.example.com \
--new-url=https://new.example.com \
--search-replace
```

The command used is:

```bash
wp search-replace OLD NEW --all-tables-with-prefix --precise --recurse-objects --skip-columns=guid
```

In `--dry-run` mode, WP-CLI search-replace is also run with `--dry-run`.

## Options

```text
--provider=auto|gridpane|legacy-mightybox|wordpress-package|wpengine
                                  Export provider adapter to use. Default: auto
--target-root=PATH                WordPress document root to restore into
--stage-dir=PATH                  Private staging directory. Default: user state/mb-migrator/staging
--db-output=PATH                  Combined SQL output path. Default: stage/<archive>-combined-phpmyadmin-import.sql
--old-url=URL                     Old URL for WP-CLI search-replace
--new-url=URL                     New URL for WP-CLI search-replace
--dry-run                         Print planned file/DB actions without changing destination files
--yes                             Answer yes to confirmation prompts
--mu-plugins=ask|copy|skip        What to do with exported mu-plugins. Default: ask
--include-mu-plugins              Alias for --mu-plugins=copy
--root-extras=ask|copy|skip       What to do with non-core root files. Default: ask
--replace-managed-symlinks        Replace destination symlink conflicts instead of preserving them
--db-import=ask|yes|no            Import combined SQL with wp db import. Default: ask, default answer yes
--target-db-method=auto|wp-cli|native
                                  Target database method. Default: auto
--import-db                       Alias for --db-import=yes
--no-import-db                    Alias for --db-import=no
--skip-db-backup                  Do not run wp db export before database import
--cleanup=ask|yes|no              Delete migration artifacts after success. Default: ask
--delete-sql-after-import         Legacy alias for --cleanup=yes
--delete-stage-after-success      Legacy alias for --cleanup=yes
--delete-archive-after-success    Legacy alias for --cleanup=yes
--search-replace                  Run wp search-replace after DB import or against current DB
--migrate-config                  After confirmation, replace target wp-config.php with exported wp-config.php
--help                            Show help
```

Archive restores use a private staging directory under
`${MB_MIGRATOR_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/mb-migrator}/staging`
unless `--stage-dir` is supplied explicitly. The directory is mode `0700`, and
reports and prepared SQL inherit the command's restrictive `umask 077`; do not
place an explicit staging directory inside a public document root.

Before extracting a tar archive, the migrator rejects traversal, duplicate or
case-colliding paths, unsupported special files, and unsafe links. It also
limits archives to 500,000 entries and 1 TiB of declared uncompressed content
by default. Operators can lower these ceilings with
`MB_MIGRATOR_MAX_ARCHIVE_ENTRIES` and `MB_MIGRATOR_MAX_ARCHIVE_BYTES`.

## Requirements

Required for basic restore:

- Bash
- `tar`
- `perl`
- `rsync`
- `awk`

Required for database backup/import:

- WP-CLI, available as `wp`, or PHP CLI plus native MariaDB/MySQL dump and client commands.

WP-CLI is specifically required for serialized-safe search-replace. If it is unavailable, the database migration succeeds and the rewrite is reported as pending.

Required on a legacy live source:

- Bash and `tar`.
- WP-CLI or PHP CLI plus `mariadb-dump`/`mysqldump`.
- `rsync` is optional; without it, catch-ups use full tar transfer.

Required for one-line remote use:

- `curl` or `wget`

## Gateway/Proxy SSH Hosts

Many MightyBox SSH sessions land on a gateway/proxy host rather than directly on the webserver container. That is supported as long as the SSH shell can access the same mounted site files and run the needed tools.

MightyBox/WP Cloud sites may also use a shared/symlinked core layout where `/srv/htdocs` contains files such as:

```text
__wp__
wp-config.php
wp-content/
wp-load.php
```

That is expected. The migrator targets `/srv/htdocs` for site files and does not require local `wp-admin` or `wp-includes` directories in the document root.
Destination WP-CLI commands are launched from inside the target root rather than with `--path`; this supports hosting wrappers that resolve a shared WordPress core from the shell's working directory.

Before a restore, run:

```bash
MB_MIGRATOR_REF=4fc933afe55c49a9a3b8914a2e70fc0f18cac137 bash -c "$(curl -fsSL https://raw.githubusercontent.com/bernadethp/mb-migrator-app/4fc933afe55c49a9a3b8914a2e70fc0f18cac137/remote-run.sh)" -- doctor \
  --target-root=/srv/htdocs \
  --archive=/path/to/export.tar.gz
```

The doctor command checks:

- The archive is readable from the SSH shell.
- The target root exists from the SSH shell.
- `wp-content` and `wp-config.php` are visible when present.
- Shared/symlinked core markers such as `__wp__` and `wp-load.php` are visible when present.
- The target root appears writable by the current user.
- Required shell tools are available.
- WP-CLI or the native database fallback is available when DB import will be used.
- Missing WP-CLI is reported as a pending rewrite when search-replace is requested.
- WP-CLI site installation checks are skipped because the database may not be imported yet.
- Disk-space information can be read when the platform exposes it.

The one-line runner downloads itself into a temporary directory. If `/tmp` is not usable on a gateway host, set `MB_MIGRATOR_TMPDIR` to a writable location:

```bash
MB_MIGRATOR_TMPDIR=/srv/htdocs MB_MIGRATOR_REF=4fc933afe55c49a9a3b8914a2e70fc0f18cac137 bash -c "$(curl -fsSL https://raw.githubusercontent.com/bernadethp/mb-migrator-app/4fc933afe55c49a9a3b8914a2e70fc0f18cac137/remote-run.sh)" -- doctor \
  --target-root=/srv/htdocs \
  --archive=/path/to/export.tar.gz
```

## Smoke Test

Run the included smoke test:

```bash
./tests/smoke.sh
./tests/live-smoke.sh
./tests/native-db-smoke.sh
./tests/package-smoke.sh
./tests/push-smoke.sh
```

The tests cover GridPane restore compatibility, live legacy pull and catch-up behavior, portable package export/import, outbound SSH push pairing and orchestration, snapshot security, SQL normalization, and native target database backup/import.

Keep generated smoke artifacts for debugging:

```bash
KEEP_SMOKE_ARTIFACTS=1 ./tests/smoke.sh
```

## Provider Adapters

Provider-specific logic lives in `providers/`.

Current adapters:

- `gridpane.sh`
- `legacy-mightybox.sh`
- `wordpress-package.sh`

Future adapters should follow the same shape:

- Detect layout from `.archive-index.txt`.
- Load provider-specific archive path globals.
- Extract only required paths into staging.
- Leave shared DB, wp-content, wp-config, WP-CLI, and verification behavior in `lib/`.

Potential future adapters:

- Kinsta
- WP Engine
- Cloudways
- cPanel
- Generic WordPress archive

## License

MIT. See `LICENSE`.

## WP Engine backup ZIPs

`restore` auto-detects a WP Engine backup containing `wp-content/mysql.sql`,
including a backup wrapped in one site directory. PHP 8.0 or newer with the
`zip` extension is required only for ZIP import. No Python dependency is added.
The layout follows [WP Engine's backup documentation](https://wpengine.com/support/restore/).

```bash
mb-migrator restore /path/to/site-backup.zip \
  --target-root=/srv/htdocs \
  --old-url=https://old.example.com --new-url=https://new.example.com \
  --search-replace --safety=enable
```

The adapter imports the database, plugins, themes, uploads, selected custom MU
plugins, and approved root files. It excludes WordPress core, source config,
cache drop-ins, server configuration, and known WPE MU plugins. URL replacement
uses the existing serialized-safe WP-CLI path. ZIP imports require explicit
`--old-url` when rewriting URLs. Archives with traversal paths, duplicate entries,
links, special files, or ambiguous database locations are rejected.

## Relay through an intermediary

When the hosts cannot connect to each other, run this on a workstation that can
SSH to both. Set up trusted SSH host keys through normal SSH first. Both servers
and the intermediary need rsync. SSH uses local keys or your existing agent; it
does not copy private keys or agent access to either host.

Run the non-mutating compatibility preflight before transferring content. App
orchestrators should pass dedicated known-hosts files and consume the single JSON
result instead of parsing terminal prose:

```bash
mb-migrator relay-doctor user@source.example.com \
  --destination=user@destination.example.com \
  --source-root=/sites/example \
  --target-root=/srv/htdocs \
  --source-identity=/private/source-key \
  --destination-identity=/private/destination-key \
  --source-known-hosts=/private/source-known-hosts \
  --destination-known-hosts=/private/destination-known-hosts \
  --json
```

The preflight checks SSH access, source WordPress/database export capability,
multisite exclusion, destination root/tool/write readiness and destination free
space. It also requires a conservative new-install destination baseline: no
uploaded files, no additional users, and no more than the standard sample and
privacy content. A modified destination is blocked instead of merged. The
preflight does not collect files, export the database or mutate either site.
Use the same identity and known-hosts options for the subsequent `relay` run.

```bash
mb-migrator relay user@source.example.com \
  --source-root=/sites/example \
  --source-identity=/path/to/source-key \
  --destination=user@destination.example.com \
  --destination-identity=/path/to/destination-key \
  --target-root=/srv/htdocs \
  --new-url=https://new.example.com \
  --db-import=yes --mu-plugins=copy --root-extras=copy --safety=enable --yes
```

Command completion is not verified migration completion. Before presenting a
destination for review, run the independent receipt check with the same pinned
SSH identities and known-hosts files:

```bash
mb-migrator relay-verify user@source.example.com \
  --destination=user@destination.example.com \
  --source-root=/sites/example \
  --target-root=/srv/htdocs \
  --run-id=019a4dc8-d9ff-73f2-8e98-2e6905994c10 \
  --expected-url=https://new.example.com \
  --expected-safety=enabled \
  --source-identity=/private/source-key \
  --destination-identity=/private/destination-key \
  --source-known-hosts=/private/source-known-hosts \
  --destination-known-hosts=/private/destination-known-hosts \
  --json
```

The command returns non-zero unless WordPress bootstraps, home and siteurl match,
normalized post/page content and the complete uploads manifest match their source
SHA-256 digests, active plugin/theme state matches, an administrator account
exists, serialized old-URL matches are zero, public HTTPS succeeds, the exact
migration safety state matches, and the current rollback point is ready. The JSON
receipt contains only the run identity, booleans, counts, digests, the tool
version and a timestamp;
it never includes content, database rows, credentials, private paths or raw SSH
output. Administrator presence is not proof that a particular customer password
works, so the application still requires a real WordPress Admin login during
customer review.

Rerun the same command for catch-up. Each run exports a fresh full database.
Each successful import also records a new private rollback point as current; a
failed export or import cannot replace that marker with stale rollback evidence.
Persistent private caches on the workstation and destination allow rsync to send
only changed file content, comparing checksums rather than only timestamps.
The destination cache is compared with the workstation cache before import;
verification failure stops the import. Source deletions are not propagated.
Relative safe symlinks are transferred; unsafe absolute links are skipped by the
relay transport. Use a portable archive if such links need legacy conversion.

Allow enough local disk space for the selected files plus the database. State
is stored under `~/.local/state/mb-migrator/relay` (or XDG_STATE_HOME); use
`--state-dir` to choose another volume. Destination state lives under its account's
`~/.local/state/mb-migrator/relay`. Caches contain private site data and remain
after success or failure. Remove them after verification and cutover. A lock
prevents concurrent runs against the same local cache; remove a stale lock only
after checking that its migration is no longer running.

## Private rollback and managed hosts

Before applying a restore, the migrator records newly added file paths and keeps
copies of overwritten files. Database imports back up the old database to the
same private directory unless `--skip-db-backup` was explicitly selected.
The report prints the rollback path. By default this is a private temporary
directory outside the web root. For durable storage, pass a new, unused
`--rollback-dir=/private/path/run-id` outside the document root. Temporary storage
may be removed by the host. Cleanup of the import stage never removes rollback
files. Keep enough free space for the database and overwritten files.

```bash
mb-migrator rollback --target-root=/srv/htdocs \
  --rollback-dir=/private/path/run-id
```

Pause writes before rollback. It restores the old database and overwritten files,
removes files added by the import, and retains migration safety state. Empty
created directories may remain. Config migration via `--migrate-config` uses its
existing separate config backups; the rollback command does not restore config.
Rollback is not a transaction and may be incomplete after an interrupted command;
keep the rollback directory and inspect any reported error before retrying.

Managed hosts are checked using a read-only database query rather than parsing
literal DB constants. WP-CLI runs from the document root and retains the host's
shared-core wrapper. Global plugin/theme flags precede commands. Known WPE MU
plugins and migrator safety files are excluded from source merges. Destination
symlinks, including nested managed paths, are preserved by default. Files are
compared by checksum so same-size, same-timestamp changes are still applied.

## Explicit migration safety and cutover

No new safety guard is installed unless `--safety=enable` is requested or the
operator runs `safety enable`. A restore preserves an existing guard and reports
its presence at completion. The guard blocks WordPress mail, ready cron jobs,
Action Scheduler workers, and WooCommerce Subscriptions automatic processing.
It does not block third-party services that send mail or charge independently.

```bash
mb-migrator safety enable --target-root=/srv/htdocs
mb-migrator safety status --target-root=/srv/htdocs
mb-migrator safety disable --target-root=/srv/htdocs \
  --live-url=https://www.example.com
```

Before releasing safety, disable renewal processing on the old host and finish
catch-up while writes are paused. DNS changes alone do not stop the old host's
background jobs. The release command requires the live URL to match WordPress
home and siteurl, asks for confirmation, updates the native Subscriptions live
URL when installed, and removes only the exact guard installed by this migrator.
It checks for any remaining Subscriptions staging override afterward. It never
silences the banner to conceal staging mode. Existing custom or legacy guards
must be inspected separately. No source host settings are changed automatically.

The portability and relay smoke suites use synthetic backups and isolated SSH
stand-ins. Run them alongside the existing regression suites:

```bash
bash tests/portability-smoke.sh
bash tests/relay-smoke.sh
```
