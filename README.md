# gdrive-sync

Bidirectional sync between a local folder and Google Drive using rclone bisync in Docker.

## Features

- Bidirectional sync with Google Drive using `rclone bisync`
- Configurable sync interval (default: every 5 minutes)
- Conflict resolution: newest file wins
- Email notifications on sync failure via Gmail SMTP
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

Copy the `[gdrive]` section to `config/rclone.conf`.

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

### 5. Initialize Bisync

Before running the container, you must initialize bisync. This creates the baseline state for bidirectional sync.

**Option A: Initialize from local (local is authoritative)**
```bash
docker compose run --rm --entrypoint rclone gdrive-sync bisync /data gdrive: \
    --config /config/rclone/rclone.conf \
    --exclude-from /config/excludes.txt \
    --conflict-resolve newer \
    --drive-export-formats link.html \
    --resync \
    --resync-mode path1 \
    --verbose
```

**Option B: Initialize from Google Drive (remote is authoritative)**
```bash
docker compose run --rm --entrypoint rclone gdrive-sync bisync /data gdrive: \
    --config /config/rclone/rclone.conf \
    --exclude-from /config/excludes.txt \
    --conflict-resolve newer \
    --drive-export-formats link.html \
    --resync \
    --resync-mode path2 \
    --verbose
```

### 6. Start the Container

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
├── config/
│   ├── rclone.conf         # Your rclone config (git-ignored)
│   ├── rclone.conf.template
│   └── excludes.txt        # Patterns to exclude from sync
├── scripts/
│   ├── entrypoint.sh       # Container entrypoint (sets up cron)
│   └── sync.sh             # Main sync script
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
- SyncThing: `.stfolder`, `.stignore`, `.stversions/`

### Sync Paths

The default syncs your entire Google Drive root to `/data`. To sync a specific folder instead, edit `scripts/sync.sh`:

```bash
REMOTE_PATH="gdrive:Documents"  # Sync only the Documents folder
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

Then copy the updated config to `config/rclone.conf`.

### Resync Required

If bisync detects too many changes or inconsistencies, it may require a resync:

```bash
docker compose run --rm --entrypoint rclone gdrive-sync bisync /data gdrive: \
    --config /config/rclone/rclone.conf \
    --exclude-from /config/excludes.txt \
    --conflict-resolve newer \
    --drive-export-formats link.html \
    --resync \
    --verbose
```

## Security Notes

- Keep `config/rclone.conf` and `.env` secure - they contain sensitive credentials
- Add these to `.gitignore` if using version control
- The Gmail App Password only works for SMTP and cannot access your full Google account
