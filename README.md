# gdrive-sync

Bidirectional sync between a local folder and Google Drive using rclone bisync in Docker.

## Features

- Bidirectional sync with Google Drive using `rclone bisync`
- Configurable sync interval (default: every 5 minutes)
- Conflict resolution: newest file wins
- Folder renames and deletes propagate instead of aborting the sync
- Guarded against an unmounted local folder being read as a mass deletion
- Email notifications on sync failure via Gmail SMTP
- Exponential back-off, circuit breaker, and graceful shutdown
- Excludes common temp files, OS metadata, and SyncThing internals
- Google Docs/Sheets/Slides sync as clickable link files (.gdoc, .gsheet, .gslides)

## Prerequisites

- Docker and Docker Compose
- A Google account
- rclone installed locally (for initial OAuth setup)

## Setup

### 1. Create Google Cloud OAuth Credentials

1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Create a new project (or select existing)
3. Enable the **Google Drive API**:
   - Go to "APIs & Services" > "Library"
   - Search for "Google Drive API"
   - Click "Enable"
4. Create OAuth credentials:
   - Go to "APIs & Services" > "Credentials"
   - Click "Create Credentials" > "OAuth client ID"
   - If prompted, configure the OAuth consent screen:
     - User Type: External
     - App name: gdrive-sync (or any name)
     - Add your email as a test user
   - Application type: **Desktop app**
   - Name: gdrive-sync
   - Click "Create"
5. Download or copy the **Client ID** and **Client Secret**

### 2. Configure rclone

Run rclone config on your local machine (or in a temporary container):

```bash
rclone config
```

Choose:
1. `n` - New remote
2. Name: `gdrive`
3. Storage: `drive` (Google Drive)
4. Enter your **Client ID** from step 1
5. Enter your **Client Secret** from step 1
6. Scope: `drive` (full access)
7. Leave root_folder_id blank
8. Leave service_account_file blank
9. Edit advanced config: `n`
10. Use auto config: `y` (this opens a browser for OAuth)
11. Configure as team drive: `n`

After completing, copy the generated config:

```bash
cat ~/.config/rclone/rclone.conf
```

Copy the `[gdrive]` section to `config/rclone/rclone.conf`.

### 3. Configure Environment

```bash
cp .env.template .env
```

Edit `.env` with your settings:

```bash
# User/Group IDs for file ownership (run `id` to find yours)
PUID=1000
PGID=1000

# Your timezone
TZ=America/Los_Angeles

# Sync interval in minutes
SYNC_INTERVAL=5

# Path to your local Google Drive folder (on host)
LOCAL_PATH=/path/to/gdrive

# Gmail credentials for notifications
GMAIL_USER=your-email@gmail.com
GMAIL_APP_PASSWORD=xxxx-xxxx-xxxx-xxxx
NOTIFY_EMAIL=your-email@gmail.com
```

Find your UID/GID by running `id` on your host system.

### 4. Create Gmail App Password

