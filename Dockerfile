FROM node:22.18.0-alpine3.22 AS yacd-build

WORKDIR /app
COPY ui/yacd/package.json ui/yacd/pnpm-lock.yaml ./
RUN corepack enable && pnpm install --frozen-lockfile
COPY ui/yacd/ .
RUN pnpm build

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
RUN mkdir -p /opt/ui /opt/portal
COPY ui/metacubexd /opt/ui/metacubexd
COPY ui/zashboard /opt/ui/zashboard
COPY --from=yacd-build /app/public /opt/ui/yacd

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
