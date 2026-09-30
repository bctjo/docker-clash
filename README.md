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

2. 设置或读取管理密码

可以在项目 `.env` 中设置 `PORTAL_ADMIN_KEY=你的密码`（参见 `.env.example`）。未设置时，首次启动自动生成密码，并保存在持久化目录中；通过以下命令读取：

```bash
docker compose exec -T clash cat /root/.config/clash/portal-admin.key
```

3. 打开 Portal 并登录（用户名固定为 `admin`）

- `http://localhost:9090`

4. 填写订阅地址并保存

保存时页面会等待后台校验和应用结果，成功后即可在面板中使用。

内置规则模板默认关闭，使用订阅自带的分组和规则。因此默认需要包含 `rules` 的完整 Clash YAML 配置（或 `mode: global` 的配置）。只有节点列表的 YAML 订阅需要在设置中开启内置规则模板；节点 URI 和 Base64 订阅需要先转换为 Clash YAML。

启用内置模板时，“🚀 默认代理”优先选择“⚡ 自动选择”（全部节点自动测速），其次才是香港等地区分组。已有的模板开关和手动选择继续保留。

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
- 新订阅下载到临时目录，下载成功且配置校验通过后再应用
- 配置通过 `/configs` 热加载，后台任务继续运行
- 配置应用失败恢复原配置和选择；失败下载不会覆盖可用缓存
- 订阅服务器离线时，重启优先保留并使用上一次可用缓存
- 后台任务按请求编号返回结果，多个请求不会相互覆盖
- Docker 健康检查覆盖 Portal、后台任务和 mihomo API

这可以明显降低“配置更新后服务起不来”的概率。

## 常用配置项

你通常只需要关心这几个：

- `SUBSCR_URLS`: 订阅地址（逗号分隔）
- `SUBSCR_VALIDATE_MAX_TIME`: 导入订阅时单次校验下载超时（秒，默认 120）
- `SUBSCR_DOWNLOAD_MAX_TIME`: 更新订阅时单次下载超时（秒，默认 120）
- `SUBSCR_CONNECT_TIMEOUT`: 订阅下载连接超时（秒，默认 15）
- `PORTAL_ADMIN_KEY`: Portal 管理密码（未指定时自动生成）
- `CONFIG_VALIDATE_MAX_TIME`: 配置校验超时（秒，默认 90）
- `SUBSCR_MAX_BYTES`: 订阅最大下载大小（字节，默认 16 MiB）
- `UPDATE_INTERVAL`: 自动更新间隔（秒，默认 43200）
- `CLASH_SECRET`: API 密钥（为空会生成并持久化；只向已登录用户提供）

更多配置可查看 `docker-compose.yml`。

Portal 密码保护管理操作、连接密钥及订阅信息。HTTP / SOCKS / Mixed 代理端口保持 LAN 访问方式；代理自身的账号密码通过 Clash 配置的 `authentication` 设置。

延迟检测有两种模式：“容器直连检测”从容器发起连接，“代理规则检测”通过 Mixed 端口按当前规则访问各个目标；这两种检测都不代表浏览器所在设备的网络。

## 数据持久化

项目将运行数据保存在 `data/` 目录，包含：

- 运行配置与原始订阅配置
- geodata 文件
- Portal 设置、订阅和状态

迁移或备份时保留该目录即可。

## 自动发布（mihomo 更新驱动）

- Workflow `Auto Release On Mihomo Update` 会每 6 小时检查一次 `MetaCubeX/mihomo` 最新版本。
- 若有更新，先准备版本提交并构建、发布多架构镜像；成功后才把内核版本提交和项目 tag 一起推送（补丁位自动加 1，例如 `v1.0.7 -> v1.0.8`）。构建失败时，下次检查继续重试。
- 自动发布和手动发布共用构建步骤及发布锁，避免并发覆盖 `latest`。
- 自动流程直接创建 Release 草稿，并在后续运行补建中断的草稿，不依赖机器人推送 tag 触发另一份工作流。
- 版本查询带认证、超时和重试；镜像记录实际版本提交的 SHA。
- `Runtime checks` 工作流在 main 更新和 PR 时执行配置测试及隔离容器的更新、回滚、重启测试。
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

## 本地验证

测试使用临时数据目录和本地订阅服务器，不接触 `data/` 中的实际订阅：

```bash
docker build -t clash-meta-review:local .
docker run --rm --entrypoint python3 -v "$PWD:/src:ro" -w /src clash-meta-review:local -m unittest discover -s tests -p 'test_*.py' -v
python3 tests/integration.py
node tests/check_frontend.cjs
```

可选浏览器测试需要 Playwright 及 Chromium：`RUN_BROWSER_TESTS=1 python3 tests/integration.py`。

本地构建需要更换 APT 源时，可添加 `--build-arg APT_MIRROR=mirrors.ustc.edu.cn`；默认使用 Debian 官方源。
