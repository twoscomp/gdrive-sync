#!/bin/sh

# Load environment variables (for cron)
. /etc/environment 2>/dev/null || true

LOG_PREFIX="[$(date '+%Y-%m-%d %H:%M:%S')]"
LOCAL_PATH="/data/documents"
REMOTE_PATH="gdrive:Documents"
EXCLUDE_FILE="/config/excludes.txt"

# Function to send email via Gmail SMTP using curl
send_failure_email() {
    ERROR_OUTPUT="$1"
    ERROR_CODE="$2"
    HOSTNAME=$(hostname)
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    # Truncate error output if too long
    ERROR_SNIPPET=$(echo "${ERROR_OUTPUT}" | tail -50)

    # Create email content
    EMAIL_CONTENT="From: ${GMAIL_USER}
To: ${NOTIFY_EMAIL}
Subject: [gdrive-sync] Sync Failed on ${HOSTNAME}

Google Drive sync failed at ${TIMESTAMP}

Exit Code: ${ERROR_CODE}

Error Output:
${ERROR_SNIPPET}

---
This is an automated message from gdrive-sync container.
"

    # Send via Gmail SMTP
    echo "${EMAIL_CONTENT}" | curl --silent --show-error \
        --url "smtps://smtp.gmail.com:465" \
        --ssl-reqd \
        --mail-from "${GMAIL_USER}" \
        --mail-rcpt "${NOTIFY_EMAIL}" \
        --user "${GMAIL_USER}:${GMAIL_APP_PASSWORD}" \
        --upload-file -

    if [ $? -eq 0 ]; then
        echo "${LOG_PREFIX} Failure notification sent"
    else
        echo "${LOG_PREFIX} Failed to send notification email"
    fi
}

echo "${LOG_PREFIX} Starting sync..."

# Build rclone bisync command
RCLONE_CMD="rclone bisync ${LOCAL_PATH} ${REMOTE_PATH} \
    --config /config/rclone/rclone.conf \
    --exclude-from ${EXCLUDE_FILE} \
    --conflict-resolve newer \
    --drive-skip-gdocs \
    --verbose"

# Run bisync
OUTPUT=$(${RCLONE_CMD} 2>&1)
EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
    echo "${LOG_PREFIX} Sync completed successfully"
    echo "${OUTPUT}" | tail -20
else
    echo "${LOG_PREFIX} Sync FAILED with exit code ${EXIT_CODE}"
    echo "${OUTPUT}"

    # Send email notification
    if [ -n "${GMAIL_USER}" ] && [ -n "${GMAIL_APP_PASSWORD}" ] && [ -n "${NOTIFY_EMAIL}" ]; then
        echo "${LOG_PREFIX} Sending failure notification to ${NOTIFY_EMAIL}..."
        send_failure_email "${OUTPUT}" "${EXIT_CODE}"
    else
        echo "${LOG_PREFIX} Email not configured, skipping notification"
    fi
fi

exit $EXIT_CODE
