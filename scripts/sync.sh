#!/bin/sh

LOG_PREFIX="[$(date '+%Y-%m-%d %H:%M:%S')]"
LOCAL_PATH="/data"
REMOTE_PATH="gdrive:"
EXCLUDE_FILE="/config/excludes.txt"

# Function to send email via Gmail SMTP using curl
# Arguments:
#   $1 - notification type: first_failure, circuit_breaker, resync_required
#   $2 - error output
#   $3 - exit code
send_notification_email() {
    NOTIFICATION_TYPE="$1"
    ERROR_OUTPUT="$2"
    ERROR_CODE="$3"

    # Check if curl is available
    if ! command -v curl >/dev/null 2>&1; then
        echo "${LOG_PREFIX} curl not available, skipping email notification"
        return 0
    fi

    HOSTNAME=$(hostname)
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    # Truncate error output if too long
    ERROR_SNIPPET=$(echo "${ERROR_OUTPUT}" | tail -50)

    # Build email based on notification type
    case "${NOTIFICATION_TYPE}" in
        first_failure)
            SUBJECT="[gdrive-sync] Sync Failed on ${HOSTNAME}"
            BODY="Google Drive sync failed at ${TIMESTAMP}

Exit Code: ${ERROR_CODE}

Back-off is now active. Subsequent failures will use exponential back-off
and emails will be suppressed until recovery or circuit breaker trips.

Error Output:
${ERROR_SNIPPET}"
            ;;

        circuit_breaker)
            SUBJECT="[gdrive-sync] STOPPED - ${CONSECUTIVE_FAILURES} failures on ${HOSTNAME}"
            BODY="Google Drive sync has been STOPPED after ${CONSECUTIVE_FAILURES} consecutive failures.

Last failure at ${TIMESTAMP}
Last Exit Code: ${ERROR_CODE}

Manual intervention required. Please:
1. Check the logs: docker logs gdrive-sync
2. Fix the underlying issue
3. Restart the container: docker restart gdrive-sync

Last Error Output:
${ERROR_SNIPPET}"
            ;;

        resync_required)
            SUBJECT="[gdrive-sync] RESYNC REQUIRED on ${HOSTNAME}"
            BODY="Google Drive sync encountered a CRITICAL ERROR requiring resync.

This typically happens when:
- The bisync state has become corrupted
- Files were modified on both sides in conflicting ways
- The sync state is too far out of date

Exit Code: ${ERROR_CODE} (resync required)

To recover, run the following command to perform a fresh resync:
  docker exec gdrive-sync rclone bisync /data gdrive: \\
    --config /config/rclone/rclone.conf \\
    --resync \\
    --verbose

WARNING: The --resync flag will make the remote match the local state.
Review both sides before running if you're unsure which has the correct files.

Error Output:
${ERROR_SNIPPET}

The container has been stopped to prevent data loss."
            ;;

        *)
            echo "${LOG_PREFIX} Unknown notification type: ${NOTIFICATION_TYPE}"
            return 1
            ;;
    esac

    # Create email content
    EMAIL_CONTENT="From: ${GMAIL_USER}
To: ${NOTIFY_EMAIL}
Subject: ${SUBJECT}

${BODY}

---
This is an automated message from gdrive-sync container."

    # Send via Gmail SMTP
    echo "${EMAIL_CONTENT}" | curl --silent --show-error \
        --url "smtps://smtp.gmail.com:465" \
        --ssl-reqd \
        --mail-from "${GMAIL_USER}" \
        --mail-rcpt "${NOTIFY_EMAIL}" \
        --user "${GMAIL_USER}:${GMAIL_APP_PASSWORD}" \
        --upload-file -

    if [ $? -eq 0 ]; then
        echo "${LOG_PREFIX} ${NOTIFICATION_TYPE} notification sent to ${NOTIFY_EMAIL}"
    else
        echo "${LOG_PREFIX} Failed to send notification email"
    fi
}

# Check if email is configured
email_configured() {
    [ -n "${GMAIL_USER}" ] && [ -n "${GMAIL_APP_PASSWORD}" ] && [ -n "${NOTIFY_EMAIL}" ]
}

echo "${LOG_PREFIX} Starting sync..."

# Build rclone bisync command
RCLONE_CMD="rclone bisync ${LOCAL_PATH} ${REMOTE_PATH} \
    --config /config/rclone/rclone.conf \
    --exclude-from ${EXCLUDE_FILE} \
    --conflict-resolve newer \
    --drive-export-formats link.html \
    --drive-skip-dangling-shortcuts \
    --create-empty-src-dirs \
    --track-renames \
    --verbose"

# Run bisync
OUTPUT=$(${RCLONE_CMD} 2>&1)
EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
    echo "${LOG_PREFIX} Sync completed successfully"
    echo "${OUTPUT}" | tail -20
elif [ $EXIT_CODE -eq 7 ]; then
    # Exit code 7: Critical error requiring resync
    echo "${LOG_PREFIX} Sync FAILED with exit code 7 - RESYNC REQUIRED"
    echo "${OUTPUT}"

    if email_configured; then
        echo "${LOG_PREFIX} Sending resync required notification to ${NOTIFY_EMAIL}..."
        send_notification_email "resync_required" "${OUTPUT}" "${EXIT_CODE}"
    else
        echo "${LOG_PREFIX} Email not configured, skipping notification"
    fi

    # Exit with code 7 for entrypoint to handle specially
    exit 7
else
    # Non-critical failure (exit code 1, etc.)
    echo "${LOG_PREFIX} Sync FAILED with exit code ${EXIT_CODE}"
    echo "${OUTPUT}"

    # Notification throttling based on consecutive failures
    # CONSECUTIVE_FAILURES is set by entrypoint.sh before calling this script
    CONSECUTIVE_FAILURES="${CONSECUTIVE_FAILURES:-0}"
    MAX_FAILURES="${MAX_FAILURES:-10}"

    if email_configured; then
        if [ "${CONSECUTIVE_FAILURES}" -eq 0 ]; then
            # First failure - send notification
            echo "${LOG_PREFIX} Sending first failure notification to ${NOTIFY_EMAIL}..."
            send_notification_email "first_failure" "${OUTPUT}" "${EXIT_CODE}"
        elif [ "${MAX_FAILURES}" -gt 0 ] && [ "${CONSECUTIVE_FAILURES}" -ge "$((MAX_FAILURES - 1))" ]; then
            # About to trip circuit breaker - send notification
            echo "${LOG_PREFIX} Sending circuit breaker notification to ${NOTIFY_EMAIL}..."
            send_notification_email "circuit_breaker" "${OUTPUT}" "${EXIT_CODE}"
        else
            # During back-off - suppress email
            echo "${LOG_PREFIX} Suppressing email notification (failure $((CONSECUTIVE_FAILURES + 1)), back-off active)"
        fi
    else
        echo "${LOG_PREFIX} Email not configured, skipping notification"
    fi
fi

exit $EXIT_CODE
