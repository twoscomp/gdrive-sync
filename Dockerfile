# Pinned deliberately. This setup depends on bisync flag semantics that have
# changed between releases (--max-delete as a percentage, --resilient wording,
# --recover, --max-lock), and `latest` would let a rebuild move rclone under a
# flag set where a regression means deleted files. Bump intentionally, and
# re-check scripts/sync.sh against the release notes when you do.
FROM rclone/rclone:1.75.1

RUN apk add --no-cache curl