1. Go to [Google Account Security](https://myaccount.google.com/security)
2. Enable 2-Factor Authentication if not already enabled
3. Go to [App Passwords](https://myaccount.google.com/apppasswords)
4. Generate a new app password for "Mail"
5. Copy the 16-character password to your `.env` file

### 5. Create the Access Check Sentinel

The container runs bisync with `--check-access`, which requires a file named
`RCLONE_TEST` at the root of **both** sides.

Create it on both sides before the first run:

```bash
touch /path/to/gdrive/RCLONE_TEST
rclone touch gdrive:RCLONE_TEST --config config/rclone/rclone.conf
```

If either copy is missing the container **parks** — it keeps running, logs which
side is missing, and does not sync until you fix it and restart.

Be clear about what this does and does not buy you. It catches the sentinel
itself disappearing. It does **not** catch a partial mass deletion that leaves
the sentinel in place, which is exactly what a raised `MAX_DELETE_PERCENT`
newly permits. And the fully-empty case — an unmounted dataset — is already
caught by rclone's own `empty current Path1 listing` error with or without this
flag. The real safety net is `BACKUP_PATH`, below.

The sentinel is deliberately **root-only**. rclone suggests one per
subdirectory, which would make `--check-access` far stricter — but it also makes
deleting any top-level folder fail the access test, which is the exact operation
this setup exists to support.

### 6. Initialize Bisync

Before running the container, you must initialize bisync. This creates the baseline state for bidirectional sync.

**Option A: Initialize from local (local is authoritative for conflicts)**
```bash
docker compose run --rm --entrypoint rclone gdrive-sync bisync /data gdrive: \
    --config /config/rclone/rclone.conf \
    --exclude-from /config/excludes.txt \
    --conflict-resolve newer \
    --drive-export-formats link.html \
    --drive-skip-dangling-shortcuts \
    --create-empty-src-dirs \
    --resync \
    --resync-mode path1 \
    --verbose
```

**Option B: Initialize from Google Drive (remote is authoritative for conflicts)**
```bash
docker compose run --rm --entrypoint rclone gdrive-sync bisync /data gdrive: \
    --config /config/rclone/rclone.conf \
    --exclude-from /config/excludes.txt \
    --conflict-resolve newer \
    --drive-export-formats link.html \
    --drive-skip-dangling-shortcuts \
    --create-empty-src-dirs \
    --resync \
    --resync-mode path2 \
    --verbose
```

> **A resync is a merge, not a mirror.** `--resync-mode` only picks the winner
> for files that exist on *both* sides. Files that exist on only one side are
> always copied to the other, in either mode. A resync can never delete
> anything. See [Resync required](#resync-required).

### 7. Start the Container

```bash
docker compose up -d
```

View logs:
```bash
docker compose logs -f gdrive-sync
```

## File Structure

```
gdrive-sync/
├── docker-compose.yml
├── .env                    # Your configuration (git-ignored)
├── .env.template           # Template for .env
├── truenas.yaml            # TrueNAS deployment (git-ignored, holds secrets)
├── truenas.yaml.template   # Template for truenas.yaml
├── config/
│   ├── rclone/             # rclone config directory (needs write access)
│   │   ├── rclone.conf     # Your rclone config (git-ignored)
│   │   └── rclone.conf.template
│   └── excludes.txt        # Patterns to exclude from sync
├── scripts/
│   ├── entrypoint.sh       # Sync loop, back-off, circuit breaker
│   └── sync.sh             # A single bisync pass + notifications
└── data/
    └── bisync/             # Persistent bisync state
```

## Configuration

### Excluded Files

Edit `config/excludes.txt` to customize which files are excluded from sync.

Default exclusions:
- Temp files: `*.tmp`, `~*`, `.~lock.*`
- OS metadata: `.DS_Store`, `Thumbs.db`
- Version control: `.git/`
- SyncThing: `.stfolder`, `.stignore`, `.stversions/`, `*.sync-conflict-*`

Edits take effect on the next run without needing a resync. Files that become
newly excluded stop being tracked but are not deleted from either side.

### Error Handling

| Variable | Default | Purpose |
| --- | --- | --- |
| `MAX_DELETE_PERCENT` | `90` | Percentage of files that may disappear from one side in a single run before bisync aborts. rclone's own default is **50**, which is too low to ever rename or delete a folder containing more than half your files. |
| `CHECK_ACCESS` | `true` | Require a sentinel file at the root of both sides. A narrow guard — see [step 5](#5-create-the-access-check-sentinel) for what it does and doesn't cover. |
| `CHECK_FILENAME` | `RCLONE_TEST` | Name of that sentinel file. |
| `BACKUP_PATH` / `BACKUP_DIR` | `./data/backup` → `/backup` | Where locally deleted or overwritten files are moved instead of destroyed. **This is the real protection against a mass delete.** Must not sit inside `LOCAL_PATH`. |
| `MAX_FAILURES` | `10` | Consecutive failures before the container parks itself (`0` = unlimited). |
| `MAX_BACKOFF_MINUTES` | `60` | Ceiling on the exponential back-off between retries. |
| `SYNC_VERBOSE` | `false` | Pass `--verbose` to rclone. Very chatty on large drives. |

#### Why deletions are backed up on the local side only

The two directions are not equally recoverable. Files rclone deletes from Google
Drive go to Drive's trash and are restorable for 30 days. Files it deletes
locally are gone permanently — and because the local folder is a Syncthing
share, that deletion propagates to every peer. `--backup-dir1` closes that gap.
Prune `BACKUP_PATH` periodically; nothing rotates it for you.

When the container cannot continue safely it **parks**: it stays running, logs
why, and stops syncing until you restart it. It does not exit, because a
restart policy would otherwise spin it in a crash loop.

### Sync Paths

The default syncs your entire Google Drive root to `/data`. To sync a specific folder instead, edit `REMOTE_DIR` in both `scripts/sync.sh` and `scripts/entrypoint.sh` (the entrypoint uses it for the access-check preflight):

```bash
REMOTE_DIR="gdrive:Documents"  # Sync only the Documents folder
```

## Troubleshooting

### Sync Errors

Check the logs:
```bash
docker compose logs -f gdrive-sync
```

### Token Expired

If you see authentication errors, regenerate the OAuth token:

```bash
rclone config reconnect gdrive:
```

Then copy the updated config to `config/rclone/rclone.conf`.

### Folder Renames and Deletes

bisync has no concept of a folder rename. Renaming `Photos/` to `Pictures/`
looks to bisync like every file in `Photos/` was deleted and an equal number of
new files appeared in `Pictures/`. Two consequences:

1. **It can trip the delete guard.** If that folder held more than
   `MAX_DELETE_PERCENT` of your files, the run aborts with
   `Safety abort: too many deletes` and the rename never propagates. Raise
   `MAX_DELETE_PERCENT`, or do the rename on both sides yourself.
2. **The files are re-uploaded, not moved.** `--track-renames` recovers this
   where the backend and hashes allow it, but expect a rename of a large folder
   to cost real bandwidth.

Renaming the folder to the same name on *both* sides, while the container is
stopped, is the cheapest way to do it.

### Resync Required

If bisync aborts with `Bisync aborted. Must run --resync to recover.`, the
container parks itself and emails you. It deliberately does **not** resync on
its own.

> **Read this first.** A resync cannot propagate a deletion. It throws away the
> prior sync state and merges the two sides: every file that exists on only one
> path is copied to the other. `--resync-mode` only decides the winner for
> files present on *both* paths. So if you deleted a folder locally and then
> resync, that folder comes straight back down from Google Drive — in every
> mode, including `path1`.
>
> Before you resync, make both sides look the way you want them to end up. If
> you deleted something locally and want it gone, delete it on Drive too.

Once the two sides are reconciled:

```bash
docker compose run --rm --entrypoint rclone gdrive-sync bisync /data gdrive: \
    --config /config/rclone/rclone.conf \
    --exclude-from /config/excludes.txt \
    --conflict-resolve newer \
    --drive-export-formats link.html \
    --drive-skip-dangling-shortcuts \
    --create-empty-src-dirs \
    --track-renames \
    --resync --resync-mode path1 \
    --verbose
```

Use `--resync-mode path2` instead if Google Drive should win conflicts. Add
`--dry-run` first to preview. Then `docker restart gdrive-sync`.

This is the same command the notification emails contain; keep the two in sync
if you change one.

Note that editing `config/excludes.txt` does **not** force a resync. bisync only
hashes filters passed via `--filters-file`, and this setup uses `--exclude-from`,
so edits take effect silently on the next run. A file that becomes newly excluded
is simply dropped from tracking — it is left in place on both sides, not deleted.

### Container Keeps Restarting

It should not — the entrypoint parks instead of exiting. If you still see
restarts, check `docker logs gdrive-sync` for a startup failure such as a
missing `RCLONE_TEST` sentinel or an unreadable `rclone.conf`.

## Security Notes

- `config/rclone/rclone.conf`, `.env`, and `truenas.yaml` hold credentials and are git-ignored
- If any of them was ever committed, rotate the credential — removing the file does not remove it from git history
- The Gmail App Password only works for SMTP and cannot access your full Google account
