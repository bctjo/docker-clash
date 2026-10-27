#!/bin/bash
set -euo pipefail
# Test the actual routing decisions for each destination through the mixed port.
# GLOBAL.now can be unrelated to rule-mode traffic and must not select the probe node.
export CONNECTIVITY_PROXY="http://127.0.0.1:${CLASH_MIXED_PORT:-7893}"
export CONNECTIVITY_PROXY_USER
CONNECTIVITY_PROXY_USER=$(python3 - <<'PY'
from pathlib import Path
import yaml
config = yaml.safe_load(Path('/root/.config/clash/config.yaml').read_text()) or {}
credentials = config.get('authentication') or []
print(credentials[0] if credentials else '', end='')
PY
)
export PROBE_MODE=router
exec "$(dirname "$0")/connectivity_probe.sh"
