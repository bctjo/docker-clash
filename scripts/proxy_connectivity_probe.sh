#!/bin/bash
set -euo pipefail
# Test the actual routing decisions for each destination through the mixed port.
# GLOBAL.now can be unrelated to rule-mode traffic and must not select the probe node.
export CONNECTIVITY_PROXY="http://127.0.0.1:${CLASH_MIXED_PORT:-7893}"
export PROBE_MODE=router
exec "$(dirname "$0")/connectivity_probe.sh"
