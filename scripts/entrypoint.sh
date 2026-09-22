#!/bin/sh
#
# Sync loop. Runs sync.sh on an interval, applies exponential back-off on
# failure, and parks the container when a manual resync is required.

SYNC_INTERVAL="${SYNC_INTERVAL:-5}"
SYNC_INTERVAL_SECONDS=$((SYNC_INTERVAL * 60))
MAX_FAILURES="${MAX_FAILURES:-10}"
MAX_BACKOFF_MINUTES="${MAX_BACKOFF_MINUTES:-60}"
MAX_BACKOFF_SECONDS=$((MAX_BACKOFF_MINUTES * 60))
CHECK_ACCESS="${CHECK_ACCESS:-true}"
CHECK_FILENAME="${CHECK_FILENAME:-RCLONE_TEST}"

LOCAL_DIR="/data"
REMOTE_DIR="gdrive:"
RCLONE_CONF="/config/rclone/rclone.conf"

STATE_DIR="/cache/rclone/bisync"
STATE_FILE="${STATE_DIR}/.failure_count"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

TERMINATE=0
CHILD_PID=""
SLEEP_PID=""

shutdown() {
    TERMINATE=1
    [ -n "$CHILD_PID" ] && kill -TERM "$CHILD_PID" 2>/dev/null
    [ -n "$SLEEP_PID" ] && kill -TERM "$SLEEP_PID" 2>/dev/null
    return 0
}
trap shutdown TERM INT

# sleep that a signal can break out of -- a plain foreground `sleep` blocks the
# trap, so `docker stop` would SIGKILL us (and any running rclone) after its
# grace period.
interruptible_sleep() {
    sleep "$1" &
    SLEEP_PID=$!
    wait "$SLEEP_PID" 2>/dev/null
    SLEEP_PID=""
}

# Hold the container open without syncing. Used when only a human can safely
# decide what to do, so that restart policies do not spin us in a crash loop.
# $2, if given, is a reason to email -- a parked container is silent otherwise.
park() {
    log "$1"
    if [ -n "$2" ]; then
        _notify_log=$(mktemp /tmp/gdrive-sync-startup.XXXXXX) && {
            printf '%s\n' "$2" > "$_notify_log"
            /scripts/sync.sh --notify startup_failed "$_notify_log" 0
            rm -f "$_notify_log"
        }
    fi
    log "Container is parked. It will not sync until it is restarted."
    while [ "$TERMINATE" -eq 0 ]; do
        interruptible_sleep 3600
        [ "$TERMINATE" -eq 0 ] && log "Still parked - manual intervention required."
    done
    log "Shutting down."
    exit 0
}

read_count() {
    _value=$(cat "$1" 2>/dev/null)
    case "$_value" in
        ''|*[!0-9]*) echo 0 ;;
        *) echo "$_value" ;;
    esac
}

# --check-access only protects us if the sentinel exists on BOTH sides. If it is
# missing, every single run would abort, so fail loudly at startup with the fix
# rather than emailing a failure every cycle.
preflight() {
    if [ ! -d "$LOCAL_DIR" ]; then
        park "STARTUP FAILED: ${LOCAL_DIR} does not exist. Check the volume mount." \
             "${LOCAL_DIR} does not exist inside the container. The volume mount for the sync folder is missing or wrong."
    fi

    [ "$CHECK_ACCESS" = "true" ] || return 0

    _local_ok=0
    [ -f "${LOCAL_DIR}/${CHECK_FILENAME}" ] && _local_ok=1

    # rclone lsf exits 3 when the file is genuinely absent and 1 when the remote
    # itself is unusable (expired token, no network yet after a NAS reboot).
    # Treating those the same would park the container forever on a transient
    # fault while reporting a file as missing when it is not.
    _remote_ok=0
    _remote_rc=0
    _attempt=1
    while [ "$_attempt" -le 5 ]; do
        rclone lsf "${REMOTE_DIR}${CHECK_FILENAME}" --config "$RCLONE_CONF" >/dev/null 2>&1
        _remote_rc=$?
        if [ "$_remote_rc" -eq 0 ]; then
            _remote_ok=1
            break
        fi
        [ "$_remote_rc" -eq 3 ] && break
        log "Remote not reachable yet (rclone exit ${_remote_rc}), retry ${_attempt}/5..."
        interruptible_sleep 15
        [ "$TERMINATE" -eq 1 ] && return 0
        _attempt=$((_attempt + 1))
    done

    if [ "$_local_ok" -eq 1 ] && [ "$_remote_ok" -eq 1 ]; then
        log "Access check sentinel '${CHECK_FILENAME}' found on both sides"
        return 0
    fi

    # Remote still unreachable rather than confirmed-missing: this is not a
    # config error, so fall through to the sync loop and let the normal
    # back-off and failure email handle it.
    if [ "$_remote_ok" -eq 0 ] && [ "$_remote_rc" -ne 3 ]; then
        log "WARNING: could not reach ${REMOTE_DIR} to verify the sentinel (rclone exit ${_remote_rc})."
        log "Continuing to the sync loop; failures will back off and notify as usual."
        return 0
    fi

    log "STARTUP FAILED: --check-access is enabled but the sentinel file is missing."
    [ "$_local_ok" -eq 0 ] && log "  missing: ${LOCAL_DIR}/${CHECK_FILENAME}"
    [ "$_remote_ok" -eq 0 ] && log "  missing: ${REMOTE_DIR}${CHECK_FILENAME}"
    log ""
    log "This file is the guard that stops an unmounted or empty ${LOCAL_DIR} from"
    log "being treated as a mass deletion. Create it on both sides, then restart:"
    log ""
    log "  touch <host path mounted at ${LOCAL_DIR}>/${CHECK_FILENAME}"
    log "  rclone touch ${REMOTE_DIR}${CHECK_FILENAME} --config <your rclone.conf>"
    log ""
    log "Set CHECK_ACCESS=false to disable the guard instead (not recommended)."
    park "Cannot start safely." \
         "The --check-access sentinel '${CHECK_FILENAME}' is missing. local=${_local_ok} remote=${_remote_ok} (1=present).
Create it on BOTH sides, then restart:
  touch <host path mounted at ${LOCAL_DIR}>/${CHECK_FILENAME}
  rclone touch ${REMOTE_DIR}${CHECK_FILENAME} --config <your rclone.conf>"
}

