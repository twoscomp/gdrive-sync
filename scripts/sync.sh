#!/bin/sh
#
# Runs a single rclone bisync pass. entrypoint.sh calls this in a loop and
# exports CONSECUTIVE_FAILURES / MAX_FAILURES so email can be throttled.
#
# Exit codes:
#   0    sync completed
#   7    bisync aborted and a MANUAL --resync is required (see README)
#   143  interrupted by SIGTERM/SIGINT
#   *    other failure; entrypoint applies exponential back-off

LOCAL_DIR="/data"
REMOTE_DIR="gdrive:"
EXCLUDE_FILE="/config/excludes.txt"
RCLONE_CONF="/config/rclone/rclone.conf"

# bisync reinterprets --max-delete as a PERCENTAGE of the files on a side, and
# defaults it to 50. That default is too low to ever rename or delete a folder:
# bisync counts one delete per contained file, trips "Safety abort: too many
# deletes", and the change never propagates.
#
# Raising it genuinely widens the blast radius: up to this percentage of one
# side can be deleted in a single run without any warning. BACKUP_DIR below is
# the real safety net, not --check-access -- see the comment there.
MAX_DELETE_PERCENT="${MAX_DELETE_PERCENT:-90}"

# --check-access requires a sentinel file at the root of both sides. It is a
# narrow guard: it only catches the case where the sentinel itself disappears.
# It does NOT catch a partial mass deletion that leaves the sentinel intact.
# (The fully-empty case -- an unmounted dataset -- is already caught by rclone's
# own "empty current Path1 listing" critical error, with or without this flag.)
#
# Deliberately root-only. rclone suggests a sentinel per subdirectory, but that
# makes deleting any top-level folder fail the access test, which is exactly the
# operation this whole setup exists to support.
CHECK_ACCESS="${CHECK_ACCESS:-true}"
CHECK_FILENAME="${CHECK_FILENAME:-RCLONE_TEST}"

# Where deleted/overwritten LOCAL files are moved instead of being destroyed.
# This matters because the two directions are not equally recoverable: files
# rclone deletes from Google Drive go to Drive's trash (30 days), but files it
# deletes locally are gone for good -- and that loss fans out to every Syncthing
# peer. Set empty to disable.
BACKUP_DIR="${BACKUP_DIR:-/backup}"

SYNC_VERBOSE="${SYNC_VERBOSE:-false}"

# curl matches netrc credentials by hostname, so the host in SMTP_URL and the
# machine in the netrc file must agree or curl silently sends unauthenticated.
# Derived from one variable so they cannot drift.
SMTP_HOST="${SMTP_HOST:-smtp.gmail.com}"
SMTP_URL="${SMTP_URL:-smtps://${SMTP_HOST}:465}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

LOG_FILE=$(mktemp /tmp/gdrive-sync-log.XXXXXX) || exit 1
RC_FILE=$(mktemp /tmp/gdrive-sync-rc.XXXXXX) || exit 1
PID_FILE=$(mktemp /tmp/gdrive-sync-pid.XXXXXX) || exit 1

cleanup_temp() {
    rm -f "$LOG_FILE" "$RC_FILE" "$PID_FILE"
}

# Forward shutdown signals to rclone so bisync can close out cleanly instead of
# being SIGKILLed mid-transfer, which is what leaves the state dir needing a
# resync in the first place.
TERMINATED=0
forward_term() {
    TERMINATED=1
    _rc_pid=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$_rc_pid" ]; then
        log "Shutdown signal received, stopping rclone (pid ${_rc_pid})..."
        kill -TERM "$_rc_pid" 2>/dev/null
    fi
}
trap forward_term TERM INT

# Send email via Gmail SMTP using curl.
#   $1 - notification type: first_failure, circuit_breaker, resync_required
#   $2 - path to the log file holding rclone's output
#   $3 - exit code
send_notification_email() {
    NOTIFICATION_TYPE="$1"
    ERROR_LOG="$2"
    ERROR_CODE="$3"

    if ! command -v curl >/dev/null 2>&1; then
        log "curl not available, skipping email notification"
        return 0
    fi

    HOSTNAME=$(hostname)
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    # Failure being reported is the one that has not been counted yet.
    FAILURE_NUMBER=$((${CONSECUTIVE_FAILURES:-0} + 1))
    ERROR_SNIPPET=$(tail -50 "${ERROR_LOG}" 2>/dev/null)

    case "${NOTIFICATION_TYPE}" in
        first_failure)
            SUBJECT="[gdrive-sync] Sync failed on ${HOSTNAME}"
            BODY="Google Drive sync failed at ${TIMESTAMP}

Exit Code: ${ERROR_CODE}

Back-off is now active. Subsequent failures will use exponential back-off
and emails will be suppressed until recovery or circuit breaker trips.

Error Output:
${ERROR_SNIPPET}"
            ;;

        circuit_breaker)
            SUBJECT="[gdrive-sync] STOPPED after ${FAILURE_NUMBER} failures on ${HOSTNAME}"
            BODY="Google Drive sync has been STOPPED after ${FAILURE_NUMBER} consecutive failures.

