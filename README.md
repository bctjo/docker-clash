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

2. 打开 `http://localhost:9090`

3. 在全屏初始化页设置管理用户名和密码，输入 Clash YAML 订阅链接，或上传本地 `.yaml` / `.yml` 文件，然后完成校验。

初始化会校验订阅配置并等待 Mihomo 启动。全部完成后自动进入控制台。失败时可修正配置并重试。

进入控制台后，可在“订阅”中上传、切换或替换本地 YAML。文件最大 16 MiB，保存在 `data/local-subscriptions/`。定时更新只下载链接订阅，本地配置可通过重新上传更新。

内置规则模板默认关闭，使用订阅自带的分组和规则。因此默认需要包含 `rules` 的完整 Clash YAML 配置（或 `mode: global` 的配置）。只有节点列表的 YAML 订阅需要在设置中开启内置规则模板；节点 URI 和 Base64 订阅需要先转换为 Clash YAML。

启用内置模板时，“🚀 默认代理”优先选择“⚡ 自动选择”（全部节点自动测速），其次才是香港等地区分组。已有的模板开关和手动选择继续保留。

旧订阅中的 `global-client-fingerprint` 会在生成配置时迁移为支持该选项的节点的 `client-fingerprint`，保留节点显式设置（包括 `none`）。完整配置和内置模板模式均支持。HTTP / file / inline 类型的 `proxy-providers` 通过条件覆写在加载及更新时补齐缺少的指纹，保留已有覆写表达式的优先级。最终配置移除旧全局字段，原始订阅缓存保持原样。provider 迁移使用 `override-expr`，自定义旧内核需确认支持该功能。项目固定的 Mihomo 版本见 [core/mihomo-version.txt](core/mihomo-version.txt)。

## 管理账号与升级

已有自设管理密码会迁移并继续生效，旧版用户名仍为 `admin`。曾经免登录或只使用自动生成密码的实例会先要求设置自己的账号和密码。已有可用订阅会沿用，订阅不可用时初始化页会要求重新导入。旧版的 `PORTAL_AUTH_ENABLED=false` 已失效。

Portal 将管理用户名、加盐后的密码哈希、订阅选择和页面设置保存到 `data/.env`，容器启动时自动读取。文件权限为 `0600`。登录后可在“设置 → 修改管理密码”更换密码，新密码立即生效并在重启后保留。

也可以用项目根目录的 `.env` 预设管理账号和订阅。

```dotenv
PORTAL_ADMIN_USERNAME=admin
PORTAL_ADMIN_KEY=你的密码
SUBSCR_URLS=https://example.com/subscription.yaml
```

未指定用户名时使用 `admin`。已保存的订阅优先于 `SUBSCR_URLS`，容器会验证订阅并在服务启动后开放控制台。需要通过环境变量重置管理密码时，使用新的 `PORTAL_ADMIN_KEY` 值并执行 `docker compose up -d`。

## API 密钥

API 密钥与管理密码独立，默认自动生成并保存到 `data/portal.json`。从旧版免登录模式升级时，自动管理的密钥会更新一次；后续重启保持不变。面板从 Portal 重新打开即可使用当前密钥。

需要手动轮换时，在 `.env` 中将 `CLASH_SECRET` 设置为新值（可用 `openssl rand -hex 24` 生成），然后运行 `docker compose up -d --force-recreate`。显式设置的 `CLASH_SECRET` 优先于自动管理的密钥，升级时也会保留。修改管理密码不会更改 API 密钥，二者需要分别管理。

## 默认端口

- `9090`: Portal、全部 Dashboard 和 Clash API 的统一入口
- `9097`: 容器内 Clash API 端口（默认仅监听回环地址，不映射）
- `7890`: HTTP 代理
- `7891`: SOCKS5 代理
- `7892`: TPROXY
- `7893`: MIXED

如需调整，可在 `docker-compose.yml` 中修改环境变量。

外网只需穿透 Web 端口 `9090`。从 Portal 点击 Metacubexd、Zashboard 或 Yacd，面板页面、API、连接和日志的 WebSocket 都使用当前访问的域名、协议和端口；支持穿透服务将外部 HTTPS 域名或其他端口映射到容器的 `9090`。无需额外穿透 `9097`，也无需手动填写控制地址或 API 密钥。穿透服务需支持 WebSocket。

内部 `DASH_PORT` 与 `PORTAL_PORT` 仍应使用不同端口。需要直接连接内核 API 时，在 `.env` 中设置 `DASH_BIND_ADDRESS=0.0.0.0`，并取消 Compose 中 `127.0.0.1:9097:9097` 的注释；直连仍使用 API 密钥。通过 Portal 访问面板和 API 无需更改这些设置。公网管理入口使用 HTTPS。

## 可选：代理用户名和密码

打开 Portal 的“设置 → 代理认证”，填写代理用户名和密码并保存，即可为 HTTP、SOCKS 和 Mixed 代理开启认证。两项都留空并保存，则无需认证；只填写其中一项会提示补全。

代理认证与 Portal 管理密码、Clash API 密钥相互独立，不适用于 TPROXY 透明代理。设置随 Portal 配置保存到 `data/.env`，应用失败会恢复原认证设置，重启、切换订阅和更新订阅后继续生效。开启代理认证后，内置代理规则延迟检测也会携带认证信息。

Portal 保存的代理认证设置优先于订阅中的 `authentication` 和 `skip-auth-prefixes`。升级前已在订阅中设置认证、且尚未通过 Portal 保存代理认证字段时，会保留订阅的原设置。

## 镜像来源

默认 `docker-compose.yml` 使用：

