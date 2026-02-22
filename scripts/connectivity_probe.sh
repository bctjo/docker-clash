#!/bin/bash
set -euo pipefail

escape_json() {
  printf '%s' "$1" | awk 'BEGIN{RS=""; ORS=""} {gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); gsub(/\r/,"\\r"); gsub(/\n/,"\\n"); print}'
}

probe_site() {
  local key="$1"
  local name="$2"
  local url="$3"
  local output
  local code
  local total
  local latency_ms
  local reachable=false
  local error_msg=""
  local rc=0

  output=$(curl -L -sS -o /dev/null --connect-timeout 5 --max-time 20 -w "%{http_code} %{time_total}" "$url" 2>&1) || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    code=$(printf '%s' "$output" | awk '{print $1}')
    total=$(printf '%s' "$output" | awk '{print $2}')
    latency_ms=$(awk "BEGIN{printf \"%d\", $total*1000}")
    if [[ "$code" =~ ^[23] ]]; then
      reachable=true
    fi
  else
    code="000"
    latency_ms=-1
    error_msg="$output"
  fi

  printf '{"key":"%s","name":"%s","url":"%s","reachable":%s,"httpCode":"%s","latencyMs":%s,"error":"%s"}' \
    "$(escape_json "$key")" \
    "$(escape_json "$name")" \
    "$(escape_json "$url")" \
    "$reachable" \
    "$(escape_json "$code")" \
    "$latency_ms" \
    "$(escape_json "$error_msg")"
}

now_epoch=$(date +%s)
checked_at=$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S')

yt=$(probe_site "youtube" "YouTube" "https://www.youtube.com/generate_204")
gh=$(probe_site "github" "GitHub" "https://github.com/")
tmdb=$(probe_site "tmdb" "TMDB" "https://www.themoviedb.org/")
bd=$(probe_site "baidu" "百度" "https://www.baidu.com/")

printf '{"checkedAtShanghai":"%s","checkedAtEpoch":%s,"sites":[%s,%s,%s,%s]}\n' \
  "$(escape_json "$checked_at")" \
  "$now_epoch" \
  "$yt" "$gh" "$tmdb" "$bd"
