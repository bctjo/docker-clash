#!/bin/bash
set -euo pipefail
curl -fsS --connect-timeout 2 --max-time 5 "http://127.0.0.1:${PORTAL_PORT:-9090}/setup/status.json" >/dev/null
kill -0 "$(cat /tmp/portal-worker.pid)"
if [[ -f /tmp/portal-auto-worker.pid ]]; then
  kill -0 "$(cat /tmp/portal-auto-worker.pid)"
fi
if [[ -f /tmp/portal-setup-complete ]]; then
  secret=$(jq -r '.secret' /root/.config/clash/portal.json)
  curl -fsS --connect-timeout 2 --max-time 5 -H "Authorization: Bearer $secret" \
    "http://127.0.0.1:${DASH_PORT:-9097}/version" >/dev/null
fi
