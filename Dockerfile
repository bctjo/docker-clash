FROM debian:12-slim

ARG APP_VERSION="dev"
ARG APP_REVISION="unknown"
ARG APP_SOURCE="https://github.com/bctjo/docker-clash"
ARG TARGETARCH

# 切换 APT 源为 USTC（Debian 12 / bookworm，.sources 格式）
RUN sed -i 's@deb.debian.org@mirrors.ustc.edu.cn@g' /etc/apt/sources.list.d/debian.sources && \
    sed -i 's@security.debian.org@mirrors.ustc.edu.cn@g' /etc/apt/sources.list.d/debian.sources && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        jq \
        nginx \
        openssl \
        tzdata && \
    rm -f /etc/nginx/sites-enabled/default && \
    rm -rf /var/lib/apt/lists/*

# mihomo 内核（按架构选择，命名为 clash，entrypoint 无需改）
COPY core/clash-linux-${TARGETARCH} /usr/bin/clash

# UI（external-ui）
ARG METACUBEXD_REPO="MetaCubeX/metacubexd"
ARG METACUBEXD_REF="gh-pages"
ARG ZASHBOARD_REPO="Zephyruso/zashboard"
ARG ZASHBOARD_REF="gh-pages"
ARG YACD_REPO="MetaCubeX/Yacd-meta"
ARG YACD_REF="gh-pages"

RUN set -eux; \
    mkdir -p /opt/ui/metacubexd /opt/ui/zashboard /opt/ui/yacd /opt/portal; \
    curl -fsSL "https://codeload.github.com/${METACUBEXD_REPO}/tar.gz/refs/heads/${METACUBEXD_REF}" | tar -xzf - -C /opt/ui/metacubexd --strip-components=1; \
    curl -fsSL "https://codeload.github.com/${ZASHBOARD_REPO}/tar.gz/refs/heads/${ZASHBOARD_REF}" | tar -xzf - -C /opt/ui/zashboard --strip-components=1; \
    curl -fsSL "https://codeload.github.com/${YACD_REPO}/tar.gz/refs/heads/${YACD_REF}" | tar -xzf - -C /opt/ui/yacd --strip-components=1; \
    BUILD_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
    VERSION_OUT="$APP_VERSION"; \
    REVISION_OUT="$APP_REVISION"; \
    [ "$VERSION_OUT" = "dev" ] && VERSION_OUT="dev-${BUILD_AT}"; \
    [ "$REVISION_OUT" = "unknown" ] && REVISION_OUT=""; \
    printf '{"version":"%s","revision":"%s","source":"%s","builtAt":"%s"}\n' "$VERSION_OUT" "$REVISION_OUT" "$APP_SOURCE" "$BUILD_AT" > /opt/portal/project-version.json

# 构建阶段预置 geodata，供弱网首启兜底
RUN set -eux; \
    mkdir -p /opt/geodata; \
    download_geodata() { \
      target="$1"; shift; \
      for url in "$@"; do \
        [ -n "$url" ] || continue; \
        if curl -fsSL --retry 2 --retry-delay 2 --connect-timeout 10 --max-time 180 "$url" -o "${target}.tmp"; then \
          if [ -s "${target}.tmp" ]; then \
            mv "${target}.tmp" "$target"; \
            return 0; \
          fi; \
          rm -f "${target}.tmp"; \
        fi; \
      done; \
      rm -f "${target}.tmp"; \
      return 1; \
    }; \
    download_geodata /opt/geodata/Country.mmdb \
      "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/country.mmdb" \
      "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/release/country.mmdb" \
      "https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/country.mmdb"; \
    download_geodata /opt/geodata/GeoSite.dat \
      "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat" \
      "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/release/geosite.dat" \
      "https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geosite.dat"; \
    download_geodata /opt/geodata/GeoIP.dat \
      "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.dat" \
      "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/release/geoip.dat" \
      "https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geoip.dat"

# 快捷入口页面
COPY portal/index.html /opt/portal/index.html
COPY portal/vendor /opt/portal/vendor
COPY nginx/portal.conf /etc/nginx/conf.d/portal.conf

RUN chown -R www-data:www-data /opt/portal && chmod 775 /opt/portal

# 启动脚本
COPY entrypoint.sh /entrypoint.sh
COPY config.yaml.template /opt/builtin-rules.yaml
COPY scripts/connectivity_probe.sh /opt/scripts/connectivity_probe.sh
COPY scripts/proxy_connectivity_probe.sh /opt/scripts/proxy_connectivity_probe.sh

RUN chmod +x /usr/bin/clash /entrypoint.sh /opt/scripts/connectivity_probe.sh /opt/scripts/proxy_connectivity_probe.sh

WORKDIR /root/.config/clash
ENTRYPOINT ["/entrypoint.sh"]
