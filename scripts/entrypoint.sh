#!/bin/sh

# Configuration
SYNC_INTERVAL="${SYNC_INTERVAL:-5}"
SYNC_INTERVAL_SECONDS=$((SYNC_INTERVAL * 60))
MAX_FAILURES="${MAX_FAILURES:-10}"
MAX_BACKOFF_MINUTES="${MAX_BACKOFF_MINUTES:-60}"
MAX_BACKOFF_SECONDS=$((MAX_BACKOFF_MINUTES * 60))

# State tracking
export CONSECUTIVE_FAILURES=0
CURRENT_BACKOFF=$SYNC_INTERVAL_SECONDS

echo "=== Google Drive Sync Container ==="
echo "Sync interval: every ${SYNC_INTERVAL} minutes"
echo "Max failures before stop: ${MAX_FAILURES} (0=unlimited)"
echo "Max back-off: ${MAX_BACKOFF_MINUTES} minutes"
echo "Running as user: $(id)"
echo "Starting at: $(date)"

# Run sync loop
while true; do
    # Export current failure count for sync.sh to use
    export CONSECUTIVE_FAILURES
    export MAX_FAILURES

    # Run sync script and capture exit code
    /scripts/sync.sh
    EXIT_CODE=$?

    if [ $EXIT_CODE -eq 0 ]; then
        # Success - reset failure count and back-off
        if [ $CONSECUTIVE_FAILURES -gt 0 ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Sync recovered after ${CONSECUTIVE_FAILURES} failure(s)"
        fi
        CONSECUTIVE_FAILURES=0
        CURRENT_BACKOFF=$SYNC_INTERVAL_SECONDS
        SLEEP_TIME=$SYNC_INTERVAL_SECONDS

    elif [ $EXIT_CODE -eq 7 ]; then
        # Critical error requiring resync - stop container
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] CRITICAL: Exit code 7 - resync required. Stopping container."
        exit 7

    else
        # Non-critical failure - apply back-off
        CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Failure ${CONSECUTIVE_FAILURES}/${MAX_FAILURES}"

        # Check circuit breaker (if MAX_FAILURES > 0)
        if [ "${MAX_FAILURES}" -gt 0 ] && [ "${CONSECUTIVE_FAILURES}" -ge "${MAX_FAILURES}" ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Circuit breaker tripped after ${CONSECUTIVE_FAILURES} consecutive failures. Stopping container."
            exit 1
        fi

        # Exponential back-off: double the interval, cap at MAX_BACKOFF
        CURRENT_BACKOFF=$((CURRENT_BACKOFF * 2))
        if [ $CURRENT_BACKOFF -gt $MAX_BACKOFF_SECONDS ]; then
            CURRENT_BACKOFF=$MAX_BACKOFF_SECONDS
        fi
        SLEEP_TIME=$CURRENT_BACKOFF

        BACKOFF_MINUTES=$((SLEEP_TIME / 60))
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Back-off active: next retry in ${BACKOFF_MINUTES} minute(s)"
    fi

    echo "Sleeping for $((SLEEP_TIME / 60)) minutes..."
    sleep ${SLEEP_TIME}
done
