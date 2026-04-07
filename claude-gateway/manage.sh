#!/usr/bin/env bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
ENV_FILE="$PROJECT_DIR/.env"
ENV_EXAMPLE_FILE="$PROJECT_DIR/.env.example"
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SERVICE_NAME="claude-gateway.service"
SERVICE_FILE="$SYSTEMD_USER_DIR/$SERVICE_NAME"

ensure_env_file() {
  if [[ ! -f "$ENV_FILE" ]]; then
    cp "$ENV_EXAMPLE_FILE" "$ENV_FILE"
    echo "Created $ENV_FILE from template."
    echo "Edit the endpoint URLs, API keys, and model IDs before starting the service."
  fi
}

load_env() {
  ensure_env_file
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
}

require_configured_env() {
  load_env

  local missing=0
  local vars=(
    GLM_ANTHROPIC_API_BASE
    GLM_ANTHROPIC_API_KEY
    GLM_OPUS_MODEL
    GLM_SONNET_MODEL
    GLM_HAIKU_MODEL
    JD_ANTHROPIC_API_BASE
    JD_ANTHROPIC_API_KEY
    JD_OPUS_MODEL
    JD_SONNET_MODEL
    JD_HAIKU_MODEL
    LITELLM_MASTER_KEY
    DATABASE_URL
  )

  for var_name in "${vars[@]}"; do
    local value="${!var_name:-}"
    if [[ -z "$value" || "$value" == "replace-me" || "$value" == https://your-* || "$value" == "sk-local-gateway-change-me" ]]; then
      echo "Config error: $var_name is not set correctly in $ENV_FILE"
      missing=1
    fi
  done

  if [[ "$missing" -ne 0 ]]; then
    exit 1
  fi
}

compose() {
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

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
  my-opus   -> GLM (${GLM_OPUS_MODEL})   -> fallback JD (${JD_OPUS_MODEL})
  my-sonnet -> GLM (${GLM_SONNET_MODEL}) -> fallback JD (${JD_SONNET_MODEL})
  my-haiku  -> GLM (${GLM_HAIKU_MODEL})  -> fallback JD (${JD_HAIKU_MODEL})

Claude Code env:
  export ANTHROPIC_BASE_URL=http://${host_ip}:${port}
  export ANTHROPIC_AUTH_TOKEN=${LITELLM_MASTER_KEY}
  export ANTHROPIC_DEFAULT_OPUS_MODEL=my-opus
  export ANTHROPIC_DEFAULT_SONNET_MODEL=my-sonnet
  export ANTHROPIC_DEFAULT_HAIKU_MODEL=my-haiku

Checks:
  ./manage.sh status
  ./manage.sh logs

Autostart:
  ${autostart_state}
EOF
}

write_systemd_service() {
  mkdir -p "$SYSTEMD_USER_DIR"

  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Claude Code LiteLLM Gateway
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

cmd_enable_autostart() {
  require_configured_env
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

cmd_help() {
  cat <<EOF
Usage: ./manage.sh <command>

Commands:
  init               Create .env from template
  start              Start the LiteLLM gateway with Docker
  stop               Stop the LiteLLM gateway
  restart            Restart the LiteLLM gateway
  status             Show container status
  logs               Tail service logs
  enable-autostart   Enable and start the systemd user service
  disable-autostart  Disable the systemd user service
  help               Show this help
EOF
}

show_menu() {
  echo "Claude Gateway 管理器"
  echo "======================"
  echo "1) init               - 从模板创建 .env 文件"
  echo "2) start              - 使用 Docker 启动 LiteLLM 网关"
  echo "3) stop               - 停止 LiteLLM 网关"
  echo "4) restart            - 重启 LiteLLM 网关"
  echo "5) status             - 显示容器状态"
  echo "6) logs               - 查看服务日志"
  echo "7) enable-autostart   - 启用并启动 systemd 用户服务"
  echo "8) disable-autostart  - 禁用 systemd 用户服务"
  echo "0) exit               - 退出"
  echo ""
}

main() {
  if [[ $# -gt 0 ]]; then
    local cmd="$1"
    case "$cmd" in
      init) cmd_init ;;
      start) cmd_start ;;
      stop) cmd_stop ;;
      restart) cmd_restart ;;
      status) cmd_status ;;
      logs) cmd_logs ;;
      enable-autostart) cmd_enable_autostart ;;
      disable-autostart) cmd_disable_autostart ;;
      help|-h|--help) cmd_help ;;
      *)
        echo "Unknown command: $cmd" >&2
        cmd_help
        exit 1
        ;;
    esac
    return
  fi

  while true; do
    show_menu
    read -rp "Select an option [0-8]: " choice
    case "$choice" in
      1) cmd_init ;;
      2) cmd_start ;;
      3) cmd_stop ;;
      4) cmd_restart ;;
      5) cmd_status ;;
      6) cmd_logs ;;
      7) cmd_enable_autostart ;;
      8) cmd_disable_autostart ;;
      0) echo "Exiting."; exit 0 ;;
      *) echo "Invalid option. Please try again." ;;
    esac
    echo ""
  done
}

main "$@"
