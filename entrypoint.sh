#!/bin/bash
set -e

# ========= 基础端口配置 & 变量 =========
PORTAL_PORT=${PORTAL_PORT:-9090}
DASH_PORT=${DASH_PORT:-9097}
CLASH_HTTP_PORT=${CLASH_HTTP_PORT:-7890}
CLASH_SOCKS_PORT=${CLASH_SOCKS_PORT:-7891}
CLASH_TPROXY_PORT=${CLASH_TPROXY_PORT:-7892}
CLASH_MIXED_PORT=${CLASH_MIXED_PORT:-7893}
CLASH_SECRET=${CLASH_SECRET:-}
SUBSCR_UA=${SUBSCR_UA:-ClashMeta}
SUBSCR_CONNECT_TIMEOUT=${SUBSCR_CONNECT_TIMEOUT:-15}
SUBSCR_VALIDATE_MAX_TIME=${SUBSCR_VALIDATE_MAX_TIME:-120}
SUBSCR_DOWNLOAD_MAX_TIME=${SUBSCR_DOWNLOAD_MAX_TIME:-120}
SUBSCR_RETRY=${SUBSCR_RETRY:-2}
SUBSCR_RETRY_DELAY=${SUBSCR_RETRY_DELAY:-2}
PORTAL_ADMIN_KEY=${PORTAL_ADMIN_KEY:-}
# 更新间隔，默认 12 小时 (43200 秒)
UPDATE_INTERVAL=${UPDATE_INTERVAL:-43200}

CONFIG_DIR="/root/.config/clash"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
MMDB_FILE="$CONFIG_DIR/Country.mmdb"
GEOSITE_FILE="$CONFIG_DIR/GeoSite.dat"
GEOIP_FILE="$CONFIG_DIR/GeoIP.dat"
TMP_DIR="/tmp/subs"
MMDB_URL="https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/country.mmdb"
GEOSITE_URL="${GEOSITE_URL:-https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat}"
GEOIP_URL="${GEOIP_URL:-https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.dat}"
GEODATA_MAX_AGE="${GEODATA_MAX_AGE:-604800}"
GEODATA_AUTO_UPDATE="${GEODATA_AUTO_UPDATE:-true}"
CONFIG_TEST_MAX_RETRY="${CONFIG_TEST_MAX_RETRY:-1}"
PORTAL_CONF="/etc/nginx/conf.d/portal.conf"
PORTAL_CONF_TEMPLATE="/etc/nginx/conf.d/portal.conf.template"
PORTAL_CONFIG="/opt/portal/config.js"
PORTAL_STATUS_FILE="$CONFIG_DIR/status.json"
PORTAL_STATUS_PUBLIC="/opt/portal/status.json"
SUBSCRIPTION_INFO_FILE="$CONFIG_DIR/subscription-info.json"
SUBSCRIPTION_INFO_PUBLIC="/opt/portal/subscription-info.json"
PORTAL_LATENCY_BROWSER_FILE="$CONFIG_DIR/latency-browser.json"
PORTAL_LATENCY_BROWSER_PUBLIC="/opt/portal/latency-browser.json"
PORTAL_LATENCY_ROUTER_FILE="$CONFIG_DIR/latency-router.json"
PORTAL_LATENCY_ROUTER_PUBLIC="/opt/portal/latency-router.json"
SETTINGS_FILE="$CONFIG_DIR/settings.json"
SETTINGS_PUBLIC="/opt/portal/settings.json"
SUBSCRIPTIONS_FILE="$CONFIG_DIR/subscriptions.json"
SUBSCRIPTIONS_PUBLIC="/opt/portal/subscriptions.json"
SUBS_CACHE_DIR="$CONFIG_DIR/proxies"
PORTAL_AUTH_FILE="/etc/nginx/.portal_htpasswd"
PORTAL_UPDATE_TRIGGER="/opt/portal/update"
PORTAL_LATENCY_BROWSER_TRIGGER="/opt/portal/latency-browser-refresh"
PORTAL_LATENCY_ROUTER_TRIGGER="/opt/portal/latency-router-refresh"
PORTAL_SUB_VALIDATE_TRIGGER="/opt/portal/subscription-validate"
PORTAL_SUB_VALIDATE_RESULT_FILE="$CONFIG_DIR/subscription-validate.json"
PORTAL_SUB_VALIDATE_RESULT_PUBLIC="/opt/portal/subscription-validate.json"
PORTAL_STATE_FILE="$CONFIG_DIR/portal.json"
DEBUG_RAW_CONFIG="$CONFIG_DIR/config.raw.yaml"
LATENCY_BROWSER_PROBE_SCRIPT="/opt/scripts/connectivity_probe.sh"
LATENCY_ROUTER_PROBE_SCRIPT="/opt/scripts/proxy_connectivity_probe.sh"
BUILTIN_RULE_FILE="${BUILTIN_RULE_FILE:-/opt/builtin-rules.yaml}"
IMAGE_GEODATA_DIR="${IMAGE_GEODATA_DIR:-/opt/geodata}"
FIRST_START_MARKER="$CONFIG_DIR/.first-start.done"
CURRENT_ACTIVE_INDEX=0

mkdir -p "$CONFIG_DIR" "$TMP_DIR"
mkdir -p "$SUBS_CACHE_DIR"

# ========= 函数：日志 =========
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [entrypoint] $1"
}

ensure_public_file_readable() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    chmod 644 "$file" || true
    chown www-data:www-data "$file" 2>/dev/null || true
}

curl_subscription() {
    local url="$1"
    local header_file="$2"
    local output_file="$3"
    local max_time="$4"

    if [[ -n "$SUBSCR_UA" ]]; then
        curl -fsSL \
            --retry "$SUBSCR_RETRY" \
            --retry-delay "$SUBSCR_RETRY_DELAY" \
            --retry-max-time "$max_time" \
            --connect-timeout "$SUBSCR_CONNECT_TIMEOUT" \
            --max-time "$max_time" \
            -A "$SUBSCR_UA" \
            -D "$header_file" \
            "$url" \
            -o "$output_file"
    else
        curl -fsSL \
            --retry "$SUBSCR_RETRY" \
            --retry-delay "$SUBSCR_RETRY_DELAY" \
            --retry-max-time "$max_time" \
            --connect-timeout "$SUBSCR_CONNECT_TIMEOUT" \
            --max-time "$max_time" \
            -D "$header_file" \
            "$url" \
            -o "$output_file"
    fi
}

# ========= 函数：下载文件（带超时/重试/过期检查） =========
download_with_fallback() {
    local file="$1"
    local label="$2"
    shift 2
    local url
    local max_time=60

    if [[ "$label" == "GeoIP.dat" ]]; then
        max_time=180
    fi

    for url in "$@"; do
        if [[ -z "$url" ]]; then
            continue
        fi
        log "Downloading $label from: $url"
        if curl -fsSL --retry 2 --retry-delay 2 --connect-timeout 10 --max-time "$max_time" "$url" -o "$file.tmp"; then
            if [[ ! -s "$file.tmp" ]]; then
                log "WARNING: $label download empty from $url."
                rm -f "$file.tmp"
                continue
            fi
            mv "$file.tmp" "$file"
            log "$label updated."
            return 0
        fi
    done
    log "WARNING: Failed to download $label from all sources."
    rm -f "$file.tmp"
    return 1
}

download_if_stale() {
    local file="$1"
    local max_age="$2"
    local label="$3"
    shift 3
    local now_ts
    local mtime=0

    now_ts=$(date +%s)
    if [[ -f "$file" ]]; then
        mtime=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file")
    fi
    if [[ -f "$file" && $((now_ts - mtime)) -lt "$max_age" ]]; then
        log "$label is fresh. Skip download."
        return 0
    fi

    download_with_fallback "$file" "$label" "$@"
}

is_geodata_auto_update_enabled() {
    case "${GEODATA_AUTO_UPDATE,,}" in
        1|true|yes|on)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

seed_geodata_from_image() {
    local seeded=0

    [[ -d "$IMAGE_GEODATA_DIR" ]] || return 0

    if [[ ! -s "$MMDB_FILE" && -s "$IMAGE_GEODATA_DIR/Country.mmdb" ]]; then
        cp "$IMAGE_GEODATA_DIR/Country.mmdb" "$MMDB_FILE"
        log "Seeded Country.mmdb from image."
        seeded=1
    fi
    if [[ ! -s "$GEOSITE_FILE" && -s "$IMAGE_GEODATA_DIR/GeoSite.dat" ]]; then
        cp "$IMAGE_GEODATA_DIR/GeoSite.dat" "$GEOSITE_FILE"
        log "Seeded GeoSite.dat from image."
        seeded=1
    fi
    if [[ ! -s "$GEOIP_FILE" && -s "$IMAGE_GEODATA_DIR/GeoIP.dat" ]]; then
        cp "$IMAGE_GEODATA_DIR/GeoIP.dat" "$GEOIP_FILE"
        log "Seeded GeoIP.dat from image."
        seeded=1
    fi

    if [[ "$seeded" -eq 1 ]]; then
        chmod 644 "$MMDB_FILE" "$GEOSITE_FILE" "$GEOIP_FILE" 2>/dev/null || true
    fi
}

# ========= 函数：生成 Secret 并持久化 =========
generate_secret() {
    local secret
    secret=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 8)
    printf '%s' "$secret"
}

