FROM debian:12-slim

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

# mihomo 内核（命名为 clash，entrypoint 无需改）
COPY clash /usr/bin/clash

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
    curl -fsSL "https://codeload.github.com/${YACD_REPO}/tar.gz/refs/heads/${YACD_REF}" | tar -xzf - -C /opt/ui/yacd --strip-components=1

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
