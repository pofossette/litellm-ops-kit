# LiteLLM Ops Kit

基于 [LiteLLM](https://github.com/BerriAI/litellm) 的本地 AI 模型网关，聚合多个云服务商的 Anthropic / OpenAI 兼容端点，为 Claude Code 等工具提供统一入口。

## 架构

```
Claude Code / 客户端
        │
  ▼
  LiteLLM Gateway (:4000)
     ┌────┴────┐
     ▼         ▼
   Main     Fallback
  Provider   Provider
```

- 同一模型名下同时挂载 Anthropic 协议和 OpenAI 协议路由，LiteLLM 自动负载均衡
- 主 provider 先尝试，失败后自动切到 fallback provider
- 支持最多 3 级 fallback，且可以通过 `manage.sh` 直接配置和重渲染路由
- PostgreSQL 持久化 LiteLLM 配置与用量数据

## 模型路由

| 模型名 | Main provider | Fallback provider |
|--------|---------------|-------------------|
| `claude-opus-4.6` | anthropic + openai | anthropic + openai |
| `claude-sonnet-4.6` | anthropic + openai | anthropic + openai |
| `claude-haiku-4.5` | anthropic + openai | anthropic + openai |

## 快速开始

```bash
# 1. 从模板创建配置
./manage.sh init

# 2. 编辑 .env，填入实际的端点地址和密钥
vim .env

# 3. 启动服务
./manage.sh start
```

## 配置说明

所有配置集中在 `.env` 文件中（从 `.env.example` 复制而来）：

```bash
# ── 通用 ──
LITELLM_PORT=4000                    # 网关监听端口
LITELLM_MASTER_KEY=sk-xxx            # 网关认证密钥

# ── 主 provider ──
MAIN_ANTHROPIC_API_BASE=...          # Anthropic 兼容端点
MAIN_ANTHROPIC_API_KEY=...
MAIN_OPENAI_API_BASE=...             # OpenAI 兼容端点
MAIN_OPENAI_API_KEY=...
MAIN_OPUS_MODEL=...                  # 模型标识
MAIN_SONNET_MODEL=...
MAIN_HAIKU_MODEL=...

# ── fallback provider ──
FALLBACK_ANTHROPIC_API_BASE=...
FALLBACK_ANTHROPIC_API_KEY=...
FALLBACK_OPENAI_API_BASE=...
FALLBACK_OPENAI_API_KEY=...
FALLBACK_OPUS_MODEL=...
FALLBACK_SONNET_MODEL=...
FALLBACK_HAIKU_MODEL=...

# ── optional extra fallback providers ──
FALLBACK2_ANTHROPIC_API_BASE=
FALLBACK2_ANTHROPIC_API_KEY=
FALLBACK2_OPENAI_API_BASE=
FALLBACK2_OPENAI_API_KEY=
FALLBACK2_OPUS_MODEL=
FALLBACK2_SONNET_MODEL=
FALLBACK2_HAIKU_MODEL=

FALLBACK3_ANTHROPIC_API_BASE=
FALLBACK3_ANTHROPIC_API_KEY=
FALLBACK3_OPENAI_API_BASE=
FALLBACK3_OPENAI_API_KEY=
FALLBACK3_OPUS_MODEL=
FALLBACK3_SONNET_MODEL=
FALLBACK3_HAIKU_MODEL=
```

## Provider 管理

`manage.sh` 现在可以直接管理 provider tiers，并在修改后重新生成 LiteLLM 路由配置。
默认直接运行 `./manage.sh` 会进入数字菜单，适合不想记命令的场景。

```bash
./manage.sh provider list
./manage.sh provider configure
./manage.sh provider edit main
./manage.sh provider edit fallback
./manage.sh provider edit fallback2
./manage.sh provider edit fallback3
./manage.sh provider disable fallback2
./manage.sh provider render
```

规则：

- `main` 必填
- `fallback`、`fallback2`、`fallback3` 可选
- fallback tier 只能连续配置，不能跳级
- 最多允许 3 级 fallback
- 菜单里可以直接选择 `list`、`configure`、`edit`、`disable`、`render`

## 客户端接入

网关默认监听 `0.0.0.0`，局域网内可直接访问。将以下地址中的 `<HOST>` 替换为运行网关的机器 IP。

### Claude Code

```bash
export ANTHROPIC_BASE_URL=http://<HOST>:4000
export ANTHROPIC_AUTH_TOKEN=<LITELLM_MASTER_KEY>
export ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-4.6
export ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-4.6
export ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-haiku-4.5
```

### OpenAI 兼容客户端

```bash
export OPENAI_API_BASE=http://<HOST>:4000/v1
export OPENAI_API_KEY=<LITELLM_MASTER_KEY>
# 使用模型名: claude-opus-4.6 / claude-sonnet-4.6 / claude-haiku-4.5
```

## 管理命令

```bash
./manage.sh start              # 启动
./manage.sh stop               # 停止
./manage.sh restart            # 重启
./manage.sh status             # 查看容器状态
./manage.sh logs               # 查看日志
./manage.sh proxy configure    # 配置反向代理
./manage.sh proxy list         # 查看反向代理状态
./manage.sh proxy export-cert  # 导出外部 HTTPS 入口证书
./manage.sh enable-autostart   # 启用开机自启 (systemd)
./manage.sh disable-autostart  # 禁用开机自启
```

直接运行 `./manage.sh` 可进入交互菜单。

## 文件结构

```
├── .env                  # 本地配置（不提交）
├── .env.example          # 配置模板
├── docker-compose.yml    # Docker Compose 定义
├── litellm/
│   └── config.yaml       # LiteLLM 模型路由配置
├── manage.sh             # 管理脚本
└── README.md
```

## Admin UI

启动后访问 `http://<HOST>:4000/ui`，使用 `LITELLM_MASTER_KEY` 登录，可查看用量、调试请求等。

## HTTPS / FRP 说明

- 当前项目中的 LiteLLM 镜像不支持 `--proxy_headers` 启动参数，把它加到 compose 会导致容器启动失败并持续重启。
- 如果通过 `sakurafrp` 暴露本机 `4000`，推荐保持本机 LiteLLM 继续监听明文 HTTP，由 FRP 侧负责 HTTPS 终止。
- 这类场景下，先确认本地可访问 `http://127.0.0.1:4000/ui`，再映射 FRP 地址；如果本地都不通，FRP 侧只会表现为 `connection reset by peer`。
- 项目现在内置了可选的反向代理层，先支持 `nginx`，同时支持 `external` 自管模式，通过 `./manage.sh proxy configure` 统一配置。
- `proxy configure` 会先探测当前机器上是否已有 `nginx/caddy/traefik/haproxy/apache` 等反代进程或容器；如果你已经自行启用了反代，选 `external` 即可，脚本不会接管该服务。
- 启用代理后，主流程只需要两个端口：`nginx监听端口` 是本机代理监听端口，`litellm监听端口` 自动使用 LiteLLM 的 `LITELLM_PORT`。
- 针对 SakuraFRP 这类“外层 HTTPS 终止、本机明文 HTTP 反代”的场景，内置 nginx 模板会重写 LiteLLM 返回的绝对 `Location` 跳转，避免 `/ui/login` 之类的尾斜杠跳转被错误降成 `http://...` 后再被 FRP 侧拒绝。
- 建议把 `sakurafrp` 的本地目标端口改为 `nginx监听端口`。例如：LiteLLM 监听 `4000`，Nginx 监听 `8080`，则 FRP 本地目标填 `8080`。
- 如果外部入口使用自签证书，可运行 `./manage.sh proxy export-cert <host:port>` 导出证书；若 `.env` 中已设置 `PROXY_BASE_URL`，也可以直接运行 `./manage.sh proxy export-cert` 自动推断目标地址，默认输出到 `proxy/certs/`。