Last failure at ${TIMESTAMP}
Last Exit Code: ${ERROR_CODE}

Manual intervention required. Please:
1. Check the logs: docker logs gdrive-sync
2. Fix the underlying issue
3. Restart the container: docker restart gdrive-sync

If the log shows "Bisync critical error" or "retryable without --resync"
repeating, the bisync state directory is the problem and a manual --resync is
the way out.

READ THIS BEFORE RUNNING A RESYNC
---------------------------------
A resync CANNOT propagate a deletion. It discards the prior sync state and
merges both sides, so any file that exists on only one side is copied to the
other -- including files you deliberately deleted. --resync-mode only picks the
winner for files present on BOTH sides.

So before you resync, make the two sides look the way you want them to end up.
Then run the command in the README under "Resync required", and restart.

Last Error Output:
${ERROR_SNIPPET}"
            ;;

        resync_required)
            SUBJECT="[gdrive-sync] MANUAL RESYNC REQUIRED on ${HOSTNAME}"
            BODY="Google Drive sync aborted at ${TIMESTAMP} and cannot continue
without a manual --resync.

Exit Code: ${ERROR_CODE}

READ THIS BEFORE RUNNING A RESYNC
---------------------------------
A resync CANNOT propagate a deletion. It discards the prior sync state and
merges both sides, so any file that exists only on one path is copied to the
other -- including files you deliberately deleted. --resync-mode only decides
the winner for files present on BOTH sides; it does not delete anything.

So before you resync: make the two sides look the way you want them to end up.
If you deleted a folder locally and want it gone, delete it on Google Drive too
(or vice versa). Otherwise the resync will restore it.

Once both sides are reconciled, run:

  docker compose run --rm --entrypoint rclone gdrive-sync bisync /data gdrive: \\
    --config /config/rclone/rclone.conf \\
    --exclude-from /config/excludes.txt \\
    --conflict-resolve newer \\
    --drive-export-formats link.html \\
    --drive-skip-dangling-shortcuts \\
    --create-empty-src-dirs \\
    --track-renames \\
    --resync --resync-mode path1 \\
    --verbose

Use --resync-mode path2 instead if Google Drive should win conflicts.
Add --dry-run first if you want to preview.

Then restart the container: docker restart gdrive-sync

Error Output:
${ERROR_SNIPPET}

The container is parked and will not sync until it is restarted."
            ;;

        startup_failed)
            SUBJECT="[gdrive-sync] WILL NOT START on ${HOSTNAME}"
            BODY="Google Drive sync refused to start at ${TIMESTAMP} and is parked.
It is NOT syncing and will not retry until it is restarted.

Reason:
${ERROR_SNIPPET}

Fix the condition above, then restart the container:
  docker restart gdrive-sync"
            ;;

        *)
            log "Unknown notification type: ${NOTIFICATION_TYPE}"
            return 1
            ;;
    esac

    # curl sends the file verbatim; --crlf converts our bare LFs to CRLF and
    # dot-stuffs leading dots, without which a body line of "." silently
    # truncates the message at a strict MTA.
    NETRC_FILE=$(mktemp /tmp/gdrive-sync-netrc.XXXXXX) || return 1
    chmod 600 "$NETRC_FILE"
    printf 'machine %s login %s password %s\n' \
        "${SMTP_HOST}" "${GMAIL_USER}" "${GMAIL_APP_PASSWORD}" > "$NETRC_FILE"

    {
        printf 'From: %s\r\n' "${GMAIL_USER}"
        printf 'To: %s\r\n' "${NOTIFY_EMAIL}"
        printf 'Subject: %s\r\n' "${SUBJECT}"
        printf 'Date: %s\r\n' "$(date -R 2>/dev/null || date)"
        printf 'MIME-Version: 1.0\r\n'
        printf 'Content-Type: text/plain; charset=UTF-8\r\n'
        printf '\r\n'
        printf '%s\r\n' "${BODY}"
        printf '\r\n---\r\nThis is an automated message from the gdrive-sync container.\r\n'
    } | curl --silent --show-error \
        --url "${SMTP_URL}" \
        --ssl-reqd \
        --crlf \
        --connect-timeout 15 \
        --max-time 60 \
        --mail-from "${GMAIL_USER}" \
        --mail-rcpt "${NOTIFY_EMAIL}" \
        --netrc-file "$NETRC_FILE" \
        --upload-file -
    CURL_RC=$?
    rm -f "$NETRC_FILE"

    if [ "$CURL_RC" -eq 0 ]; then
        log "${NOTIFICATION_TYPE} notification sent to ${NOTIFY_EMAIL}"
    else
        log "Failed to send notification email"
    fi
}

email_configured() {
    [ -n "${GMAIL_USER}" ] && [ -n "${GMAIL_APP_PASSWORD}" ] && [ -n "${NOTIFY_EMAIL}" ]
}

