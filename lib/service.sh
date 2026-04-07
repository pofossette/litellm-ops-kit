#!/usr/bin/env bash
# lib/service.sh — Docker lifecycle, systemd autostart, startup info

print_startup_info() {
  load_env
  local port="${LITELLM_PORT:-4000}"
  local autostart_state="disabled"
  local host_ip
  host_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"

  if systemctl --user is-enabled "$SERVICE_NAME" >/dev/null 2>&1; then
    autostart_state="enabled"
  fi

  cat <<EOF
Service started.

Gateway:
  Local:   http://127.0.0.1:${port}
  LAN:     http://${host_ip}:${port}
  Admin UI: http://${host_ip}:${port}/ui
  LiteLLM Master Key: ${LITELLM_MASTER_KEY}

Routing:
$(for level in "${!ROUTES[@]}"; do route_chain_summary "$level"; done)

Claude Code env:
  export ANTHROPIC_BASE_URL=http://${host_ip}:${port}
  export ANTHROPIC_AUTH_TOKEN=${LITELLM_MASTER_KEY}
  export ANTHROPIC_DEFAULT_OPUS_MODEL=my-opus
  export ANTHROPIC_DEFAULT_SONNET_MODEL=my-sonnet
  export ANTHROPIC_DEFAULT_HAIKU_MODEL=my-haiku

Checks:
  ./manage.sh status
  ./manage.sh logs
  ./manage.sh provider list

Autostart:
  ${autostart_state}
EOF
}

write_systemd_service() {
  mkdir -p "$SYSTEMD_USER_DIR"

  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=LiteLLM Ops Kit
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$PROJECT_DIR
ExecStart=/usr/bin/docker compose --env-file $ENV_FILE -f $COMPOSE_FILE up -d
ExecStop=/usr/bin/docker compose --env-file $ENV_FILE -f $COMPOSE_FILE down
TimeoutStartSec=0

[Install]
WantedBy=default.target
EOF
}

cmd_init() {
  ensure_env_file
  echo "Environment template is ready at $ENV_FILE"
}

cmd_start() {
  require_configured_env
  render_litellm_config
  compose up -d
  print_startup_info
}

cmd_stop() {
  ensure_env_file
  compose down
  echo "Service stopped."
}

cmd_restart() {
  require_configured_env
  render_litellm_config
  compose down
  compose up -d
  print_startup_info
}

cmd_status() {
  ensure_env_file
  compose ps
}

cmd_logs() {
  ensure_env_file
  compose logs --tail=200 -f
}

cmd_quickstart() {
  load_env
  local port="${LITELLM_PORT:-4000}"
  local host_ip
  host_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  local api_url="http://${host_ip}:${port}"

  cat <<EOF
============================================
  Quick Start — API 接入指引
============================================

API Endpoint:
  ${api_url}

API Key:
  ${LITELLM_MASTER_KEY}

Available Models:
  my-opus    -> Opus 模型路由
  my-sonnet  -> Sonnet 模型路由
  my-haiku   -> Haiku 模型路由

--------------------------------------------
  Claude Code 接入
--------------------------------------------
export ANTHROPIC_BASE_URL=${api_url}
export ANTHROPIC_AUTH_TOKEN=${LITELLM_MASTER_KEY}
export ANTHROPIC_DEFAULT_OPUS_MODEL=my-opus
export ANTHROPIC_DEFAULT_SONNET_MODEL=my-sonnet
export ANTHROPIC_DEFAULT_HAIKU_MODEL=my-haiku

--------------------------------------------
  curl 测试
--------------------------------------------
curl ${api_url}/v1/chat/completions \\
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \\
  -H "Content-Type: application/json" \\
  -d '{
    "model": "my-sonnet",
    "messages": [{"role": "user", "content": "Hello"}]
  }'

--------------------------------------------
  Python (OpenAI SDK)
--------------------------------------------
from openai import OpenAI

client = OpenAI(
    base_url="${api_url}/v1",
    api_key="${LITELLM_MASTER_KEY}",
)
response = client.chat.completions.create(
    model="my-sonnet",
    messages=[{"role": "user", "content": "Hello"}],
)
print(response.choices[0].message.content)

--------------------------------------------
  Python (Anthropic SDK)
--------------------------------------------
import anthropic

client = anthropic.Anthropic(
    base_url="${api_url}",
    api_key="${LITELLM_MASTER_KEY}",
)
message = client.messages.create(
    model="my-sonnet",
    max_tokens=1024,
    messages=[{"role": "user", "content": "Hello"}],
)
print(message.content[0].text)

============================================
EOF
}

cmd_enable_autostart() {
  require_configured_env
  render_litellm_config
  write_systemd_service
  systemctl --user daemon-reload
  systemctl --user enable "$SERVICE_NAME"
  systemctl --user start "$SERVICE_NAME"
  echo "Autostart enabled."
  echo "Systemd user service: $SERVICE_FILE"
  print_startup_info
}

cmd_disable_autostart() {
  if systemctl --user is-enabled "$SERVICE_NAME" >/dev/null 2>&1; then
    systemctl --user disable --now "$SERVICE_NAME"
  fi
  rm -f "$SERVICE_FILE"
  systemctl --user daemon-reload
  echo "Autostart disabled."
}