# The persisted count exists so back-off survives a crash/redeploy, but if it
# already reached MAX_FAILURES the container was parked and a human has now
# restarted it -- that restart IS the acknowledgement, so give a full budget
# again rather than parking on the very next failure.
CONSECUTIVE_FAILURES=$(read_count "$STATE_FILE")
if [ "${MAX_FAILURES}" -gt 0 ] && [ "$CONSECUTIVE_FAILURES" -ge "${MAX_FAILURES}" ]; then
    echo "Clearing persisted failure count (${CONSECUTIVE_FAILURES}) after manual restart"
    CONSECUTIVE_FAILURES=0
    rm -f "$STATE_FILE"
fi
CURRENT_BACKOFF=$SYNC_INTERVAL_SECONDS

echo "=== Google Drive Sync Container ==="
echo "Sync interval: every ${SYNC_INTERVAL} minutes"
echo "Max failures before stop: ${MAX_FAILURES} (0=unlimited)"
echo "Max back-off: ${MAX_BACKOFF_MINUTES} minutes"
echo "Max delete threshold: ${MAX_DELETE_PERCENT:-90}%"
echo "Access check: ${CHECK_ACCESS} (sentinel: ${CHECK_FILENAME})"
echo "Local delete backup dir: ${BACKUP_DIR:-(disabled)}"
echo "Running as user: $(id)"
echo "Starting at: $(date)"
[ "$CONSECUTIVE_FAILURES" -gt 0 ] && echo "Resuming with ${CONSECUTIVE_FAILURES} persisted consecutive failure(s)"

# Left over from the removed auto-resync; clean up on upgrade.
rm -f "${STATE_DIR}/.resync_attempts"

preflight

while [ "$TERMINATE" -eq 0 ]; do
    export CONSECUTIVE_FAILURES
    export MAX_FAILURES

    /scripts/sync.sh &
    CHILD_PID=$!
    wait "$CHILD_PID" 2>/dev/null
    EXIT_CODE=$?
    if [ "$TERMINATE" -eq 1 ]; then
        wait "$CHILD_PID" 2>/dev/null
        break
    fi
    CHILD_PID=""

    if [ "$EXIT_CODE" -eq 0 ]; then
        if [ "$CONSECUTIVE_FAILURES" -gt 0 ]; then
            log "Sync recovered after ${CONSECUTIVE_FAILURES} failure(s)"
        fi
        CONSECUTIVE_FAILURES=0
        rm -f "$STATE_FILE"
        CURRENT_BACKOFF=$SYNC_INTERVAL_SECONDS
        SLEEP_TIME=$SYNC_INTERVAL_SECONDS

    elif [ "$EXIT_CODE" -eq 7 ]; then
        # A resync is the only way forward, and a resync can never propagate a
        # deletion -- it merges both sides, restoring anything that exists on
        # only one of them. Doing that automatically silently resurrects deleted
        # files, so it is left to a human. See README "Resync required".
        park "CRITICAL: bisync requires a manual --resync. See the notification email or README."

    else
        CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
        echo "$CONSECUTIVE_FAILURES" > "$STATE_FILE"
        log "Failure ${CONSECUTIVE_FAILURES}/${MAX_FAILURES}"

        if [ "${MAX_FAILURES}" -gt 0 ] && [ "${CONSECUTIVE_FAILURES}" -ge "${MAX_FAILURES}" ]; then
            park "Circuit breaker tripped after ${CONSECUTIVE_FAILURES} consecutive failures."
        fi

        CURRENT_BACKOFF=$((CURRENT_BACKOFF * 2))
        if [ "$CURRENT_BACKOFF" -gt "$MAX_BACKOFF_SECONDS" ]; then
            CURRENT_BACKOFF=$MAX_BACKOFF_SECONDS
        fi
        SLEEP_TIME=$CURRENT_BACKOFF

        log "Back-off active: next retry in $((SLEEP_TIME / 60)) minute(s)"
    fi

    log "Sleeping for $((SLEEP_TIME / 60)) minutes..."
    interruptible_sleep "$SLEEP_TIME"
done

log "Shutting down."
exit 0
