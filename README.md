# Clash Meta Docker

一个开箱即用的 Clash Meta（mihomo）容器方案。

你只需要启动容器、填入订阅，就可以通过统一 Portal 完成配置、更新和状态查看，不需要手动改一堆配置文件。

## 这是什么

这个项目把 Clash Meta 的日常使用流程做成了一个完整产品化体验：

- 内置 Portal 管理页面，先用再折腾
- 内置多套 Web UI（metacubexd / zashboard / yacd）
- 自动处理 geodata 下载、配置校验和失败回滚
- 支持定时更新与手动更新，减少断流和重启循环

## 3 分钟上手

1. 启动服务

```bash
docker compose up -d
```

2. 打开 Portal

- `http://localhost:9090`

3. 填写订阅地址并保存

保存后会自动生成并应用配置，随后即可在面板中使用。

## 默认端口

- `9090`: Portal
- `9097`: Clash API / Dashboard
- `7890`: HTTP 代理
- `7891`: SOCKS5 代理
- `7892`: TPROXY
- `7893`: MIXED

如需调整，可在 `docker-compose.yml` 中修改环境变量。

## 镜像来源

默认 `docker-compose.yml` 使用：

- `ghcr.nju.edu.cn/bctjo/docker-clash:latest`

## 为什么更稳定

容器启动与更新流程包含以下保护机制：

- geodata 预下载（`Country.mmdb` / `GeoSite.dat` / `GeoIP.dat`）
- 构建阶段内置 geodata，弱网首启可直接使用镜像内文件
- 首次启动 geodata 下载失败/超时会自动熔断本次自动更新，避免反复重试阻塞
- 配置应用前执行 `clash -t` 校验
- 下载失败自动重试与多源回退
- 更新失败自动回滚到可用文件

这可以明显降低“配置更新后服务起不来”的概率。

## 常用配置项

你通常只需要关心这几个：

- `SUBSCR_URLS`: 订阅地址（逗号分隔）
- `SUBSCR_VALIDATE_MAX_TIME`: 导入订阅时单次校验下载超时（秒，默认 120）
- `SUBSCR_DOWNLOAD_MAX_TIME`: 更新订阅时单次下载超时（秒，默认 120）
- `SUBSCR_CONNECT_TIMEOUT`: 订阅下载连接超时（秒，默认 15）
- `PORTAL_ADMIN_KEY`: Portal 管理密码
- `UPDATE_INTERVAL`: 自动更新间隔（秒，默认 43200）
- `CLASH_SECRET`: API 密钥（为空会自动生成）

更多配置可查看 `docker-compose.yml`。

## 数据持久化

项目将运行数据保存在 `data/` 目录，包含：

- 运行配置与原始订阅配置
- geodata 文件
- Portal 设置、订阅和状态

迁移或备份时保留该目录即可。

## 自动发布（mihomo 更新驱动）

- Workflow `Auto Release On Mihomo Update` 会每 6 小时检查一次 `MetaCubeX/mihomo` 最新版本。
- 若有更新，会把 `core/mihomo-version.txt` 更新为最新内核版本，并自动把项目 tag 的补丁位加 1（例如 `v1.0.7 -> v1.0.8`），随后触发发布流程。
- 发布构建时会优先读取 `core/mihomo-version.txt`，确保镜像内核版本可追溯。

## 本地构建（可选）

如果你想自己构建镜像：

默认会在构建时自动下载 mihomo 内核，版本来自 `core/mihomo-version.txt`。

你也可以通过构建参数临时覆盖版本：

```bash
docker build --build-arg MIHOMO_VERSION=v1.19.20 -t clash-meta-dev:local .
```

```bash
docker compose -f docker-compose.dev.yml up --build
```

这个文件使用 bridge + 显式端口映射，适合本地开发测试。
