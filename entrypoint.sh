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
SUBSCR_MAX_BYTES=${SUBSCR_MAX_BYTES:-16777216}
PORTAL_ADMIN_KEY=${PORTAL_ADMIN_KEY:-}
CONFIG_VALIDATE_MAX_TIME=${CONFIG_VALIDATE_MAX_TIME:-90}
PORTAL_TASK_DIR="/opt/portal/tasks"
PORTAL_REQUEST_DIR="/opt/portal/requests"
# 更新间隔，默认 12 小时 (43200 秒)
UPDATE_INTERVAL=${UPDATE_INTERVAL:-43200}

CONFIG_DIR="/root/.config/clash"
APPLIED_STATE_FILE="$CONFIG_DIR/applied-state.json"
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

mkdir -p "$CONFIG_DIR" "$TMP_DIR"
mkdir -p "$SUBS_CACHE_DIR"

# ========= 函数：日志 =========
validate_environment() {
    local name value
    local -A used_ports=()
    for name in PORTAL_PORT DASH_PORT CLASH_HTTP_PORT CLASH_SOCKS_PORT CLASH_TPROXY_PORT CLASH_MIXED_PORT; do
        value="${!name}"
        if [[ ! "$value" =~ ^[1-9][0-9]{0,4}$ ]] || (( value > 65535 )); then
            log "ERROR: Invalid port in $name."
            return 1
        fi
        if [[ -n "${used_ports[$value]:-}" ]]; then
            log "ERROR: Duplicate port in $name and ${used_ports[$value]}."
            return 1
        fi
        used_ports[$value]="$name"
    done
    for name in UPDATE_INTERVAL SUBSCR_CONNECT_TIMEOUT SUBSCR_VALIDATE_MAX_TIME SUBSCR_DOWNLOAD_MAX_TIME CONFIG_VALIDATE_MAX_TIME; do
        value="${!name}"
        if [[ ! "$value" =~ ^[0-9]{1,7}$ ]] || (( 10#$value < 1 )); then
            log "ERROR: $name must be a positive number of seconds."
            return 1
        fi
    done
    if [[ "$CLASH_SECRET" == *$'\n'* || "$CLASH_SECRET" == *$'\r'* || "$PORTAL_ADMIN_KEY" == *$'\n'* || "$PORTAL_ADMIN_KEY" == *$'\r'* ]]; then
        log "ERROR: Passwords cannot contain line breaks."
        return 1
    fi
}

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
            --proto '=http,https' --proto-redir '=http,https' \
            --max-filesize "$SUBSCR_MAX_BYTES" \
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
            --proto '=http,https' --proto-redir '=http,https' \
            --max-filesize "$SUBSCR_MAX_BYTES" \
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
    secret=$(openssl rand -hex 24)
    printf '%s' "$secret"
}

ensure_secret() {
    if [[ -z "$CLASH_SECRET" && -f "$PORTAL_STATE_FILE" ]]; then
        CLASH_SECRET=$(jq -r '.secret // empty' "$PORTAL_STATE_FILE" 2>/dev/null || true)
    fi
    [[ -n "$CLASH_SECRET" ]] || CLASH_SECRET=$(generate_secret)
    (umask 077; jq -n --arg secret "$CLASH_SECRET" '{secret:$secret}' > "$PORTAL_STATE_FILE.tmp")
    chmod 600 "$PORTAL_STATE_FILE.tmp"
    mv "$PORTAL_STATE_FILE.tmp" "$PORTAL_STATE_FILE"
}

ensure_portal_admin_key() {
    local key_file="$CONFIG_DIR/portal-admin.key"
    if [[ -z "$PORTAL_ADMIN_KEY" ]]; then
        if [[ -s "$key_file" ]]; then
            PORTAL_ADMIN_KEY=$(cat "$key_file")
        else
            PORTAL_ADMIN_KEY=$(generate_secret)
            (umask 077; printf '%s\n' "$PORTAL_ADMIN_KEY" > "$key_file.tmp")
            mv "$key_file.tmp" "$key_file"
            log "Portal admin password generated. Read $key_file or set PORTAL_ADMIN_KEY."
        fi
    fi
}

# ========= 函数：生成 Portal 配置 =========

escape_json() {
    jq -jn --arg value "$1" '($value|tojson)[1:-1]'
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
    local json
    json=$(jq -n --arg dashPort "$DASH_PORT" --arg portalPort "$PORTAL_PORT" \
        --arg httpPort "$CLASH_HTTP_PORT" --arg socksPort "$CLASH_SOCKS_PORT" \
        --arg tproxyPort "$CLASH_TPROXY_PORT" --arg mixedPort "$CLASH_MIXED_PORT" \
        --arg updateIntervalSec "$UPDATE_INTERVAL" \
        '{dashPort:$dashPort,portalPort:$portalPort,httpPort:$httpPort,socksPort:$socksPort,
          tproxyPort:$tproxyPort,mixedPort:$mixedPort,updateIntervalSec:$updateIntervalSec,adminAuthEnabled:true}')
    printf 'window.__PORTAL_CONFIG__ = %s;\n' "$json" > "$PORTAL_CONFIG"
    jq -n --arg secret "$CLASH_SECRET" '{secret:$secret}' > /opt/portal/connection.json
    ensure_public_file_readable /opt/portal/connection.json
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
    local source="${1:-$SUBSCRIPTIONS_PUBLIC}"
    local snapshot
    SUBS_REQUEST_ID=""
    SUBS_SOURCE_HASH=""
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
        snapshot=$(mktemp "$TMP_DIR/subscriptions.XXXXXX")
        cp "$source" "$snapshot"
        source="$snapshot"
        [[ -z "${2:-}" ]] || cp "$snapshot" "$2"
        SUBS_REQUEST_ID=$(jq -r '.requestId // empty' "$source" 2>/dev/null || true)
        SUBS_SOURCE_HASH=$(sha256sum "$source" | cut -d' ' -f1)
        trap 'rm -f "$snapshot"; trap - RETURN' RETURN
        if ! jq -e 'def urls: .urls // [(.items // [])[] | .url];
            type=="object" and (urls|type)=="array" and (urls|length)>0 and
            all(urls[]; type=="string" and test("^https?://")) and ((.active // 0)|type)=="number"' "$source" >/dev/null 2>&1; then
            return 1
        fi
    elif [[ -f "$SUBSCRIPTIONS_FILE" ]]; then
        source="$SUBSCRIPTIONS_FILE"
        cp "$SUBSCRIPTIONS_FILE" "$SUBSCRIPTIONS_PUBLIC"
    else
        return 1
    fi

    SUBS_REQUEST_ID=$(jq -r '.requestId // empty' "$source")
    SUBS_SOURCE_HASH=$(sha256sum "$source" | cut -d' ' -f1)
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
        normalized_url="$url"
        duplicate=0
        for existing in "${unique_urls[@]}"; do
            if [[ "$existing" == "$normalized_url" ]]; then
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
        SUBS_NAMES_ARRAY[$idx]=$(jq -r --arg url "${SUBS_URLS_ARRAY[$idx]}" '(.items // [] | map(select(.url==$url))[0]).name // empty' "$source" 2>/dev/null || true)
        SUBS_UPDATED_ARRAY[$idx]=$(jq -r --arg url "${SUBS_URLS_ARRAY[$idx]}" '(.items // [] | map(select(.url==$url))[0]).updatedAtShanghai // (.items // [] | map(select(.url==$url))[0]).checkedAtShanghai // empty' "$source" 2>/dev/null || true)
        SUBS_ERRORS_ARRAY[$idx]=$(jq -r --arg url "${SUBS_URLS_ARRAY[$idx]}" '(.items // [] | map(select(.url==$url))[0]).lastError // empty' "$source" 2>/dev/null || true)
        SUBS_INFO_HAS_ARRAY[$idx]=$(jq -r --arg url "${SUBS_URLS_ARRAY[$idx]}" '(.items // [] | map(select(.url==$url))[0]).subscriptionInfo.hasInfo // "false"' "$source" 2>/dev/null || echo "false")
        SUBS_INFO_TOTAL_ARRAY[$idx]=$(jq -r --arg url "${SUBS_URLS_ARRAY[$idx]}" '(.items // [] | map(select(.url==$url))[0]).subscriptionInfo.totalBytes // 0' "$source" 2>/dev/null || echo "0")
        SUBS_INFO_UPLOAD_ARRAY[$idx]=$(jq -r --arg url "${SUBS_URLS_ARRAY[$idx]}" '(.items // [] | map(select(.url==$url))[0]).subscriptionInfo.uploadBytes // 0' "$source" 2>/dev/null || echo "0")
        SUBS_INFO_DOWNLOAD_ARRAY[$idx]=$(jq -r --arg url "${SUBS_URLS_ARRAY[$idx]}" '(.items // [] | map(select(.url==$url))[0]).subscriptionInfo.downloadBytes // 0' "$source" 2>/dev/null || echo "0")
        SUBS_INFO_USED_ARRAY[$idx]=$(jq -r --arg url "${SUBS_URLS_ARRAY[$idx]}" '(.items // [] | map(select(.url==$url))[0]).subscriptionInfo.usedBytes // 0' "$source" 2>/dev/null || echo "0")
        SUBS_INFO_REMAINING_ARRAY[$idx]=$(jq -r --arg url "${SUBS_URLS_ARRAY[$idx]}" '(.items // [] | map(select(.url==$url))[0]).subscriptionInfo.remainingBytes // 0' "$source" 2>/dev/null || echo "0")
        SUBS_INFO_USED_PERCENT_ARRAY[$idx]=$(jq -r --arg url "${SUBS_URLS_ARRAY[$idx]}" '(.items // [] | map(select(.url==$url))[0]).subscriptionInfo.usedPercent // 0' "$source" 2>/dev/null || echo "0")
        SUBS_INFO_EXPIRE_TS_ARRAY[$idx]=$(jq -r --arg url "${SUBS_URLS_ARRAY[$idx]}" '(.items // [] | map(select(.url==$url))[0]).subscriptionInfo.expireTs // 0' "$source" 2>/dev/null || echo "0")
        SUBS_INFO_EXPIRE_SH_ARRAY[$idx]=$(jq -r --arg url "${SUBS_URLS_ARRAY[$idx]}" '(.items // [] | map(select(.url==$url))[0]).subscriptionInfo.expireAtShanghai // "-"' "$source" 2>/dev/null || echo "-")
        SUBS_INFO_MSG_ARRAY[$idx]=$(jq -r --arg url "${SUBS_URLS_ARRAY[$idx]}" '(.items // [] | map(select(.url==$url))[0]).subscriptionInfo.message // "subscription-userinfo not found"' "$source" 2>/dev/null || echo "subscription-userinfo not found")
        if [[ -z "${SUBS_NAMES_ARRAY[$idx]}" ]]; then
            SUBS_NAMES_ARRAY[$idx]=$(derive_subscription_name "${SUBS_URLS_ARRAY[$idx]}" "")
        fi
    done

    SUBSCR_URLS=$(IFS=','; printf '%s' "${SUBS_URLS_ARRAY[*]}")
    return 0
}

write_subscriptions_state() {
    local target="${1:-$SUBSCRIPTIONS_FILE}"
    if [[ -n "${SUBS_SOURCE_HASH:-}" && -s "$SUBSCRIPTIONS_PUBLIC" && "$SUBS_SOURCE_HASH" != "$(sha256sum "$SUBSCRIPTIONS_PUBLIC" | cut -d' ' -f1)" ]]; then
        log "Subscription state changed; preserving the newer request."
        return 1
    fi
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

    if ! jq -e . "$tmp_file" >/dev/null || [[ "$SUBS_SOURCE_HASH" != "$(sha256sum "$SUBSCRIPTIONS_PUBLIC" | cut -d' ' -f1)" ]]; then
        rm -f "$tmp_file"
        log "Subscription state changed while serializing; keeping the newer request."
        return 1
    fi
    mv "$tmp_file" "$target"
    cp "$target" "$tmp_public"
    if [[ "$SUBS_SOURCE_HASH" != "$(sha256sum "$SUBSCRIPTIONS_PUBLIC" | cut -d' ' -f1)" ]]; then
        rm -f "$tmp_public"
        return 1
    fi
    mv "$tmp_public" "$SUBSCRIPTIONS_PUBLIC"
    ensure_public_file_readable "$SUBSCRIPTIONS_PUBLIC"
    SUBS_SOURCE_HASH=$(sha256sum "$SUBSCRIPTIONS_PUBLIC" | cut -d' ' -f1)
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
        if [[ -s "$SETTINGS_PUBLIC" ]]; then cp "$SETTINGS_PUBLIC" "$SETTINGS_FILE"; fi
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
    if [[ "$request_id" =~ ^[A-Za-z0-9-]{1,80}$ ]]; then
        cp "$PORTAL_SUB_VALIDATE_RESULT_PUBLIC" "$PORTAL_TASK_DIR/$request_id.json.tmp"
        mv "$PORTAL_TASK_DIR/$request_id.json.tmp" "$PORTAL_TASK_DIR/$request_id.json"
        ensure_public_file_readable "$PORTAL_TASK_DIR/$request_id.json"
    fi
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
    local name
    local curl_code=0
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

    local builtin candidate="$TMP_DIR/validate-$request_id.yaml" validation_error
    IFS='|' read -r _ _ builtin <<< "$(read_settings)"
    if ! validation_error=$(generate_config "$body_file" "$candidate" "$builtin" 2>&1); then
        write_subscription_validate_result false "$url" "" "$validation_error" "$request_id"
        rm -f "$candidate"
        return 1
    fi
    if ! validate_generated_config "$candidate"; then
        write_subscription_validate_result false "$url" "" "Clash 配置校验失败，请检查订阅格式或模板设置。" "$request_id"
        rm -f "$candidate"
        return 1
    fi
    rm -f "$candidate"
    name=$(derive_subscription_name "$url" "$header_file")
    info_json=$(build_subscription_info_json_from_header "$header_file")
    now_shanghai=$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S')
    write_subscription_validate_result "true" "$url" "$name" "订阅链接校验通过。" "$request_id" "$info_json" "$now_shanghai"
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

refresh_latency_cache() (
    local mode="$1"
    local force="${2:-false}"
    local lock_fd
    exec {lock_fd}>"/tmp/portal-latency-$mode.lock"
    flock "$lock_fd"
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
    if CLASH_MIXED_PORT="$CLASH_MIXED_PORT" timeout 100 "$probe_script" > "$tmp_file"; then
        jq --arg requestId "$force" '. + {requestId:$requestId}' "$tmp_file" > "$tmp_file.result"
        mv "$tmp_file.result" "$tmp_file"
        mv "$tmp_file" "$target_file"
        cp "$target_file" "$tmp_public"
        mv "$tmp_public" "$target_public"
        ensure_public_file_readable "$target_public"
        if [[ "$force" =~ ^[A-Za-z0-9-]{1,80}$ ]]; then
            cp "$target_file" "$PORTAL_TASK_DIR/$force.json.tmp"
            mv "$PORTAL_TASK_DIR/$force.json.tmp" "$PORTAL_TASK_DIR/$force.json"
            ensure_public_file_readable "$PORTAL_TASK_DIR/$force.json"
        fi
        return 0
    fi

    rm -f "$tmp_file"
    write_latency_error "$mode" "latency probe failed"
    write_task_status "$force" failed "延迟检测失败或超时"
    return 1
)

# ========= 函数：处理 Portal 触发更新 =========
watch_portal_update() {
    while true; do
        if [[ ! -f /tmp/portal-core-started && -s "$SETTINGS_PUBLIC" ]]; then
            if jq -e '(.autoEnabled|type)=="boolean" and (.builtinEnabled|type)=="boolean" and
                (.intervalMinutes|type)=="number" and .intervalMinutes>=0 and .intervalMinutes<=10080 and
                (.autoEnabled==false or .intervalMinutes>=1)' "$SETTINGS_PUBLIC" >/dev/null 2>&1; then
                cp "$SETTINGS_PUBLIC" "$SETTINGS_FILE"
                write_task_status "$(jq -r '.requestId // empty' "$SETTINGS_PUBLIC")" success "设置已保存"
            fi
        fi
        local request kind request_id request_body claimed
        for request in "$PORTAL_REQUEST_DIR"/*/*; do
            [[ -f "$request" ]] || continue
            kind=$(basename "$(dirname "$request")")
            request_id=$(basename "$request")
            [[ "$request_id" =~ ^[A-Za-z0-9-]{1,80}$ ]] || { rm -f "$request"; continue; }
            claimed="$TMP_DIR/request-$request_id"
            mv "$request" "$claimed" || continue
            request_body=$(cat "$claimed")
            rm -f "$claimed"
            case "$kind" in
                updates)
                    local scope
                    scope=$(printf '%s' "$request_body" | jq -r '.scope // "active"' 2>/dev/null || true)
                    [[ "$scope" == "all" ]] || scope=active
                    update_resources update "$scope" "$request_id" || true
                    ;;
                validations)
                    local url
                    url=$(printf '%s' "$request_body" | jq -r '.url // empty' 2>/dev/null || true)
                    validate_subscription_url "$url" "$request_id" || true
                    ;;
                latency-browser|latency-router)
                    local mode="${kind#latency-}"
                    (refresh_latency_cache "$mode" "$request_id" || true) &
                    ;;
            esac
        done
        find "$PORTAL_TASK_DIR" -type f -mmin +1440 -delete
        if [[ -f "$PORTAL_UPDATE_TRIGGER" ]]; then
            local update_req_raw
            local update_scope
            update_req_raw=$(cat "$PORTAL_UPDATE_TRIGGER" 2>/dev/null || true)
            rm -f "$PORTAL_UPDATE_TRIGGER"
            update_scope=$(printf '%s' "$update_req_raw" | jq -r '.scope // empty' 2>/dev/null || true)
            if [[ "$update_scope" != "all" ]]; then
                update_scope="active"
            fi
            update_resources "update" "$update_scope" "$(printf '%s' "$update_req_raw" | jq -r ' .requestId // empty' 2>/dev/null || true)" || log "Manual update failed; worker continues."
        fi
        if [[ -f "$PORTAL_LATENCY_BROWSER_TRIGGER" ]]; then
            rm -f "$PORTAL_LATENCY_BROWSER_TRIGGER"
            refresh_latency_cache "browser" "true" || true
        fi
        if [[ -f "$PORTAL_LATENCY_ROUTER_TRIGGER" ]]; then
            rm -f "$PORTAL_LATENCY_ROUTER_TRIGGER"
            refresh_latency_cache "router" "true" || true
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
{"autoEnabled":true,"intervalMinutes":$default_minutes,"builtinEnabled":false}
EOF
    cp "$SETTINGS_FILE" "$SETTINGS_PUBLIC"
    ensure_public_file_readable "$SETTINGS_PUBLIC"
}

read_settings() {
    local source="${1:-$SETTINGS_PUBLIC}"
    [[ -f "$source" ]] || source="$SETTINGS_FILE"
    jq -r --argjson minutes "$(awk "BEGIN{print $UPDATE_INTERVAL/60}")" '
        (if (.autoEnabled|type)=="boolean" then .autoEnabled else true end | tostring) + "|" +
        (if (.intervalMinutes|type)=="number" and .intervalMinutes>=1 and .intervalMinutes<=10080
            then .intervalMinutes else $minutes end | tostring) + "|" +
        (if (.builtinEnabled|type)=="boolean" then .builtinEnabled else false end | tostring)
    ' "$source" 2>/dev/null || printf 'true|720|false'
}

generate_config() {
    local sub_file="$1" target_file="$2" builtin_enabled="$3"
    local -a args=()
    [[ "$builtin_enabled" != "true" ]] || args+=(--template "$BUILTIN_RULE_FILE")
    python3 /opt/scripts/config_tool.py --subscription "$sub_file" --output "$target_file" \
        --secret-file "$PORTAL_STATE_FILE" --ports "$(jq -nc \
          --argjson port "$CLASH_HTTP_PORT" --argjson socks "$CLASH_SOCKS_PORT" \
          --argjson mixed "$CLASH_MIXED_PORT" --argjson tproxy "$CLASH_TPROXY_PORT" \
          --arg controller "0.0.0.0:$DASH_PORT" \
          '{port:$port,"socks-port":$socks,"mixed-port":$mixed,"tproxy-port":$tproxy,"external-controller":$controller}')" \
        "${args[@]}"
}

auto_update_loop() {
    local last_settings_mtime=0
    local last_subs_mtime=0
    local enabled="true"
    local interval_minutes="0"
    local next_run=0
    local builtin_enabled="false"
    local prev_builtin_enabled="false"
    local mtime
    local subs_mtime
    local last_subs_signature=""
    local current_subs_signature=""
    local settings_snapshot settings_request_id

    # 初始化基线，避免容器启动后首次轮询被误判为“文件变更”
    if [[ -f "$SETTINGS_PUBLIC" ]]; then
        mtime=$(sha256sum "$SETTINGS_PUBLIC" | cut -d' ' -f1)
        last_settings_mtime="$mtime"
        cp "$SETTINGS_PUBLIC" "$SETTINGS_FILE"
        IFS='|' read -r enabled interval_minutes builtin_enabled <<< "$(read_settings)"
        prev_builtin_enabled="$builtin_enabled"
    fi
    if [[ -f "$SUBSCRIPTIONS_PUBLIC" ]]; then
        subs_mtime=$(sha256sum "$SUBSCRIPTIONS_PUBLIC" | cut -d' ' -f1)
        last_subs_mtime="$subs_mtime"
        if load_subscriptions >/dev/null 2>&1; then
            last_subs_signature=$(subscriptions_signature)
        fi
    fi

    while true; do
        if [[ -f "$SETTINGS_PUBLIC" ]]; then
            mtime=$(sha256sum "$SETTINGS_PUBLIC" | cut -d' ' -f1)
            if [[ "$mtime" != "$last_settings_mtime" ]]; then
                settings_snapshot=$(mktemp "$TMP_DIR/settings.XXXXXX")
                cp "$SETTINGS_PUBLIC" "$settings_snapshot"
                mtime=$(sha256sum "$settings_snapshot" | cut -d' ' -f1)
                last_settings_mtime="$mtime"
                settings_request_id=$(jq -r '.requestId // empty' "$settings_snapshot" 2>/dev/null || true)
                if ! jq -e '(.autoEnabled|type)=="boolean" and (.builtinEnabled|type)=="boolean" and
                    (.intervalMinutes|type)=="number" and .intervalMinutes>=0 and .intervalMinutes<=10080 and
                    (.autoEnabled==false or .intervalMinutes>=1)' "$settings_snapshot" >/dev/null 2>&1; then
                    write_task_status "$settings_request_id" failed "更新间隔或设置格式无效"
                    if [[ "$mtime" == "$(sha256sum "$SETTINGS_PUBLIC" | cut -d' ' -f1)" ]]; then
                        cp "$SETTINGS_FILE" "$SETTINGS_PUBLIC"
                    fi
                    rm -f "$settings_snapshot"
                    ensure_public_file_readable "$SETTINGS_PUBLIC"
                    log "Invalid settings rejected."
                    continue
                fi
                cp "$settings_snapshot" "$SETTINGS_FILE"
                prev_builtin_enabled="$builtin_enabled"
                IFS='|' read -r enabled interval_minutes builtin_enabled <<< "$(read_settings "$settings_snapshot")"
                rm -f "$settings_snapshot"
                log "Auto update settings changed: enabled=$enabled interval=${interval_minutes}m builtin=$builtin_enabled"
                next_run=0
                if [[ "$builtin_enabled" != "$prev_builtin_enabled" ]]; then
                    log "Built-in rule switch changed ($prev_builtin_enabled -> $builtin_enabled), applying immediately..."
                    if update_resources "switch" "switch" "$settings_request_id" "" "$mtime"; then
                        log "Built-in rule switch applied successfully."
                    else
                        log "WARNING: Failed to apply built-in rule switch immediately."
                    fi
                else
                    write_task_status "$settings_request_id" success "设置已保存"
                fi
            fi
        fi

        if [[ -f "$SUBSCRIPTIONS_PUBLIC" ]]; then
            subs_mtime=$(sha256sum "$SUBSCRIPTIONS_PUBLIC" | cut -d' ' -f1)
            if [[ "$subs_mtime" != "$last_subs_mtime" ]]; then
                last_subs_mtime="$subs_mtime"
                if load_subscriptions; then
                    log "Subscriptions updated: active=${ACTIVE_SUB_INDEX:-0} total=${#SUBS_URLS_ARRAY[@]}"
                    current_subs_signature=$(subscriptions_signature)
                    if [[ "$current_subs_signature" != "$last_subs_signature" ]]; then
                        if update_resources "switch" "switch" "$SUBS_REQUEST_ID" "$SUBS_SOURCE_HASH"; then
                            next_run=0
                            if load_subscriptions >/dev/null 2>&1; then
                                last_subs_signature=$(subscriptions_signature)
                            else
                                last_subs_signature="$current_subs_signature"
                            fi
                        else
                            log "WARNING: Failed to apply subscription switch."
                        fi
                    else
                        if [[ "$SUBS_SOURCE_HASH" == "$(sha256sum "$SUBSCRIPTIONS_PUBLIC" | cut -d' ' -f1)" ]]; then
                            write_subscriptions_state "$SUBSCRIPTIONS_FILE" || true
                            write_task_status "$SUBS_REQUEST_ID" success "订阅已保存"
                        fi
                    fi
                else
                    write_task_status "$SUBS_REQUEST_ID" failed "订阅列表无效，已保留原设置"
                    if [[ "$SUBS_SOURCE_HASH" == "$(sha256sum "$SUBSCRIPTIONS_PUBLIC" | cut -d' ' -f1)" ]]; then
                        cp "$SUBSCRIPTIONS_FILE" "$SUBSCRIPTIONS_PUBLIC"
                    fi
                    ensure_public_file_readable "$SUBSCRIPTIONS_PUBLIC"
                    log "Invalid subscription list rejected."
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
                    update_resources "update" "all" || log "Scheduled update failed; worker continues."
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
    ensure_portal_admin_key
    mkdir -p "$PORTAL_TASK_DIR" "$PORTAL_REQUEST_DIR"/{updates,validations,latency-browser,latency-router}
    chown -R www-data:www-data "$PORTAL_TASK_DIR" "$PORTAL_REQUEST_DIR"
    if [[ ! -f "$PORTAL_CONF_TEMPLATE" ]]; then
        cp "$PORTAL_CONF" "$PORTAL_CONF_TEMPLATE"
    fi
    cp "$PORTAL_CONF_TEMPLATE" "$PORTAL_CONF"
    if [[ -n "$PORTAL_ADMIN_KEY" ]]; then
        if command -v openssl >/dev/null 2>&1; then
            printf 'admin:%s\n' "$(printf '%s\n' "$PORTAL_ADMIN_KEY" | openssl passwd -apr1 -stdin)" > "$PORTAL_AUTH_FILE"
            sed -i "s|__PORTAL_AUTH__|auth_basic \"Portal Admin\"; auth_basic_user_file $PORTAL_AUTH_FILE;|g" "$PORTAL_CONF"
        else
            log "ERROR: openssl missing; cannot enable Portal authentication."
            return 1
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

# ========= 函数：任务状态与配置应用 =========
write_task_status() {
    local request_id="$1" state="$2" message="$3"
    [[ "$request_id" =~ ^[A-Za-z0-9-]{1,80}$ ]] || return 0
    local target="$PORTAL_TASK_DIR/$request_id.json"
    jq -n --arg requestId "$request_id" --arg state "$state" --arg message "$message" \
        '{requestId:$requestId,state:$state,message:$message}' > "$target.tmp"
    mv "$target.tmp" "$target"
    ensure_public_file_readable "$target"
}

validate_generated_config() {
    local output
    local retry=0
    local candidate="${1:-$CONFIG_FILE}"

    while true; do
        if output=$(SAFE_PATHS="/opt/ui${SAFE_PATHS:+:$SAFE_PATHS}" timeout "$CONFIG_VALIDATE_MAX_TIME" clash -d "$CONFIG_DIR" -f "$candidate" -t 2>&1); then
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

reload_clash_via_api() {
    local code
    # Hot reload keeps the core and the Portal workers alive.
    code=$(curl -sS --connect-timeout 5 --max-time 90 -o /dev/null -w '%{http_code}' \
        -X PUT "http://127.0.0.1:${DASH_PORT}/configs?force=true" \
        -H 'Content-Type: application/json' -H "Authorization: Bearer $CLASH_SECRET" \
        -d '{"path":"","payload":""}') || return 1
    [[ "$code" == "200" || "$code" == "204" ]] || { log "Config reload failed (HTTP $code)."; return 1; }
}

restore_applied_selection() {
    [[ -s "$APPLIED_STATE_FILE" ]] || return 0
    local applied_url old_builtin idx
    applied_url=$(jq -r '.url' "$APPLIED_STATE_FILE")
    old_builtin=$(jq -r '.builtinEnabled' "$APPLIED_STATE_FILE")
    for idx in "${!SUBS_URLS_ARRAY[@]}"; do
        if [[ "${SUBS_URLS_ARRAY[$idx]}" == "$applied_url" ]]; then
            ACTIVE_SUB_INDEX="$idx"
            write_subscriptions_state "$SUBSCRIPTIONS_FILE" || true
            break
        fi
    done
    if [[ -s "$SETTINGS_PUBLIC" && "${settings_signature:-}" == "$(sha256sum "$SETTINGS_PUBLIC" | cut -d' ' -f1)" ]]; then
        jq --argjson builtin "$old_builtin" '.builtinEnabled=$builtin | del(.requestId)' "$SETTINGS_PUBLIC" > "$SETTINGS_PUBLIC.tmp"
        mv "$SETTINGS_PUBLIC.tmp" "$SETTINGS_PUBLIC"
        ensure_public_file_readable "$SETTINGS_PUBLIC"
        cp "$SETTINGS_PUBLIC" "$SETTINGS_FILE"
    fi
}

update_geodata_resources() {
    local mmdb_max_age=86400
    local prefetch_failed=0
    local first_start=0

    if [[ ! -f "$FIRST_START_MARKER" ]]; then
        first_start=1
    fi

    seed_geodata_from_image
    if ! is_geodata_auto_update_enabled; then
        log "GEODATA_AUTO_UPDATE disabled. Skip geodata prefetch."
        touch "$FIRST_START_MARKER" 2>/dev/null || true
        return 0
    fi

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
update_resources() (
    local mode="${1:-update}" scope="${2:-active}" request_id="${3:-}" expected_subs="${4:-}" expected_settings="${5:-}"
    local lock_fd stage active cache candidate builtin idx header downloaded=false failures=0 subs_signature settings_signature
    local -a targets=()
    exec {lock_fd}>/tmp/clash_update.lock
    flock "$lock_fd"
    stage=$(mktemp -d "$CONFIG_DIR/.update.XXXXXX") || return 1
    trap '
        result=$?
        if [[ "$result" -ne 0 && "$request_id" =~ ^[A-Za-z0-9-]{1,80}$ ]] &&
           jq -e ".state==\"running\"" "$PORTAL_TASK_DIR/$request_id.json" >/dev/null 2>&1; then
            write_task_status "$request_id" failed "更新未完成，请检查容器日志"
        fi
        rm -rf "$stage"
    ' EXIT
    write_task_status "$request_id" running "正在下载并校验配置"
    if ! load_subscriptions "" "$stage/input-subs.json"; then
        write_task_status "$request_id" failed "没有可用订阅"
        return 1
    fi
    IFS='|' read -r _ _ builtin <<< "$(read_settings)"
    subs_signature="$SUBS_SOURCE_HASH"
    settings_signature=$(sha256sum "$SETTINGS_PUBLIC" | cut -d' ' -f1)
    if [[ ( -n "$expected_subs" && "$expected_subs" != "$subs_signature" ) || ( -n "$expected_settings" && "$expected_settings" != "$settings_signature" ) ]]; then
        write_task_status "$request_id" failed "设置已发生变化，请重试"
        return 1
    fi
    active="${ACTIVE_SUB_INDEX:-0}"
    cache=$(subscription_cache_file_by_index "$active")
    if [[ "$scope" == "all" ]]; then
        targets=("${!SUBS_URLS_ARRAY[@]}")
    elif [[ "$scope" != "switch" || ! -s "$cache" ]]; then
        targets=("$active")
    fi
    for idx in "${targets[@]}"; do
        header="$stage/$idx.headers"
        if curl_subscription "${SUBS_URLS_ARRAY[$idx]}" "$header" "$stage/$idx.sub" "$SUBSCR_DOWNLOAD_MAX_TIME" && [[ -s "$stage/$idx.sub" ]]; then
            if generate_config "$stage/$idx.sub" "$stage/$idx.yaml" "$builtin" && validate_generated_config "$stage/$idx.yaml"; then
                SUBS_UPDATED_ARRAY[$idx]=$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S')
                SUBS_ERRORS_ARRAY[$idx]=""
                SUBS_NAMES_ARRAY[$idx]=$(derive_subscription_name "${SUBS_URLS_ARRAY[$idx]}" "$header")
                update_subscription_info_from_header "$header" "$idx" false
                [[ "$idx" != "$active" ]] || downloaded=true
                continue
            fi
            SUBS_ERRORS_ARRAY[$idx]="订阅配置无效，已保留上一次可用缓存"
        else
            SUBS_ERRORS_ARRAY[$idx]="下载失败，已保留上一次可用缓存"
        fi
        rm -f "$stage/$idx.sub" "$stage/$idx.yaml"
        failures=$((failures + 1))
    done
    if [[ "$subs_signature" != "$(sha256sum "$SUBSCRIPTIONS_PUBLIC" | cut -d' ' -f1)" || "$settings_signature" != "$(sha256sum "$SETTINGS_PUBLIC" | cut -d' ' -f1)" ]]; then
        write_task_status "$request_id" failed "下载期间设置发生变化，请重试更新"
        return 1
    fi
    # A failed active download is an error, even when the previous cache exists.
    # At startup the previous cache can still start the service while offline.
    if [[ "$mode" != "initial" && ( "$scope" != "switch" || ! -s "$cache" ) && "$downloaded" != "true" ]]; then
        local active_error="${SUBS_ERRORS_ARRAY[$active]:-当前订阅更新失败}"
        load_subscriptions "$stage/input-subs.json" || true
        SUBS_ERRORS_ARRAY[$active]="$active_error"
        write_subscriptions_state "$SUBSCRIPTIONS_FILE"
        [[ "$mode" != "switch" ]] || restore_applied_selection
        write_task_status "$request_id" failed "当前订阅下载或校验失败，已保留原配置"
        return 1
    fi
    candidate="$stage/candidate.yaml"
    local source="$cache"
    [[ ! -s "$stage/$active.sub" ]] || source="$stage/$active.sub"
    if ! generate_config "$source" "$candidate" "$builtin" || ! validate_generated_config "$candidate"; then
        restore_applied_selection
        write_task_status "$request_id" failed "配置校验失败，已恢复原选择和配置"
        return 1
    fi
    if [[ "$subs_signature" != "$(sha256sum "$SUBSCRIPTIONS_PUBLIC" | cut -d' ' -f1)" || "$settings_signature" != "$(sha256sum "$SETTINGS_PUBLIC" | cut -d' ' -f1)" ]]; then
        write_task_status "$request_id" failed "校验期间设置发生变化，请重试"
        return 1
    fi
    if [[ -f "$CONFIG_FILE" ]]; then cp "$CONFIG_FILE" "$stage/previous.yaml" || return 1; fi
    cp "$candidate" "$CONFIG_FILE.new" || return 1
    mv "$CONFIG_FILE.new" "$CONFIG_FILE" || return 1
    if [[ "$mode" != "initial" ]] && ! reload_clash_via_api; then
        if [[ -f "$stage/previous.yaml" ]]; then
            mv "$stage/previous.yaml" "$CONFIG_FILE"
            reload_clash_via_api || log "WARNING: Failed to reload previous configuration."
        else
            rm -f "$CONFIG_FILE"
        fi
        load_subscriptions "$stage/input-subs.json" || true
        SUBS_ERRORS_ARRAY[$active]="配置应用失败，已保留原缓存"
        restore_applied_selection
        write_task_status "$request_id" failed "配置应用失败，已恢复原配置"
        return 1
    fi
    for idx in "${targets[@]}"; do
        [[ -s "$stage/$idx.sub" ]] || continue
        mv "$stage/$idx.sub" "$(subscription_cache_file_by_index "$idx")"
    done
    cp "$cache" "$DEBUG_RAW_CONFIG"
    jq -n --arg url "${SUBS_URLS_ARRAY[$active]}" --argjson builtin "$builtin" \
        '{url:$url,builtinEnabled:$builtin}' > "$APPLIED_STATE_FILE.tmp"
    mv "$APPLIED_STATE_FILE.tmp" "$APPLIED_STATE_FILE"
    write_subscriptions_state "$SUBSCRIPTIONS_FILE"
    if [[ "$settings_signature" == "$(sha256sum "$SETTINGS_PUBLIC" | cut -d' ' -f1)" ]]; then
        cp "$SETTINGS_PUBLIC" "$SETTINGS_FILE"
    fi
    write_subscription_info_from_cache_index "$active" || true
    write_portal_status
    local message="配置已成功应用"
    [[ "$failures" -eq 0 ]] || message="配置已应用，部分订阅更新失败，保留原缓存"
    write_task_status "$request_id" success "$message"
    log "$message"
)

# ========= 主逻辑 =========

# 0. 启动快捷入口页面
validate_environment
rm -f /tmp/portal-core-started /tmp/portal-auto-worker.pid
init_subscriptions
start_portal
update_geodata_resources
watch_portal_update &
echo "$!" > /tmp/portal-worker.pid

# 1. 首次运行：等待订阅，然后执行更新和配置生成
wait_for_subscriptions
update_resources "initial" active "$(jq -r '.requestId // empty' "$SUBSCRIPTIONS_PUBLIC")"

# 2. 启动后台自动更新循环
auto_update_loop &
echo "$!" > /tmp/portal-auto-worker.pid

# 3. 启动 mihomo (前台运行)
# 使用 exec 替换当前 shell 进程，让 clash 成为 PID 1 (或继承 PID)
log "Starting clash (mihomo) in foreground..."
export SAFE_PATHS="/opt/ui"
touch /tmp/portal-core-started
exec clash -d "$CONFIG_DIR"