ensure_secret() {
    if [[ -n "$CLASH_SECRET" ]]; then
        return
    fi
    if [[ -f "$PORTAL_STATE_FILE" ]]; then
        CLASH_SECRET=$(sed -n 's/.*"secret"[[:space:]]*:[[:space:]]*"\([^\"]*\)".*/\1/p' "$PORTAL_STATE_FILE" | head -n 1)
    fi
    if [[ -z "$CLASH_SECRET" ]]; then
        CLASH_SECRET=$(generate_secret)
        cat > "$PORTAL_STATE_FILE" <<EOF
{"secret":"$CLASH_SECRET"}
EOF
    fi
}

# ========= 函数：生成 Portal 配置 =========
escape_js() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

escape_json() {
    printf '%s' "$1" | awk 'BEGIN{RS=""; ORS=""} {gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); gsub(/\r/,"\\r"); gsub(/\n/,"\\n"); print}'
}

decode_percent_text() {
    local text="$1"
    local escaped=""
    local decoded=""
    if [[ "$text" != *%* ]]; then
        printf '%s' "$text"
        return 0
    fi
    escaped=$(printf '%s' "$text" | sed -E 's/%([0-9A-Fa-f]{2})/\\x\1/g')
    decoded=$(printf '%b' "$escaped" 2>/dev/null || true)
    if [[ -n "$decoded" ]]; then
        printf '%s' "$decoded"
    else
        printf '%s' "$text"
    fi
}

write_portal_config() {
    local DASH_PORT_ESC
    local PORTAL_PORT_ESC
    local HTTP_PORT_ESC
    local SOCKS_PORT_ESC
    local TPROXY_PORT_ESC
    local MIXED_PORT_ESC
    local SECRET_ESC
    local UPDATE_INTERVAL_ESC
    local ADMIN_AUTH_ENABLED

    DASH_PORT_ESC=$(escape_js "$DASH_PORT")
    PORTAL_PORT_ESC=$(escape_js "$PORTAL_PORT")
    HTTP_PORT_ESC=$(escape_js "$CLASH_HTTP_PORT")
    SOCKS_PORT_ESC=$(escape_js "$CLASH_SOCKS_PORT")
    TPROXY_PORT_ESC=$(escape_js "$CLASH_TPROXY_PORT")
    MIXED_PORT_ESC=$(escape_js "$CLASH_MIXED_PORT")
    SECRET_ESC=$(escape_js "$CLASH_SECRET")
    UPDATE_INTERVAL_ESC=$(escape_js "$UPDATE_INTERVAL")
    ADMIN_AUTH_ENABLED="false"
    if [[ -n "$PORTAL_ADMIN_KEY" ]]; then
        ADMIN_AUTH_ENABLED="true"
    fi

    cat > "$PORTAL_CONFIG" <<EOF
window.__PORTAL_CONFIG__ = {
  dashPort: "$DASH_PORT_ESC",
  portalPort: "$PORTAL_PORT_ESC",
  httpPort: "$HTTP_PORT_ESC",
  socksPort: "$SOCKS_PORT_ESC",
  tproxyPort: "$TPROXY_PORT_ESC",
  mixedPort: "$MIXED_PORT_ESC",
  secret: "$SECRET_ESC",
  updateIntervalSec: "$UPDATE_INTERVAL_ESC",
  adminAuthEnabled: $ADMIN_AUTH_ENABLED
};
EOF
}

