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
| `my-opus` | anthropic + openai | anthropic + openai |
| `my-sonnet` | anthropic + openai | anthropic + openai |
| `my-haiku` | anthropic + openai | anthropic + openai |

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
export ANTHROPIC_DEFAULT_OPUS_MODEL=my-opus
export ANTHROPIC_DEFAULT_SONNET_MODEL=my-sonnet
export ANTHROPIC_DEFAULT_HAIKU_MODEL=my-haiku
```

### OpenAI 兼容客户端

```bash
export OPENAI_API_BASE=http://<HOST>:4000/v1
export OPENAI_API_KEY=<LITELLM_MASTER_KEY>
# 使用模型名: my-opus / my-sonnet / my-haiku
```

## 管理命令

```bash
./manage.sh start              # 启动
./manage.sh stop               # 停止
./manage.sh restart            # 重启
./manage.sh status             # 查看容器状态
./manage.sh logs               # 查看日志
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