- `ghcr.nju.edu.cn/bctjo/docker-clash:latest`

## 为什么更稳定

容器启动与更新流程包含以下保护机制：

- 内置 geodata 初始化后可在后台更新（`Country.mmdb` / `GeoSite.dat` / `GeoIP.dat`）
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

- `SUBSCR_URLS`: 首次初始化的订阅地址（逗号分隔）
- `SUBSCR_VALIDATE_MAX_TIME`: 导入订阅时单次校验下载超时（秒，默认 120）
- `SUBSCR_DOWNLOAD_MAX_TIME`: 更新订阅时单次下载超时（秒，默认 120）
- `SUBSCR_CONNECT_TIMEOUT`: 订阅下载连接超时（秒，默认 15）
- `PORTAL_ADMIN_USERNAME`: 可选的管理用户名，与预设密码一起使用
- `PORTAL_ADMIN_KEY`: 可选的预设管理密码；留空时可在初始化页设置
- `CONFIG_VALIDATE_MAX_TIME`: 配置校验超时（秒，默认 90）
- `SUBSCR_MAX_BYTES`: 订阅最大下载大小（字节，默认 16 MiB）
- `UPDATE_INTERVAL`: 自动更新间隔（秒，默认 43200）
- `CLASH_SECRET`: API 密钥（留空自动管理；设置新值并重建容器可轮换）
- `DASH_BIND_ADDRESS`: 核心 API 监听地址（默认 `127.0.0.1`；显式直连时可设为 `0.0.0.0`）

更多配置可查看 `docker-compose.yml`。

管理密码保护管理操作、连接密钥、代理认证设置及订阅信息。面板 API 继续由 Clash API 密钥认证，首页自动连接但不展示该密钥。HTTP / SOCKS / Mixed 代理自身的账号密码在“设置 → 代理认证”中配置。

延迟检测有两种模式：“容器直连检测”从容器发起连接，“代理规则检测”通过 Mixed 端口按当前规则访问各个目标；这两种检测都不代表浏览器所在设备的网络。

## 数据持久化

项目将运行数据保存在 `data/` 目录，包含：

- 运行配置与原始订阅配置
- geodata 文件
- Portal 配置文件 `data/.env`、订阅缓存和运行状态

迁移或备份时保留该目录即可。

## 自动发布（mihomo 更新驱动）

- Workflow `Auto Release On Mihomo Update` 会每 6 小时检查一次 `MetaCubeX/mihomo` 最新版本。
- 若有更新，先准备版本提交并构建、发布多架构镜像；成功后才把内核版本提交和项目 tag 一起推送（补丁位自动加 1，例如 `v1.0.7 -> v1.0.8`）。构建失败时，下次检查继续重试。
- 自动发布和手动发布共用构建步骤及发布锁，避免并发覆盖 `latest`。
- 自动流程直接创建正式 Release，并在后续运行补建中断的发布，不依赖机器人推送 tag 触发另一份工作流。内核更新提交会注明前后版本。
- 版本查询带认证、超时和重试；镜像记录实际版本提交的 SHA。
- `Runtime checks` 工作流在 main 更新和 PR 时执行配置测试及隔离容器的更新、回滚、重启测试。
- 发布构建时会优先读取 `core/mihomo-version.txt`，确保镜像内核版本可追溯。

项目功能更新使用新的版本 tag 发布，例如 `v1.1.0`；仅推送 main 会运行检查，不会发布镜像。tag 发布会更新对应版本的镜像和 `latest`，同时创建包含源码包与版本说明的正式 Release。功能变更和升级说明记录在 [CHANGELOG.md](CHANGELOG.md)。

提交说明按改动类型区分：`🐞 fix` 用于缺陷修复，`✨ feat` 用于功能，`🚀 ci(release)` 用于发布，`🔧 chore(core)` 用于内核升级，`📝 docs` 用于文档，`✅ test` 用于测试。每条说明描述具体变化，避免把多类改动都写成同一句话。

## 本地构建（可选）

从源码构建镜像，构建时会自动下载 `core/mihomo-version.txt` 指定的 mihomo 内核。

```bash
docker build -t clash-meta:local .
```

如需临时使用其他内核版本，可传入 `--build-arg MIHOMO_VERSION=v1.19.20`。部署自建镜像时，将 Compose 中的 `image` 改为所构建的镜像标签。

## 本地验证

测试使用临时数据目录和本地订阅服务器，不接触 `data/` 中的实际订阅：

```bash
docker build -t clash-meta-review:local .
docker run --rm --entrypoint python3 -v "$PWD:/src:ro" -w /src clash-meta-review:local -m unittest discover -s tests -p 'test_*.py' -v
python3 tests/integration.py
node tests/check_frontend.cjs
```

只验证配置和指纹兼容性时，本机安装 PyYAML 后可运行：

```bash
python3 -m unittest discover -s tests -p 'test_config_tool.py' -v
MIHOMO_BIN=/path/to/mihomo python3 -m unittest discover -s tests -p 'test_fingerprint_runtime.py' -v
```

指纹运行测试使用本地模拟端点捕获 VLESS + REALITY 的 TLS ClientHello，对比继承值、节点显式值及 provider 覆写和更新后的实际指纹；不使用真实订阅，也不代表真实节点的端到端连通性。容器中的配置测试会自动使用 `/usr/bin/clash` 运行此测试；本机未提供内核时跳过。

可选浏览器测试需要 Playwright 及 Chromium：`RUN_BROWSER_TESTS=1 python3 tests/integration.py`。

本地构建需要更换 APT 源时，可添加 `--build-arg APT_MIRROR=mirrors.ustc.edu.cn`；默认使用 Debian 官方源。
