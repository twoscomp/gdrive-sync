# TODO

- Rename `resync_required` email notification to better reflect auto-resync behavior.
  Currently the email body says "manual intervention required" but the service now attempts
  auto-resync first. Update the subject/body to say "auto-resync initiated" and only send
  the "manual intervention required" message if the auto-resync fails twice and the
  container stops.