# Notify-only mode, so entrypoint.sh can send mail without a separate script
# (and therefore without another volume mount to keep in sync across deploys):
#   sync.sh --notify <type> <logfile> <exit-code>
if [ "$1" = "--notify" ]; then
    if email_configured; then
        send_notification_email "$2" "$3" "$4"
    else
        log "Email not configured, skipping ${2} notification"
    fi
    cleanup_temp
    exit 0
fi

log "Starting sync..."

set -- bisync "$LOCAL_DIR" "$REMOTE_DIR" \
    --config "$RCLONE_CONF" \
    --exclude-from "$EXCLUDE_FILE" \
    --conflict-resolve newer \
    --drive-export-formats link.html \
    --drive-skip-dangling-shortcuts \
    --create-empty-src-dirs \
    --track-renames \
    --max-delete "$MAX_DELETE_PERCENT" \
    --max-lock 15m \
    --recover \
    --resilient

# Sentinel files on both paths. If /data is ever unmounted or empty, bisync
# aborts instead of deleting the whole of Google Drive.
if [ "$CHECK_ACCESS" = "true" ]; then
    set -- "$@" --check-access --check-filename "$CHECK_FILENAME"
fi

if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
    set -- "$@" --backup-dir1 "$BACKUP_DIR"
elif [ -n "$BACKUP_DIR" ]; then
    log "WARNING: BACKUP_DIR ${BACKUP_DIR} does not exist; local deletions will be PERMANENT"
fi

[ "$SYNC_VERBOSE" = "true" ] && set -- "$@" --verbose

# A signal can arrive after the trap is armed but before PID_FILE is written,
# in which case forward_term has nothing to signal -- so re-check here rather
# than launching a sync we have already been told to abandon.
if [ "$TERMINATED" -eq 1 ]; then
    log "Shutdown signal received before sync started"
    cleanup_temp
    exit 143
fi

# Run rclone in the background so the trap above can reach it, streaming output
# live to the container log while keeping a copy on disk for the email body.
{
    rclone "$@" 2>&1 &
    _pid=$!
    echo "$_pid" > "$PID_FILE"
    wait "$_pid"
    echo "$?" > "$RC_FILE"
} | tee "$LOG_FILE" &
PIPELINE_PID=$!

wait "$PIPELINE_PID" 2>/dev/null
if [ "$TERMINATED" -eq 1 ]; then
    wait "$PIPELINE_PID" 2>/dev/null
    log "Sync interrupted by shutdown signal"
    cleanup_temp
    exit 143
fi

# rclone is reaped; stop forward_term from signalling a recycled PID.
: > "$PID_FILE"

EXIT_CODE=$(cat "$RC_FILE" 2>/dev/null)
case "$EXIT_CODE" in
    ''|*[!0-9]*) EXIT_CODE=1 ;;
esac

if [ "$EXIT_CODE" -eq 0 ]; then
    log "Sync completed successfully"
    cleanup_temp
    exit 0
fi

# rclone returns exit code 7 both for "must run --resync" and for aborts that
# --resilient makes retryable without one, so key off the message, not the code.
if grep -q "Must run --resync to recover" "$LOG_FILE" 2>/dev/null; then
    log "Sync FAILED (exit ${EXIT_CODE}) - MANUAL RESYNC REQUIRED"

    if email_configured; then
        log "Sending manual resync notification to ${NOTIFY_EMAIL}..."
        send_notification_email "resync_required" "${LOG_FILE}" "${EXIT_CODE}"
    else
        log "Email not configured, skipping notification"
    fi

    cleanup_temp
    exit 7
fi

log "Sync FAILED with exit code ${EXIT_CODE}"

CONSECUTIVE_FAILURES="${CONSECUTIVE_FAILURES:-0}"
MAX_FAILURES="${MAX_FAILURES:-10}"

if email_configured; then
    if [ "${CONSECUTIVE_FAILURES}" -eq 0 ]; then
        log "Sending first failure notification to ${NOTIFY_EMAIL}..."
        send_notification_email "first_failure" "${LOG_FILE}" "${EXIT_CODE}"
    elif [ "${MAX_FAILURES}" -gt 0 ] && [ "${CONSECUTIVE_FAILURES}" -ge "$((MAX_FAILURES - 1))" ]; then
        log "Sending circuit breaker notification to ${NOTIFY_EMAIL}..."
        send_notification_email "circuit_breaker" "${LOG_FILE}" "${EXIT_CODE}"
    elif [ "$(((CONSECUTIVE_FAILURES + 1) % 20))" -eq 0 ]; then
        # Without this, MAX_FAILURES=0 ("unlimited") means exactly one email
        # ever and sync can stay broken indefinitely in silence.
        log "Sending periodic failure reminder to ${NOTIFY_EMAIL}..."
        send_notification_email "first_failure" "${LOG_FILE}" "${EXIT_CODE}"
    else
        log "Suppressing email notification (failure $((CONSECUTIVE_FAILURES + 1)), back-off active)"
    fi
else
    log "Email not configured, skipping notification"
fi

cleanup_temp

# Never surface 7 for anything other than a genuine manual-resync abort; the
# entrypoint parks the container on 7.
[ "$EXIT_CODE" -eq 7 ] && EXIT_CODE=1
exit "$EXIT_CODE"
