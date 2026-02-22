#!/bin/bash
set -euo pipefail

escape_json() {
  printf '%s' "$1" | awk 'BEGIN{RS=""; ORS=""} {gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); gsub(/\r/,"\\r"); gsub(/\n/,"\\n"); print}'
}

dash_port="${DASH_PORT:-9097}"
clash_secret="${CLASH_SECRET:-}"
timeout_ms="${PROXY_TEST_TIMEOUT_MS:-8000}"
test_url_youtube="${PROXY_TEST_URL_YOUTUBE:-https://www.youtube.com/generate_204}"
test_url_github="${PROXY_TEST_URL_GITHUB:-https://github.com/}"
test_url_tmdb="${PROXY_TEST_URL_TMDB:-https://www.themoviedb.org/}"
test_url_baidu="${PROXY_TEST_URL_BAIDU:-https://www.baidu.com/}"

api_base="http://127.0.0.1:${dash_port}"

api_curl() {
  local url="$1"
  if [[ -n "$clash_secret" ]]; then
    curl -fsS -H "Authorization: Bearer ${clash_secret}" "$url"
  else
    curl -fsS "$url"
  fi
}

now_epoch=$(date +%s)
checked_at=$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S')

if ! proxies_json=$(api_curl "${api_base}/proxies" 2>/dev/null); then
  printf '{"mode":"router","checkedAtShanghai":"%s","checkedAtEpoch":%s,"error":"%s","sites":[]}\n' \
    "$(escape_json "$checked_at")" \
    "$now_epoch" \
    "failed to query clash proxies api"
  exit 0
fi

selected_node=$(printf '%s' "$proxies_json" | jq -r '.proxies.GLOBAL.now // empty')
if [[ -z "$selected_node" || "$selected_node" == "DIRECT" || "$selected_node" == "REJECT" ]]; then
  selected_node=$(printf '%s' "$proxies_json" | jq -r '
    (
      .proxies
      | to_entries[]
      | select(.value.now? and (.value.now | type == "string"))
      | .value.now
    ) // empty
  ' | grep -Ev '^(DIRECT|REJECT|GLOBAL)$' | head -n 1 || true)
fi
if [[ -z "$selected_node" || "$selected_node" == "null" ]]; then
  selected_node=$(printf '%s' "$proxies_json" | jq -r '
      .proxies
      | to_entries[]
      | select(.value.type? and (.value.type | test("Selector|URLTest|Fallback|LoadBalance") | not))
      | .key
    ' | grep -Ev '^(DIRECT|REJECT|GLOBAL)$' | head -n 1 || true)
fi

if [[ -z "$selected_node" || "$selected_node" == "null" ]]; then
  printf '{"mode":"router","checkedAtShanghai":"%s","checkedAtEpoch":%s,"error":"%s","sites":[]}\n' \
    "$(escape_json "$checked_at")" \
    "$now_epoch" \
    "no proxy nodes found"
  exit 0
fi

probe_site_by_node() {
  local key="$1"
  local name="$2"
  local url="$3"
  local node="$4"
  local node_enc
  local url_enc
  local delay=-1
  local reachable=false
  local err=""
  local resp=""
  local delay_url

  node_enc=$(jq -rn --arg v "$node" '$v|@uri')
  url_enc=$(jq -rn --arg v "$url" '$v|@uri')
  delay_url="${api_base}/proxies/${node_enc}/delay?timeout=${timeout_ms}&url=${url_enc}"

  if resp=$(api_curl "$delay_url" 2>&1); then
    delay=$(printf '%s' "$resp" | jq -r '.delay // -1')
    if [[ "$delay" =~ ^[0-9]+$ ]] && [[ "$delay" -ge 0 ]]; then
      reachable=true
    fi
  else
    err="$resp"
  fi

  printf '{"key":"%s","name":"%s","url":"%s","reachable":%s,"httpCode":"%s","latencyMs":%s,"error":"%s"}' \
    "$(escape_json "$key")" \
    "$(escape_json "$name")" \
    "$(escape_json "$url")" \
    "$reachable" \
    "-" \
    "$delay" \
    "$(escape_json "$err")"
}

yt=$(probe_site_by_node "youtube" "YouTube" "$test_url_youtube" "$selected_node")
gh=$(probe_site_by_node "github" "GitHub" "$test_url_github" "$selected_node")
tm=$(probe_site_by_node "tmdb" "TMDB" "$test_url_tmdb" "$selected_node")
bd=$(probe_site_by_node "baidu" "百度" "$test_url_baidu" "$selected_node")

printf '{"mode":"router","viaNode":"%s","checkedAtShanghai":"%s","checkedAtEpoch":%s,"sites":[%s,%s,%s,%s]}\n' \
  "$(escape_json "$selected_node")" \
  "$(escape_json "$checked_at")" \
  "$now_epoch" \
  "$yt" "$gh" "$tm" "$bd"
