#!/bin/sh
set -e

SYNC_INTERVAL="${SYNC_INTERVAL:-5}"
SYNC_INTERVAL_SECONDS=$((SYNC_INTERVAL * 60))

echo "=== Google Drive Sync Container ==="
echo "Sync interval: every ${SYNC_INTERVAL} minutes"
echo "Running as user: $(id)"
echo "Starting at: $(date)"

# Run sync loop
while true; do
    /scripts/sync.sh
    echo "Sleeping for ${SYNC_INTERVAL} minutes..."
    sleep ${SYNC_INTERVAL_SECONDS}
done