write_subscriptions_file() {
    local urls_csv="$1"
    local active="${2:-0}"
    local -a urls=()

    if [[ -z "$urls_csv" ]]; then
        return 1
    fi

    IFS=',' read -ra urls <<< "$urls_csv"
    if [[ ${#urls[@]} -eq 0 ]]; then
        return 1
    fi

    mkdir -p "$CONFIG_DIR"
    {
        printf '{"active":%s,"urls":[' "$active"
        local first=1
        for url in "${urls[@]}"; do
            if [[ -z "$url" ]]; then
                continue
            fi
            if [[ $first -eq 0 ]]; then
                printf ','
            fi
            first=0
            printf '"%s"' "$(escape_json "$url")"
        done
        printf ']}'
    } > "$SUBSCRIPTIONS_FILE"
    cp "$SUBSCRIPTIONS_FILE" "$SUBSCRIPTIONS_PUBLIC"
    ensure_public_file_readable "$SUBSCRIPTIONS_PUBLIC"
}

init_subscriptions() {
    if [[ -f "$SUBSCRIPTIONS_PUBLIC" ]]; then
        cp "$SUBSCRIPTIONS_PUBLIC" "$SUBSCRIPTIONS_FILE"
        ensure_public_file_readable "$SUBSCRIPTIONS_PUBLIC"
        return
    fi
    if [[ -f "$SUBSCRIPTIONS_FILE" ]]; then
        cp "$SUBSCRIPTIONS_FILE" "$SUBSCRIPTIONS_PUBLIC"
        ensure_public_file_readable "$SUBSCRIPTIONS_PUBLIC"
        return
    fi
    if [[ -n "$SUBSCR_URLS" ]]; then
        write_subscriptions_file "$SUBSCR_URLS" 0
        return
    fi
    # 保证 Portal 首次启动也能读取到有效 JSON，避免前端因 404 卡在读取状态
    printf '{"active":0,"urls":[]}\n' > "$SUBSCRIPTIONS_FILE"
    cp "$SUBSCRIPTIONS_FILE" "$SUBSCRIPTIONS_PUBLIC"
    ensure_public_file_readable "$SUBSCRIPTIONS_PUBLIC"
}

load_subscriptions() {
    local source="$SUBSCRIPTIONS_PUBLIC"
    local active
    local -a parsed_urls=()
    local -a cleaned_urls=()
    local -a unique_urls=()
    local url
    local existing
    local normalized_url
    local duplicate
    local idx
    local parsed_active=0

    SUBS_URLS_ARRAY=()
    SUBS_NAMES_ARRAY=()
    SUBS_UPDATED_ARRAY=()
    SUBS_ERRORS_ARRAY=()
    SUBS_INFO_HAS_ARRAY=()
    SUBS_INFO_TOTAL_ARRAY=()
    SUBS_INFO_UPLOAD_ARRAY=()
    SUBS_INFO_DOWNLOAD_ARRAY=()
    SUBS_INFO_USED_ARRAY=()
    SUBS_INFO_REMAINING_ARRAY=()
    SUBS_INFO_USED_PERCENT_ARRAY=()
    SUBS_INFO_EXPIRE_TS_ARRAY=()
    SUBS_INFO_EXPIRE_SH_ARRAY=()
    SUBS_INFO_MSG_ARRAY=()

    if [[ -f "$source" ]]; then
        cp "$source" "$SUBSCRIPTIONS_FILE"
    elif [[ -f "$SUBSCRIPTIONS_FILE" ]]; then
        source="$SUBSCRIPTIONS_FILE"
        cp "$SUBSCRIPTIONS_FILE" "$SUBSCRIPTIONS_PUBLIC"
    else
        return 1
    fi

    # 优先使用 jq 严格解析，避免 items/name 等字段被误识别为 URL。
    active=$(jq -r 'if (.active|type)=="number" then .active else 0 end' "$source" 2>/dev/null || true)
    mapfile -t parsed_urls < <(jq -r '(.urls // []) | map(select(type=="string"))[]' "$source" 2>/dev/null || true)
    if [[ ${#parsed_urls[@]} -eq 0 ]]; then
        mapfile -t parsed_urls < <(jq -r '(.items // []) | map(select(type=="object" and (.url|type=="string"))) | .[].url' "$source" 2>/dev/null || true)
    fi

    if [[ ${#parsed_urls[@]} -eq 0 ]]; then
        return 1
    fi

    for url in "${parsed_urls[@]}"; do
        url="$(printf '%s' "$url" | tr -d '\r\n')"
        [[ -n "$url" ]] || continue
        if [[ "$url" =~ ^https?:// ]]; then
            cleaned_urls+=("$url")
        fi
    done

    if [[ ${#cleaned_urls[@]} -eq 0 ]]; then
        return 1
    fi

    for url in "${cleaned_urls[@]}"; do
        normalized_url="${url%/}"
        duplicate=0
        for existing in "${unique_urls[@]}"; do
            if [[ "${existing%/}" == "$normalized_url" ]]; then
                duplicate=1
                break
            fi
        done
        if [[ "$duplicate" -eq 0 ]]; then
            unique_urls+=("$url")
        fi
    done

    if [[ ${#unique_urls[@]} -eq 0 ]]; then
        return 1
    fi

    SUBS_URLS_ARRAY=("${unique_urls[@]}")

    if [[ "$active" =~ ^[0-9]+$ ]]; then
        parsed_active="$active"
    fi
    if [[ "$parsed_active" -lt 0 || "$parsed_active" -ge "${#SUBS_URLS_ARRAY[@]}" ]]; then
        parsed_active=0
    fi
    ACTIVE_SUB_INDEX="$parsed_active"

    for idx in "${!SUBS_URLS_ARRAY[@]}"; do
        SUBS_NAMES_ARRAY[$idx]=$(jq -r --argjson i "$idx" '.items[$i].name // empty' "$source" 2>/dev/null || true)
        SUBS_UPDATED_ARRAY[$idx]=$(jq -r --argjson i "$idx" '.items[$i].updatedAtShanghai // .items[$i].checkedAtShanghai // empty' "$source" 2>/dev/null || true)
        SUBS_ERRORS_ARRAY[$idx]=$(jq -r --argjson i "$idx" '.items[$i].lastError // empty' "$source" 2>/dev/null || true)
        SUBS_INFO_HAS_ARRAY[$idx]=$(jq -r --argjson i "$idx" '.items[$i].subscriptionInfo.hasInfo // "false"' "$source" 2>/dev/null || echo "false")
        SUBS_INFO_TOTAL_ARRAY[$idx]=$(jq -r --argjson i "$idx" '.items[$i].subscriptionInfo.totalBytes // 0' "$source" 2>/dev/null || echo "0")
        SUBS_INFO_UPLOAD_ARRAY[$idx]=$(jq -r --argjson i "$idx" '.items[$i].subscriptionInfo.uploadBytes // 0' "$source" 2>/dev/null || echo "0")
        SUBS_INFO_DOWNLOAD_ARRAY[$idx]=$(jq -r --argjson i "$idx" '.items[$i].subscriptionInfo.downloadBytes // 0' "$source" 2>/dev/null || echo "0")
        SUBS_INFO_USED_ARRAY[$idx]=$(jq -r --argjson i "$idx" '.items[$i].subscriptionInfo.usedBytes // 0' "$source" 2>/dev/null || echo "0")
        SUBS_INFO_REMAINING_ARRAY[$idx]=$(jq -r --argjson i "$idx" '.items[$i].subscriptionInfo.remainingBytes // 0' "$source" 2>/dev/null || echo "0")
        SUBS_INFO_USED_PERCENT_ARRAY[$idx]=$(jq -r --argjson i "$idx" '.items[$i].subscriptionInfo.usedPercent // 0' "$source" 2>/dev/null || echo "0")
        SUBS_INFO_EXPIRE_TS_ARRAY[$idx]=$(jq -r --argjson i "$idx" '.items[$i].subscriptionInfo.expireTs // 0' "$source" 2>/dev/null || echo "0")
        SUBS_INFO_EXPIRE_SH_ARRAY[$idx]=$(jq -r --argjson i "$idx" '.items[$i].subscriptionInfo.expireAtShanghai // "-"' "$source" 2>/dev/null || echo "-")
        SUBS_INFO_MSG_ARRAY[$idx]=$(jq -r --argjson i "$idx" '.items[$i].subscriptionInfo.message // "subscription-userinfo not found"' "$source" 2>/dev/null || echo "subscription-userinfo not found")
        if [[ -z "${SUBS_NAMES_ARRAY[$idx]}" ]]; then
            SUBS_NAMES_ARRAY[$idx]=$(derive_subscription_name "${SUBS_URLS_ARRAY[$idx]}" "")
        fi
    done

    SUBSCR_URLS=$(IFS=','; printf '%s' "${SUBS_URLS_ARRAY[*]}")
    return 0
}

write_subscriptions_state() {
    local target="${1:-$SUBSCRIPTIONS_FILE}"
    local tmp_file="${target}.tmp"
    local tmp_public="${SUBSCRIPTIONS_PUBLIC}.tmp"
    local idx
    local total="${#SUBS_URLS_ARRAY[@]}"
    local active="${ACTIVE_SUB_INDEX:-0}"

    if [[ "$active" -lt 0 || "$active" -ge "$total" ]]; then
        active=0
    fi

    {
        printf '{"active":%s,"urls":[' "$active"
        for idx in "${!SUBS_URLS_ARRAY[@]}"; do
            [[ "$idx" -gt 0 ]] && printf ','
            printf '"%s"' "$(escape_json "${SUBS_URLS_ARRAY[$idx]}")"
        done
        printf '],"items":['
        for idx in "${!SUBS_URLS_ARRAY[@]}"; do
            [[ "$idx" -gt 0 ]] && printf ','
            printf '{"name":"%s","url":"%s","updatedAtShanghai":"%s","lastError":"%s","subscriptionInfo":{"hasInfo":%s,"totalBytes":%s,"uploadBytes":%s,"downloadBytes":%s,"usedBytes":%s,"remainingBytes":%s,"usedPercent":%s,"expireTs":%s,"expireAtShanghai":"%s","message":"%s"}}' \
                "$(escape_json "${SUBS_NAMES_ARRAY[$idx]}")" \
                "$(escape_json "${SUBS_URLS_ARRAY[$idx]}")" \
                "$(escape_json "${SUBS_UPDATED_ARRAY[$idx]}")" \
                "$(escape_json "${SUBS_ERRORS_ARRAY[$idx]}")" \
                "${SUBS_INFO_HAS_ARRAY[$idx]:-false}" \
                "${SUBS_INFO_TOTAL_ARRAY[$idx]:-0}" \
                "${SUBS_INFO_UPLOAD_ARRAY[$idx]:-0}" \
                "${SUBS_INFO_DOWNLOAD_ARRAY[$idx]:-0}" \
                "${SUBS_INFO_USED_ARRAY[$idx]:-0}" \
                "${SUBS_INFO_REMAINING_ARRAY[$idx]:-0}" \
                "${SUBS_INFO_USED_PERCENT_ARRAY[$idx]:-0}" \
                "${SUBS_INFO_EXPIRE_TS_ARRAY[$idx]:-0}" \
                "$(escape_json "${SUBS_INFO_EXPIRE_SH_ARRAY[$idx]:--}")" \
                "$(escape_json "${SUBS_INFO_MSG_ARRAY[$idx]:-subscription-userinfo not found}")"
        done
        printf ']}'
    } > "$tmp_file"

    mv "$tmp_file" "$target"
    cp "$target" "$tmp_public"
    mv "$tmp_public" "$SUBSCRIPTIONS_PUBLIC"
    ensure_public_file_readable "$SUBSCRIPTIONS_PUBLIC"
}

subscription_cache_file_by_index() {
    local idx="$1"
    local url="${SUBS_URLS_ARRAY[$idx]:-}"
    local hash
    if [[ -z "$url" ]]; then
        return 1
    fi
    hash=$(printf '%s' "$url" | md5sum | awk '{print $1}')
    printf '%s/%s' "$SUBS_CACHE_DIR" "$hash"
}

subscriptions_signature() {
    local raw=""
    local url
    raw="${ACTIVE_SUB_INDEX}|"
    for url in "${SUBS_URLS_ARRAY[@]}"; do
        raw="${raw}${url}||"
    done
    printf '%s' "$raw" | md5sum | awk '{print $1}'
}

wait_for_subscriptions() {
    if load_subscriptions; then
        return 0
    fi
    log "No subscriptions configured. Waiting for portal input..."
    while true; do
        sleep 2
        if load_subscriptions; then
            log "Subscriptions configured. Initializing..."
            return 0
        fi
    done
}

write_portal_status() {
    local now
    local tmp_file
    local tmp_public
    now=$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S')
    mkdir -p "$CONFIG_DIR"
    tmp_file="${PORTAL_STATUS_FILE}.tmp"
    tmp_public="${PORTAL_STATUS_PUBLIC}.tmp"
    printf '{"lastUpdateShanghai":"%s"}\n' "$now" > "$tmp_file"
    mv "$tmp_file" "$PORTAL_STATUS_FILE"
    cp "$PORTAL_STATUS_FILE" "$tmp_public"
    mv "$tmp_public" "$PORTAL_STATUS_PUBLIC"
    ensure_public_file_readable "$PORTAL_STATUS_PUBLIC"
}

write_subscription_info_json() {
    local has_info="$1"
    local total="$2"
    local upload="$3"
    local download="$4"
    local used="$5"
    local remaining="$6"
    local used_percent="$7"
    local expire_ts="$8"
    local expire_shanghai="$9"
    local message="${10}"
    local now
    local tmp_file
    local tmp_public

    now=$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S')
    tmp_file="${SUBSCRIPTION_INFO_FILE}.tmp"
    tmp_public="${SUBSCRIPTION_INFO_PUBLIC}.tmp"

    cat > "$tmp_file" <<EOF
{"hasInfo":$has_info,"totalBytes":$total,"uploadBytes":$upload,"downloadBytes":$download,"usedBytes":$used,"remainingBytes":$remaining,"usedPercent":$used_percent,"expireTs":$expire_ts,"expireAtShanghai":"$(escape_json "$expire_shanghai")","updatedAtShanghai":"$now","message":"$(escape_json "$message")"}
EOF
    mv "$tmp_file" "$SUBSCRIPTION_INFO_FILE"
    cp "$SUBSCRIPTION_INFO_FILE" "$tmp_public"
    mv "$tmp_public" "$SUBSCRIPTION_INFO_PUBLIC"
    ensure_public_file_readable "$SUBSCRIPTION_INFO_PUBLIC"
}

cache_subscription_info_unknown_for_index() {
    local idx="$1"
    local message="${2:-subscription-userinfo not found}"
    SUBS_INFO_HAS_ARRAY[$idx]="false"
    SUBS_INFO_TOTAL_ARRAY[$idx]=0
    SUBS_INFO_UPLOAD_ARRAY[$idx]=0
    SUBS_INFO_DOWNLOAD_ARRAY[$idx]=0
    SUBS_INFO_USED_ARRAY[$idx]=0
    SUBS_INFO_REMAINING_ARRAY[$idx]=0
    SUBS_INFO_USED_PERCENT_ARRAY[$idx]=0
    SUBS_INFO_EXPIRE_TS_ARRAY[$idx]=0
    SUBS_INFO_EXPIRE_SH_ARRAY[$idx]="-"
    SUBS_INFO_MSG_ARRAY[$idx]="$message"
}

write_subscription_info_unknown() {
    local message="${1:-subscription-userinfo not found}"
    write_subscription_info_json "false" 0 0 0 0 0 0 0 "-" "$message"
}

write_subscription_info_from_cache_index() {
    local idx="$1"
    if [[ -z "$idx" || "$idx" -lt 0 || "$idx" -ge "${#SUBS_URLS_ARRAY[@]}" ]]; then
        return 1
    fi
    write_subscription_info_json \
        "${SUBS_INFO_HAS_ARRAY[$idx]:-false}" \
        "${SUBS_INFO_TOTAL_ARRAY[$idx]:-0}" \
        "${SUBS_INFO_UPLOAD_ARRAY[$idx]:-0}" \
        "${SUBS_INFO_DOWNLOAD_ARRAY[$idx]:-0}" \
        "${SUBS_INFO_USED_ARRAY[$idx]:-0}" \
        "${SUBS_INFO_REMAINING_ARRAY[$idx]:-0}" \
        "${SUBS_INFO_USED_PERCENT_ARRAY[$idx]:-0}" \
        "${SUBS_INFO_EXPIRE_TS_ARRAY[$idx]:-0}" \
        "${SUBS_INFO_EXPIRE_SH_ARRAY[$idx]:--}" \
        "${SUBS_INFO_MSG_ARRAY[$idx]:-subscription-userinfo not found}"
}

write_subscription_validate_result() {
    local ok="$1"
    local url="$2"
    local name="$3"
    local message="$4"
    local request_id="$5"
    local info_json="${6:-}"
    local updated_at="${7:-}"
    local now
    local tmp_file
    local tmp_public

    now=$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S')
    if [[ -z "$updated_at" ]]; then
        updated_at="$now"
    fi
    if [[ -z "$info_json" ]]; then
        info_json="null"
    fi
    tmp_file="${PORTAL_SUB_VALIDATE_RESULT_FILE}.tmp"
    tmp_public="${PORTAL_SUB_VALIDATE_RESULT_PUBLIC}.tmp"

    cat > "$tmp_file" <<EOF
{"ok":$ok,"url":"$(escape_json "$url")","name":"$(escape_json "$name")","message":"$(escape_json "$message")","requestId":"$(escape_json "$request_id")","checkedAtShanghai":"$now","updatedAtShanghai":"$(escape_json "$updated_at")","subscriptionInfo":$info_json}
EOF
    mv "$tmp_file" "$PORTAL_SUB_VALIDATE_RESULT_FILE"
    cp "$PORTAL_SUB_VALIDATE_RESULT_FILE" "$tmp_public"
    mv "$tmp_public" "$PORTAL_SUB_VALIDATE_RESULT_PUBLIC"
    ensure_public_file_readable "$PORTAL_SUB_VALIDATE_RESULT_PUBLIC"
}

derive_subscription_name() {
    local url="$1"
    local header_file="$2"
    local name=""
    local content_disposition=""

    if [[ -f "$header_file" ]]; then
        content_disposition=$(tr -d '\r' < "$header_file" | awk -F': ' 'tolower($1)=="content-disposition"{print $2; exit}')
        if [[ -n "$content_disposition" ]]; then
            name=$(printf '%s' "$content_disposition" | sed -n "s/.*filename\\*=UTF-8''\\([^;]*\\).*/\\1/p" | head -n 1)
            if [[ -z "$name" ]]; then
                name=$(printf '%s' "$content_disposition" | sed -n 's/.*filename="\([^"]*\)".*/\1/p' | head -n 1)
            fi
            if [[ -z "$name" ]]; then
                name=$(printf '%s' "$content_disposition" | sed -n 's/.*filename=\([^;]*\).*/\1/p' | head -n 1)
            fi
        fi
    fi

    if [[ -z "$name" ]]; then
        name=$(printf '%s' "$url" | sed -n 's#^[a-zA-Z]\+://\([^/:?]*\).*#\1#p' | head -n 1)
    fi
    # 清理并解码百分号编码名称（例如 %E8%B5%94%E9%92%B1%E6%9C%BA%E5%9C%BA）
    name=$(printf '%s' "$name" | sed 's/^ *//; s/ *$//; s/^"//; s/"$//; s/;$//')
    name=$(decode_percent_text "$name")
    name="${name%.yaml}"
    name="${name%.yml}"
    name="${name%.txt}"
    if [[ -z "$name" ]]; then
        name="订阅"
    fi
    printf '%s' "$name"
}

subscription_cache_file_for_url() {
    local url="$1"
    local hash
    if [[ -z "$url" ]]; then
        return 1
    fi
    hash=$(printf '%s' "$url" | md5sum | awk '{print $1}')
    printf '%s/%s' "$SUBS_CACHE_DIR" "$hash"
}

build_subscription_info_json_from_header() {
    local header_file="$1"
    local info_line total upload download used remaining used_percent
    local expire_ts expire_shanghai
    local message

    if [[ ! -f "$header_file" ]]; then
        message="subscription header file missing"
        printf '{"hasInfo":false,"totalBytes":0,"uploadBytes":0,"downloadBytes":0,"usedBytes":0,"remainingBytes":0,"usedPercent":0,"expireTs":0,"expireAtShanghai":"-","message":"%s"}' \
            "$(escape_json "$message")"
        return 0
    fi

    info_line=$(tr -d '\r' < "$header_file" | awk -F': ' 'tolower($1)=="subscription-userinfo"{print $2; exit}')
    if [[ -z "$info_line" ]]; then
        message="subscription-userinfo not provided by provider"
        printf '{"hasInfo":false,"totalBytes":0,"uploadBytes":0,"downloadBytes":0,"usedBytes":0,"remainingBytes":0,"usedPercent":0,"expireTs":0,"expireAtShanghai":"-","message":"%s"}' \
            "$(escape_json "$message")"
        return 0
    fi

    extract_num() {
        local key="$1"
        printf '%s' "$info_line" | grep -o "${key}=[0-9]\+" | head -n 1 | cut -d= -f2 || true
    }

    total=$(extract_num "total")
    upload=$(extract_num "upload")
    download=$(extract_num "download")
    expire_ts=$(extract_num "expire")

    [[ -n "$total" ]] || total=0
    [[ -n "$upload" ]] || upload=0
    [[ -n "$download" ]] || download=0
    [[ -n "$expire_ts" ]] || expire_ts=0

    used=$((upload + download))
    if [[ "$total" -gt 0 && "$used" -gt "$total" ]]; then
        used="$total"
    fi
    if [[ "$total" -gt "$used" ]]; then
        remaining=$((total - used))
    else
        remaining=0
    fi

    if [[ "$total" -gt 0 ]]; then
        used_percent=$(awk "BEGIN{printf \"%d\", ($used*100)/$total}")
        if [[ "$used_percent" -gt 100 ]]; then
            used_percent=100
        fi
    else
        used_percent=0
    fi

    if [[ "$expire_ts" -gt 0 ]]; then
        expire_shanghai=$(TZ=Asia/Shanghai date -d "@$expire_ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || TZ=Asia/Shanghai date -r "$expire_ts" '+%Y-%m-%d %H:%M:%S')
    else
        expire_shanghai="-"
    fi

    printf '{"hasInfo":true,"totalBytes":%s,"uploadBytes":%s,"downloadBytes":%s,"usedBytes":%s,"remainingBytes":%s,"usedPercent":%s,"expireTs":%s,"expireAtShanghai":"%s","message":"ok"}' \
        "$total" "$upload" "$download" "$used" "$remaining" "$used_percent" "$expire_ts" "$(escape_json "$expire_shanghai")"
}

validate_subscription_url() {
    local url="$1"
    local request_id="$2"
    local body_file="$TMP_DIR/validate-sub.body"
    local header_file="$TMP_DIR/validate-sub.headers"
    local decoded_file="$TMP_DIR/validate-sub.decoded"
    local name
    local curl_code=0
    local compact_body=""
    local cache_file=""
    local info_json=""
    local now_shanghai=""

    if [[ -z "$url" ]]; then
        write_subscription_validate_result "false" "$url" "" "订阅链接为空。" "$request_id"
        return 1
    fi
    if [[ ! "$url" =~ ^https?:// ]]; then
        write_subscription_validate_result "false" "$url" "" "订阅链接必须以 http:// 或 https:// 开头。" "$request_id"
        return 1
    fi

    rm -f "$body_file" "$header_file"
    if curl_subscription "$url" "$header_file" "$body_file" "$SUBSCR_VALIDATE_MAX_TIME"; then
        :
    else
        curl_code=$?
        write_subscription_validate_result "false" "$url" "" "订阅链接不可用（下载失败或超时，curl=$curl_code）。" "$request_id"
        return 1
    fi

    if [[ ! -s "$body_file" ]]; then
        write_subscription_validate_result "false" "$url" "" "订阅链接返回空内容。" "$request_id"
        return 1
    fi

    # 订阅内容有效性校验（仅下载成功还不够）
    # 支持：Clash YAML（proxies/proxy-providers）或常见节点链接列表（含 base64 形式）
    if grep -aEiq '(^|[[:space:]])(proxies|proxy-providers):' "$body_file"; then
        :
    elif grep -aEiq '(^|[\r\n])[[:space:]]*(vmess|vless|trojan|ss|ssr|hysteria2?|tuic)://' "$body_file"; then
        :
    else
        compact_body=$(tr -d '\r\n\t ' < "$body_file" 2>/dev/null || true)
        if [[ -n "$compact_body" && ${#compact_body} -ge 32 && "$compact_body" =~ ^[A-Za-z0-9+/=]+$ ]]; then
            if printf '%s' "$compact_body" | base64 -d > "$decoded_file" 2>/dev/null; then
                if grep -aEiq '(vmess|vless|trojan|ss|ssr|hysteria2?|tuic)://' "$decoded_file"; then
                    :
                elif grep -aEiq '(^|[[:space:]])(proxies|proxy-providers):' "$decoded_file"; then
                    :
                else
                    write_subscription_validate_result "false" "$url" "" "下载成功但内容不是可识别的订阅格式。" "$request_id"
                    return 1
                fi
            else
                write_subscription_validate_result "false" "$url" "" "下载成功但内容不是可识别的订阅格式。" "$request_id"
                return 1
            fi
        else
            write_subscription_validate_result "false" "$url" "" "下载成功但内容不是可识别的订阅格式。" "$request_id"
            return 1
        fi
    fi

    name=$(derive_subscription_name "$url" "$header_file")
    info_json=$(build_subscription_info_json_from_header "$header_file")
    now_shanghai=$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S')
    write_subscription_validate_result "true" "$url" "$name" "订阅链接校验通过。" "$request_id" "$info_json" "$now_shanghai"
    cache_file=$(subscription_cache_file_for_url "$url" 2>/dev/null || true)
    if [[ -n "$cache_file" ]]; then
        mkdir -p "$SUBS_CACHE_DIR"
        cp "$body_file" "$cache_file" 2>/dev/null || true
    fi
    return 0
}

update_subscription_info_from_header() {
    local header_file="$1"
    local idx="${2:-}"
    local write_global="${3:-true}"
    local info_line
    local total upload download used remaining used_percent
    local expire_ts expire_shanghai

    if [[ ! -f "$header_file" ]]; then
        if [[ -n "$idx" ]]; then
            cache_subscription_info_unknown_for_index "$idx" "subscription header file missing"
        fi
        if [[ "$write_global" == "true" ]]; then
            write_subscription_info_unknown "subscription header file missing"
        fi
        return 0
    fi

    info_line=$(tr -d '\r' < "$header_file" | awk -F': ' 'tolower($1)=="subscription-userinfo"{print $2; exit}')
    if [[ -z "$info_line" ]]; then
        if [[ -n "$idx" ]]; then
            cache_subscription_info_unknown_for_index "$idx" "subscription-userinfo not provided by provider"
        fi
        if [[ "$write_global" == "true" ]]; then
            write_subscription_info_unknown "subscription-userinfo not provided by provider"
        fi
        return 0
    fi

    extract_num() {
        local key="$1"
        printf '%s' "$info_line" | grep -o "${key}=[0-9]\+" | head -n 1 | cut -d= -f2 || true
    }

    total=$(extract_num "total")
    upload=$(extract_num "upload")
    download=$(extract_num "download")
    expire_ts=$(extract_num "expire")

    [[ -n "$total" ]] || total=0
    [[ -n "$upload" ]] || upload=0
    [[ -n "$download" ]] || download=0
    [[ -n "$expire_ts" ]] || expire_ts=0

    used=$((upload + download))
    if [[ "$total" -gt 0 && "$used" -gt "$total" ]]; then
        used="$total"
    fi
    if [[ "$total" -gt "$used" ]]; then
        remaining=$((total - used))
    else
        remaining=0
    fi

    if [[ "$total" -gt 0 ]]; then
        used_percent=$(awk "BEGIN{printf \"%d\", ($used*100)/$total}")
        if [[ "$used_percent" -gt 100 ]]; then
            used_percent=100
        fi
    else
        used_percent=0
    fi

    if [[ "$expire_ts" -gt 0 ]]; then
        expire_shanghai=$(TZ=Asia/Shanghai date -d "@$expire_ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || TZ=Asia/Shanghai date -r "$expire_ts" '+%Y-%m-%d %H:%M:%S')
    else
        expire_shanghai="-"
    fi

    if [[ -n "$idx" ]]; then
        SUBS_INFO_HAS_ARRAY[$idx]="true"
        SUBS_INFO_TOTAL_ARRAY[$idx]="$total"
        SUBS_INFO_UPLOAD_ARRAY[$idx]="$upload"
        SUBS_INFO_DOWNLOAD_ARRAY[$idx]="$download"
        SUBS_INFO_USED_ARRAY[$idx]="$used"
        SUBS_INFO_REMAINING_ARRAY[$idx]="$remaining"
        SUBS_INFO_USED_PERCENT_ARRAY[$idx]="$used_percent"
        SUBS_INFO_EXPIRE_TS_ARRAY[$idx]="$expire_ts"
        SUBS_INFO_EXPIRE_SH_ARRAY[$idx]="$expire_shanghai"
        SUBS_INFO_MSG_ARRAY[$idx]="ok"
    fi

    if [[ "$write_global" == "true" ]]; then
        write_subscription_info_json "true" "$total" "$upload" "$download" "$used" "$remaining" "$used_percent" "$expire_ts" "$expire_shanghai" "ok"
    fi
}

write_latency_error() {
    local mode="$1"
    local message="$2"
    local now_epoch
    local now
    local tmp_file
    local tmp_public
    local target_file
    local target_public

    now_epoch=$(date +%s)
    now=$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S')
    if [[ "$mode" == "router" ]]; then
        target_file="$PORTAL_LATENCY_ROUTER_FILE"
        target_public="$PORTAL_LATENCY_ROUTER_PUBLIC"
    else
        target_file="$PORTAL_LATENCY_BROWSER_FILE"
        target_public="$PORTAL_LATENCY_BROWSER_PUBLIC"
    fi
    tmp_file="${target_file}.tmp"
    tmp_public="${target_public}.tmp"

    cat > "$tmp_file" <<EOF
{"mode":"$mode","checkedAtShanghai":"$now","checkedAtEpoch":$now_epoch,"error":"$(escape_json "$message")","sites":[]}
EOF
    mv "$tmp_file" "$target_file"
    cp "$target_file" "$tmp_public"
    mv "$tmp_public" "$target_public"
    ensure_public_file_readable "$target_public"
}

write_latency_default() {
    local mode="$1"
    local now_epoch
    local now
    local tmp_file
    local tmp_public
    local target_file
    local target_public

    now_epoch=$(date +%s)
    now=$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S')
    if [[ "$mode" == "router" ]]; then
        target_file="$PORTAL_LATENCY_ROUTER_FILE"
        target_public="$PORTAL_LATENCY_ROUTER_PUBLIC"
    else
        target_file="$PORTAL_LATENCY_BROWSER_FILE"
        target_public="$PORTAL_LATENCY_BROWSER_PUBLIC"
    fi

    tmp_file="${target_file}.tmp"
    tmp_public="${target_public}.tmp"
    cat > "$tmp_file" <<EOF
{"mode":"$mode","checkedAtShanghai":"$now","checkedAtEpoch":$now_epoch,"error":"","sites":[{"key":"youtube","name":"YouTube","url":"https://www.youtube.com/generate_204","reachable":null,"httpCode":"-","latencyMs":-1,"error":""},{"key":"github","name":"GitHub","url":"https://github.com/","reachable":null,"httpCode":"-","latencyMs":-1,"error":""},{"key":"tmdb","name":"TMDB","url":"https://www.themoviedb.org/","reachable":null,"httpCode":"-","latencyMs":-1,"error":""},{"key":"baidu","name":"百度","url":"https://www.baidu.com/","reachable":null,"httpCode":"-","latencyMs":-1,"error":""}]}
EOF
    mv "$tmp_file" "$target_file"
    cp "$target_file" "$tmp_public"
    mv "$tmp_public" "$target_public"
    ensure_public_file_readable "$target_public"
}

refresh_latency_cache() {
    local mode="$1"
    local force="${2:-false}"
    local tmp_file
    local tmp_public
    local target_file
    local target_public
    local probe_script

    if [[ "$mode" == "router" ]]; then
        target_file="$PORTAL_LATENCY_ROUTER_FILE"
        target_public="$PORTAL_LATENCY_ROUTER_PUBLIC"
        probe_script="$LATENCY_ROUTER_PROBE_SCRIPT"
    else
        target_file="$PORTAL_LATENCY_BROWSER_FILE"
        target_public="$PORTAL_LATENCY_BROWSER_PUBLIC"
        probe_script="$LATENCY_BROWSER_PROBE_SCRIPT"
    fi

    if [[ ! -x "$probe_script" ]]; then
        write_latency_error "$mode" "latency probe script not found: $probe_script"
        return 1
    fi

    tmp_file="${target_file}.tmp"
    tmp_public="${target_public}.tmp"
    if DASH_PORT="$DASH_PORT" CLASH_SECRET="$CLASH_SECRET" "$probe_script" > "$tmp_file"; then
        mv "$tmp_file" "$target_file"
        cp "$target_file" "$tmp_public"
        mv "$tmp_public" "$target_public"
        ensure_public_file_readable "$target_public"
        return 0
    fi

    rm -f "$tmp_file"
    write_latency_error "$mode" "latency probe failed"
    return 1
}

# ========= 函数：处理 Portal 触发更新 =========
watch_portal_update() {
    while true; do
        if [[ -f "$PORTAL_UPDATE_TRIGGER" ]]; then
            local update_req_raw
            local update_scope
            update_req_raw=$(cat "$PORTAL_UPDATE_TRIGGER" 2>/dev/null || true)
            rm -f "$PORTAL_UPDATE_TRIGGER"
            update_scope=$(printf '%s' "$update_req_raw" | jq -r '.scope // empty' 2>/dev/null || true)
            if [[ "$update_scope" != "all" ]]; then
                update_scope="active"
            fi
            update_resources "update" "$update_scope"
        fi
        if [[ -f "$PORTAL_LATENCY_BROWSER_TRIGGER" ]]; then
            rm -f "$PORTAL_LATENCY_BROWSER_TRIGGER"
            refresh_latency_cache "browser" "true"
        fi
        if [[ -f "$PORTAL_LATENCY_ROUTER_TRIGGER" ]]; then
            rm -f "$PORTAL_LATENCY_ROUTER_TRIGGER"
            refresh_latency_cache "router" "true"
        fi
        if [[ -f "$PORTAL_SUB_VALIDATE_TRIGGER" ]]; then
            local req_raw
            local req_id
            local req_url
            req_raw=$(cat "$PORTAL_SUB_VALIDATE_TRIGGER" 2>/dev/null || true)
            rm -f "$PORTAL_SUB_VALIDATE_TRIGGER"
            req_id=$(printf '%s' "$req_raw" | jq -r '.requestId // empty' 2>/dev/null || true)
            req_url=$(printf '%s' "$req_raw" | jq -r '.url // empty' 2>/dev/null || true)
            if [[ -z "$req_url" ]]; then
                req_url=$(printf '%s' "$req_raw" | tr -d '\r\n')
            fi
            validate_subscription_url "$req_url" "$req_id" || true
        fi
        sleep 2
    done
}

init_settings() {
    local default_minutes
    if [[ -f "$SETTINGS_FILE" ]]; then
        cp "$SETTINGS_FILE" "$SETTINGS_PUBLIC"
        ensure_public_file_readable "$SETTINGS_PUBLIC"
        return
    fi
    default_minutes=$(awk "BEGIN{printf \"%.2f\", $UPDATE_INTERVAL/60}")
    cat > "$SETTINGS_FILE" <<EOF
{"autoEnabled":true,"intervalMinutes":$default_minutes,"builtinEnabled":true}
EOF
    cp "$SETTINGS_FILE" "$SETTINGS_PUBLIC"
    ensure_public_file_readable "$SETTINGS_PUBLIC"
}

read_settings() {
    local enabled
    local interval
    local builtin
    local source="$SETTINGS_PUBLIC"
    if [[ ! -f "$source" ]]; then
        source="$SETTINGS_FILE"
    fi
    enabled=$(sed -n 's/.*"autoEnabled"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p' "$source" | head -n 1)
    interval=$(sed -n 's/.*"intervalMinutes"[[:space:]]*:[[:space:]]*\([0-9.]*\).*/\1/p' "$source" | head -n 1)
    builtin=$(sed -n 's/.*"builtinEnabled"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p' "$source" | head -n 1)
    if [[ -z "$enabled" ]]; then
        enabled="true"
    fi
    if [[ -z "$interval" ]]; then
        interval=$(awk "BEGIN{printf \"%.2f\", $UPDATE_INTERVAL/60}")
    fi
    if [[ -z "$builtin" ]]; then
        builtin="true"
    fi
    printf '%s|%s|%s' "$enabled" "$interval" "$builtin"
}

build_config_from_builtin() {
    local sub_file="$1"
    local target_file="$2"
    local tmp_file="${target_file}.builtin.tmp"

    if [[ ! -f "$BUILTIN_RULE_FILE" ]]; then
        log "ERROR: Built-in rule file not found: $BUILTIN_RULE_FILE"
        return 1
    fi

    if ! awk -v url="$sub_file" '
BEGIN { in_pp=0; in_airport=0; replaced_path=0; replaced_type=0 }
{
    if ($0 ~ /^proxy-providers:[[:space:]]*$/) {
        in_pp=1
        print
        next
    }
    if (in_pp && $0 ~ /^[^[:space:]]/) {
        in_pp=0
        in_airport=0
    }
    if (in_pp && $0 ~ /^  Airport:[[:space:]]*$/) {
        in_airport=1
        print
        next
    }
    if (in_airport && $0 ~ /^  [A-Za-z0-9_-]+:[[:space:]]*$/) {
        in_airport=0
    }
    if (in_airport && $0 ~ /^    url:[[:space:]]*"/) {
        print "    path: \"" url "\""
        replaced_path=1
        next
    }
    if (in_airport && $0 ~ /^    path:[[:space:]]*"/) {
        print "    path: \"" url "\""
        replaced_path=1
        next
    }
    if (in_airport && $0 ~ /^    type:[[:space:]]*/) {
        print "    type: file"
        replaced_type=1
        next
    }
    print
}
END {
    if (replaced_path == 0 || replaced_type == 0) {
        exit 2
    }
}
' "$BUILTIN_RULE_FILE" > "$tmp_file"; then
        log "ERROR: Failed to inject subscription URL into built-in rule template."
        rm -f "$tmp_file"
        return 1
    fi

    mv "$tmp_file" "$target_file"
    return 0
}

auto_update_loop() {
    local last_settings_mtime=0
    local last_subs_mtime=0
    local enabled="true"
    local interval_minutes="0"
    local next_run=0
    local builtin_enabled="true"
    local prev_builtin_enabled="true"
    local mtime
    local subs_mtime
    local last_subs_signature=""
    local current_subs_signature=""

    # 初始化基线，避免容器启动后首次轮询被误判为“文件变更”
    if [[ -f "$SETTINGS_PUBLIC" ]]; then
        mtime=$(stat -c %Y "$SETTINGS_PUBLIC" 2>/dev/null || stat -f %m "$SETTINGS_PUBLIC")
        last_settings_mtime="$mtime"
        cp "$SETTINGS_PUBLIC" "$SETTINGS_FILE"
        IFS='|' read -r enabled interval_minutes builtin_enabled <<< "$(read_settings)"
        prev_builtin_enabled="$builtin_enabled"
    fi
    if [[ -f "$SUBSCRIPTIONS_PUBLIC" ]]; then
        subs_mtime=$(stat -c %Y "$SUBSCRIPTIONS_PUBLIC" 2>/dev/null || stat -f %m "$SUBSCRIPTIONS_PUBLIC")
        last_subs_mtime="$subs_mtime"
        cp "$SUBSCRIPTIONS_PUBLIC" "$SUBSCRIPTIONS_FILE"
        if load_subscriptions >/dev/null 2>&1; then
            last_subs_signature=$(subscriptions_signature)
        fi
    fi

    while true; do
        if [[ -f "$SETTINGS_PUBLIC" ]]; then
            mtime=$(stat -c %Y "$SETTINGS_PUBLIC" 2>/dev/null || stat -f %m "$SETTINGS_PUBLIC")
            if [[ "$mtime" != "$last_settings_mtime" ]]; then
                last_settings_mtime="$mtime"
                cp "$SETTINGS_PUBLIC" "$SETTINGS_FILE"
                prev_builtin_enabled="$builtin_enabled"
                IFS='|' read -r enabled interval_minutes builtin_enabled <<< "$(read_settings)"
                log "Auto update settings changed: enabled=$enabled interval=${interval_minutes}m builtin=$builtin_enabled"
                next_run=0
                if [[ "$builtin_enabled" != "$prev_builtin_enabled" ]]; then
                    log "Built-in rule switch changed ($prev_builtin_enabled -> $builtin_enabled), applying immediately..."
                    if update_resources "switch" "switch"; then
                        log "Built-in rule switch applied successfully."
                    else
                        log "WARNING: Failed to apply built-in rule switch immediately."
                    fi
                fi
            fi
        fi

        if [[ -f "$SUBSCRIPTIONS_PUBLIC" ]]; then
            subs_mtime=$(stat -c %Y "$SUBSCRIPTIONS_PUBLIC" 2>/dev/null || stat -f %m "$SUBSCRIPTIONS_PUBLIC")
            if [[ "$subs_mtime" != "$last_subs_mtime" ]]; then
                last_subs_mtime="$subs_mtime"
                cp "$SUBSCRIPTIONS_PUBLIC" "$SUBSCRIPTIONS_FILE"
                if load_subscriptions; then
                    log "Subscriptions updated: active=${ACTIVE_SUB_INDEX:-0} total=${#SUBS_URLS_ARRAY[@]}"
                    current_subs_signature=$(subscriptions_signature)
                    if [[ "$current_subs_signature" != "$last_subs_signature" ]]; then
                        if update_resources "switch" "switch"; then
                            next_run=0
                            if load_subscriptions >/dev/null 2>&1; then
                                last_subs_signature=$(subscriptions_signature)
                            else
                                last_subs_signature="$current_subs_signature"
                            fi
                        else
                            log "WARNING: Failed to apply subscription switch."
                        fi
                    fi
                else
                    log "Subscriptions file updated but empty."
                fi
            fi
        fi

        if [[ "$enabled" == "true" ]]; then
            if [[ -z "$interval_minutes" ]]; then
                interval_minutes="0"
            fi
            interval_sec=$(awk "BEGIN{printf \"%d\", $interval_minutes*60}")
            if [[ "$interval_sec" -gt 0 ]]; then
                now=$(date +%s)
                if [[ "$next_run" -eq 0 ]]; then
                    next_run=$((now + interval_sec))
                fi
                if [[ "$now" -ge "$next_run" ]]; then
                    update_resources "update" "all"
                    next_run=$((now + interval_sec))
                fi
            fi
        fi

        sleep 2
    done
}

# ========= 函数：启动快捷入口页面 =========
start_portal() {
    ensure_secret
    if [[ ! -f "$PORTAL_CONF_TEMPLATE" ]]; then
        cp "$PORTAL_CONF" "$PORTAL_CONF_TEMPLATE"
    fi
    cp "$PORTAL_CONF_TEMPLATE" "$PORTAL_CONF"
    if [[ -n "$PORTAL_ADMIN_KEY" ]]; then
        if command -v openssl >/dev/null 2>&1; then
            printf 'admin:%s\n' "$(openssl passwd -apr1 "$PORTAL_ADMIN_KEY")" > "$PORTAL_AUTH_FILE"
            sed -i "s|__PORTAL_AUTH__|auth_basic \"Portal Admin\"; auth_basic_user_file $PORTAL_AUTH_FILE;|g" "$PORTAL_CONF"
        else
            log "WARNING: openssl not found. Portal admin auth disabled."
            sed -i "s|__PORTAL_AUTH__||g" "$PORTAL_CONF"
        fi
    else
        sed -i "s|__PORTAL_AUTH__||g" "$PORTAL_CONF"
    fi
    write_portal_config
    init_settings
    if [[ -f "$PORTAL_STATUS_FILE" ]]; then
        cp "$PORTAL_STATUS_FILE" "$PORTAL_STATUS_PUBLIC"
        ensure_public_file_readable "$PORTAL_STATUS_PUBLIC"
    fi
    if [[ -f "$SUBSCRIPTION_INFO_FILE" ]]; then
        cp "$SUBSCRIPTION_INFO_FILE" "$SUBSCRIPTION_INFO_PUBLIC"
        ensure_public_file_readable "$SUBSCRIPTION_INFO_PUBLIC"
    else
        write_subscription_info_unknown "waiting for subscription update"
    fi
    if [[ -f "$PORTAL_LATENCY_BROWSER_FILE" ]]; then
        cp "$PORTAL_LATENCY_BROWSER_FILE" "$PORTAL_LATENCY_BROWSER_PUBLIC"
        ensure_public_file_readable "$PORTAL_LATENCY_BROWSER_PUBLIC"
    else
        write_latency_default "browser"
    fi
    if [[ -f "$PORTAL_LATENCY_ROUTER_FILE" ]]; then
        cp "$PORTAL_LATENCY_ROUTER_FILE" "$PORTAL_LATENCY_ROUTER_PUBLIC"
        ensure_public_file_readable "$PORTAL_LATENCY_ROUTER_PUBLIC"
    else
        write_latency_default "router"
    fi
    if [[ -f "$PORTAL_CONF" ]]; then
        sed -i "s/__PORTAL_PORT__/$PORTAL_PORT/g" "$PORTAL_CONF"
    fi
    log "Starting portal server on port $PORTAL_PORT..."
    nginx
}

# ========= 函数：修正端口与字段 =========
apply_config_fixes() {
    local FILE=$1
    log "Applying port fixes and defaults to $FILE..."

    # 端口修正
    sed -i "s/^mixed-port:.*/mixed-port: $CLASH_MIXED_PORT/" "$FILE"
    sed -i "s/^socks-port:.*/socks-port: $CLASH_SOCKS_PORT/" "$FILE"
    sed -i "s/^tproxy-port:.*/tproxy-port: $CLASH_TPROXY_PORT/" "$FILE"
    sed -i "s/^port:.*/port: $CLASH_HTTP_PORT/" "$FILE"
    sed -i "s|^[[:space:]]*#\\{0,1\\}[[:space:]]*external-ui:.*|external-ui: /opt/ui|" "$FILE"
    sed -i "s/^external-controller:.*/external-controller: 0.0.0.0:$DASH_PORT/" "$FILE"
    sed -i "s|^[[:space:]]*#\\{0,1\\}[[:space:]]*allow-lan:.*|allow-lan: true|" "$FILE"

    # 缺失字段兜底
    grep -q "mixed-port:" "$FILE" || echo "mixed-port: $CLASH_MIXED_PORT" >> "$FILE"
    grep -q "socks-port:" "$FILE" || echo "socks-port: $CLASH_SOCKS_PORT" >> "$FILE"
    grep -q "tproxy-port:" "$FILE" || echo "tproxy-port: $CLASH_TPROXY_PORT" >> "$FILE"
    grep -q "^port:" "$FILE" || echo "port: $CLASH_HTTP_PORT" >> "$FILE"
    grep -q "^[[:space:]]*external-ui:" "$FILE" || echo "external-ui: /opt/ui" >> "$FILE"
    grep -q "external-controller:" "$FILE" || echo "external-controller: 0.0.0.0:$DASH_PORT" >> "$FILE"
    grep -q "^[[:space:]]*allow-lan:" "$FILE" || echo "allow-lan: true" >> "$FILE"

    # Secret 处理
    if [[ -n "$CLASH_SECRET" ]]; then
        grep -q "^secret:" "$FILE" && \
            sed -i "s/^secret:.*/secret: \"$CLASH_SECRET\"/" "$FILE" || \
            echo "secret: \"$CLASH_SECRET\"" >> "$FILE"
    fi
}

validate_generated_config() {
    local output
    local retry=0

    while true; do
        if output=$(SAFE_PATHS="/opt/ui${SAFE_PATHS:+:$SAFE_PATHS}" clash -d "$CONFIG_DIR" -f "$CONFIG_FILE" -t 2>&1); then
            log "Config validation passed."
            return 0
        fi

        log "WARNING: Config validation failed."
        printf '%s\n' "$output" | tail -n 3 | while IFS= read -r line; do
            log "validate: $line"
        done

        if ! is_geodata_auto_update_enabled; then
            return 1
        fi

        if [[ "$retry" -lt "$CONFIG_TEST_MAX_RETRY" ]] && printf '%s' "$output" | grep -Eqi 'GeoSite|geosite'; then
            retry=$((retry + 1))
            log "GeoSite issue detected. Force refreshing GeoSite.dat (retry=$retry)..."
            rm -f "$GEOSITE_FILE"
            if download_with_fallback "$GEOSITE_FILE" "GeoSite.dat" \
                "$GEOSITE_URL" \
                "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/release/geosite.dat" \
                "https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geosite.dat"; then
                continue
            fi
        fi

        return 1
    done
}

restart_clash_via_api() {
    local HTTP_CODE
    local API_URL="http://127.0.0.1:${DASH_PORT}/restart"
    local AUTH_HEADER="Authorization: Bearer ${CLASH_SECRET}"
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API_URL" \
        -H "Content-Type: application/json" \
        -H "$AUTH_HEADER" \
        -d '{"path":"","payload":""}')
    if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "204" ]]; then
        log "Clash restart trigger success (HTTP $HTTP_CODE)."
    else
        log "ERROR: Clash restart trigger failed (HTTP $HTTP_CODE)."
    fi
}

apply_active_subscription_from_cache() {
    local mode="$1"
    local builtin_enabled="$2"
    local active_index="${ACTIVE_SUB_INDEX:-0}"
    local cache_file

    if [[ "$active_index" -lt 0 || "$active_index" -ge "${#SUBS_URLS_ARRAY[@]}" ]]; then
        active_index=0
    fi

    cache_file=$(subscription_cache_file_by_index "$active_index") || return 1
    if [[ ! -s "$cache_file" ]]; then
        log "WARNING: Active subscription cache missing: $cache_file"
        return 1
    fi

    if [[ "$builtin_enabled" == "true" ]]; then
        if ! build_config_from_builtin "$cache_file" "$CONFIG_FILE"; then
            return 1
        fi
    else
        cp "$cache_file" "$CONFIG_FILE"
    fi

    apply_config_fixes "$CONFIG_FILE"
    if ! validate_generated_config; then
        return 1
    fi
    write_portal_status
    CURRENT_ACTIVE_INDEX="$active_index"
    log "Configuration switched from local cache successfully."

    if [[ "$mode" == "update" || "$mode" == "switch" ]]; then
        restart_clash_via_api
    fi
    return 0
}

update_geodata_resources() {
    local mmdb_max_age=86400
    local prefetch_failed=0
    local first_start=0

    if [[ ! -f "$FIRST_START_MARKER" ]]; then
        first_start=1
    fi

    if ! is_geodata_auto_update_enabled; then
        log "GEODATA_AUTO_UPDATE disabled. Skip geodata prefetch."
        touch "$FIRST_START_MARKER" 2>/dev/null || true
        return 0
    fi

    seed_geodata_from_image
    log "Preparing geodata resources at container startup..."
    if ! download_if_stale "$MMDB_FILE" "$mmdb_max_age" "Country.mmdb" \
        "$MMDB_URL" \
        "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/release/country.mmdb" \
        "https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/country.mmdb"; then
        log "WARNING: Country.mmdb prefetch failed."
        prefetch_failed=1
    fi
    if ! download_if_stale "$GEOSITE_FILE" "$GEODATA_MAX_AGE" "GeoSite.dat" \
        "$GEOSITE_URL" \
        "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/release/geosite.dat" \
        "https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geosite.dat"; then
        log "WARNING: GeoSite.dat prefetch failed."
        prefetch_failed=1
    fi
    if ! download_if_stale "$GEOIP_FILE" "$GEODATA_MAX_AGE" "GeoIP.dat" \
        "$GEOIP_URL" \
        "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/release/geoip.dat" \
        "https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geoip.dat"; then
        log "WARNING: GeoIP.dat prefetch failed."
        prefetch_failed=1
    fi

    if [[ "$first_start" -eq 1 && "$prefetch_failed" -eq 1 ]]; then
        GEODATA_AUTO_UPDATE="false"
        log "First startup geodata prefetch failed/timeout. Auto disabling GEODATA_AUTO_UPDATE for this run."
    fi

    touch "$FIRST_START_MARKER" 2>/dev/null || true
}

# ========= 函数：执行更新任务 =========
# 参数 $1: MODE -> initial | update | switch
# 参数 $2: DOWNLOAD_SCOPE -> active | all | switch
update_resources() {
    local MODE="${1:-update}"
    local DOWNLOAD_SCOPE="${2:-active}"
    local lock_fd=200
    local builtin_enabled="true"
    local active_index=0
    local idx
    local now_shanghai
    local -a targets=()
    local curl_code=0
    local cache_file=""
    local header_file=""
    local active_download_ok="false"
    local subs_state_dirty="false"
    local active_error=""
    local switch_missing_cache="false"
    local rollback_index=""

    exec {lock_fd}>/tmp/clash_update.lock
    flock "$lock_fd"
    trap 'flock -u "$lock_fd"; exec {lock_fd}>&-' RETURN

    log "Starting resource update (mode=$MODE, scope=$DOWNLOAD_SCOPE)..."

    if ! load_subscriptions; then
        log "No subscriptions configured. Skipping update."
        return 0
    fi
    IFS='|' read -r _ _ builtin_enabled <<< "$(read_settings)"

    if [[ -f "$CONFIG_FILE" ]]; then
        cp "$CONFIG_FILE" "$CONFIG_FILE.bak"
    fi
    if [[ -f "$MMDB_FILE" ]]; then
        cp "$MMDB_FILE" "$MMDB_FILE.bak"
    fi

    active_index="${ACTIVE_SUB_INDEX:-0}"
    if [[ "$active_index" -lt 0 || "$active_index" -ge "${#SUBS_URLS_ARRAY[@]}" ]]; then
        active_index=0
    fi

    # 切换模式下默认不下载；若目标订阅本地缓存不存在，则尝试下载一次以生成缓存。
    if [[ "$MODE" == "switch" && "$DOWNLOAD_SCOPE" == "switch" ]]; then
        cache_file=$(subscription_cache_file_by_index "$active_index" 2>/dev/null || true)
        if [[ ! -s "$cache_file" ]]; then
            switch_missing_cache="true"
            if [[ "$CURRENT_ACTIVE_INDEX" -ge 0 && "$CURRENT_ACTIVE_INDEX" -lt "${#SUBS_URLS_ARRAY[@]}" ]]; then
                local rollback_cache
                rollback_cache=$(subscription_cache_file_by_index "$CURRENT_ACTIVE_INDEX" 2>/dev/null || true)
                if [[ -s "$rollback_cache" ]]; then
                    rollback_index="$CURRENT_ACTIVE_INDEX"
                fi
            fi
            log "WARNING: Active subscription cache missing: $cache_file"
            log "Attempting to download active subscription once to build local cache."
            DOWNLOAD_SCOPE="active"
        fi
    fi

    if [[ "$DOWNLOAD_SCOPE" == "all" ]]; then
        for idx in "${!SUBS_URLS_ARRAY[@]}"; do
            targets+=("$idx")
        done
    elif [[ "$DOWNLOAD_SCOPE" == "active" ]]; then
        targets+=("$active_index")
    fi

    for idx in "${targets[@]}"; do
        curl_code=0
        cache_file=$(subscription_cache_file_by_index "$idx") || continue
        header_file="$TMP_DIR/sub${idx}.headers"
        rm -f "$header_file" "${cache_file}.tmp"
        log "Downloading subscription $idx..."

        if curl_subscription "${SUBS_URLS_ARRAY[$idx]}" "$header_file" "${cache_file}.tmp" "$SUBSCR_DOWNLOAD_MAX_TIME"; then
            :
        else
            curl_code=$?
        fi

        if [[ -s "${cache_file}.tmp" ]]; then
            mv "${cache_file}.tmp" "$cache_file"
            now_shanghai=$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S')
            SUBS_UPDATED_ARRAY[$idx]="$now_shanghai"
            SUBS_ERRORS_ARRAY[$idx]=""
            SUBS_NAMES_ARRAY[$idx]=$(derive_subscription_name "${SUBS_URLS_ARRAY[$idx]}" "$header_file")
            update_subscription_info_from_header "$header_file" "$idx" "false"
            subs_state_dirty="true"
            if [[ "$idx" -eq "$active_index" ]]; then
                active_download_ok="true"
            fi
        else
            rm -f "${cache_file}.tmp"
            SUBS_ERRORS_ARRAY[$idx]="下载失败（curl=${curl_code:-1}）"
            cache_subscription_info_unknown_for_index "$idx" "subscription download failed (curl=${curl_code:-1})"
            log "WARNING: Failed to download subscription $idx (curl=${curl_code:-1})"
            subs_state_dirty="true"
            if [[ "$idx" -eq "$active_index" ]]; then
                active_error="当前订阅下载失败（索引 ${active_index}，curl=${curl_code:-1}）。"
            fi
        fi
    done

    if [[ "$DOWNLOAD_SCOPE" != "switch" && "$subs_state_dirty" == "true" ]]; then
        write_subscriptions_state "$SUBSCRIPTIONS_FILE"
    fi

    if [[ "$switch_missing_cache" == "true" && "$active_download_ok" != "true" ]]; then
        if [[ -n "$rollback_index" ]]; then
            ACTIVE_SUB_INDEX="$rollback_index"
            active_index="$rollback_index"
            active_error=""
            write_subscriptions_state "$SUBSCRIPTIONS_FILE"
            write_subscription_info_from_cache_index "$active_index" || true
            log "Switch aborted: cache missing for target subscription, reverted active to $active_index."
        fi
    fi

    if [[ "$DOWNLOAD_SCOPE" != "switch" && "$active_download_ok" != "true" && -n "$active_error" ]]; then
        cache_subscription_info_unknown_for_index "$active_index" "$active_error"
    fi
    write_subscription_info_from_cache_index "$active_index" || write_subscription_info_unknown "$active_error"

    if apply_active_subscription_from_cache "$MODE" "$builtin_enabled"; then
        cache_file=$(subscription_cache_file_by_index "$active_index" 2>/dev/null || true)
        if [[ -n "$cache_file" && -f "$cache_file" ]]; then
            cp "$cache_file" "$DEBUG_RAW_CONFIG" 2>/dev/null || true
        fi
        rm -f "$CONFIG_FILE.bak" "$MMDB_FILE.bak" "$MMDB_FILE.tmp"
        return 0
    fi

    log "CRITICAL: Update/switch failed."
    if [[ -f "$CONFIG_FILE.bak" || -f "$MMDB_FILE.bak" ]]; then
        log "Restoring from backups..."
        if [[ -f "$CONFIG_FILE.bak" ]]; then
            mv "$CONFIG_FILE.bak" "$CONFIG_FILE"
        fi
        if [[ -f "$MMDB_FILE.bak" ]]; then
            mv "$MMDB_FILE.bak" "$MMDB_FILE"
        fi
    fi
    if [[ "$MODE" == "initial" ]]; then
        log "Initial startup failed due to missing/invalid local subscription cache. Exiting."
        exit 1
    fi
    return 1
}

# ========= 主逻辑 =========

# 0. 启动快捷入口页面
init_subscriptions
start_portal
if [[ ! -f "$PORTAL_STATUS_FILE" ]]; then
    write_portal_status
fi
watch_portal_update &
update_geodata_resources

# 1. 首次运行：等待订阅，然后执行更新和配置生成
wait_for_subscriptions
update_resources "initial"

# 2. 启动后台自动更新循环
auto_update_loop &

# 3. 启动 mihomo (前台运行)
# 使用 exec 替换当前 shell 进程，让 clash 成为 PID 1 (或继承 PID)
log "Starting clash (mihomo) in foreground..."
export SAFE_PATHS="/opt/ui"
exec clash -d "$CONFIG_DIR"
