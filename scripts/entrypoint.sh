#!/bin/sh
set -e

SYNC_INTERVAL="${SYNC_INTERVAL:-5}"

echo "=== Google Drive Sync Container ==="
echo "Sync interval: every ${SYNC_INTERVAL} minutes"
echo "Starting at: $(date)"

# Create cron schedule (every N minutes)
CRON_SCHEDULE="*/${SYNC_INTERVAL} * * * *"

# Export environment variables for cron
env | grep -E '^(GMAIL_|NOTIFY_|TZ=)' > /etc/environment

# Create crontab
echo "${CRON_SCHEDULE} /scripts/sync.sh >> /var/log/sync.log 2>&1" > /etc/crontabs/root

# Create log file
touch /var/log/sync.log

echo "Cron schedule: ${CRON_SCHEDULE}"
echo "Starting cron daemon..."

# Start crond in foreground, tail the log
crond -f -l 2 &
CROND_PID=$!

# Tail the log file so container logs are visible
tail -F /var/log/sync.log &
TAIL_PID=$!

# Wait for either process to exit
wait $CROND_PID $TAIL_PID
