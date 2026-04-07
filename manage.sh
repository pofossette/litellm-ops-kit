#!/usr/bin/env bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
ENV_FILE="$PROJECT_DIR/.env"
ENV_EXAMPLE_FILE="$PROJECT_DIR/.env.example"
CONFIG_FILE="$PROJECT_DIR/litellm/config.yaml"
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SERVICE_NAME="litellm-ops-kit.service"
SERVICE_FILE="$SYSTEMD_USER_DIR/$SERVICE_NAME"

MAX_FALLBACK_LEVELS=3
ROUTES=(my-opus my-sonnet my-haiku)
ROUTE_KEYS=(OPUS SONNET HAIKU)

# shellcheck source=lib/common.sh
source "$PROJECT_DIR/lib/common.sh"
# shellcheck source=lib/provider.sh
source "$PROJECT_DIR/lib/provider.sh"
# shellcheck source=lib/service.sh
source "$PROJECT_DIR/lib/service.sh"

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
  provider           Manage provider tiers and regenerate config
  quickstart         Show API endpoint, API key and integration guide
  enable-autostart   Enable and start the systemd user service
  disable-autostart  Disable the systemd user service
  help               Show this help

Provider subcommands:
  ./manage.sh provider list
  ./manage.sh provider configure
  ./manage.sh provider edit <main|fallback|fallback2|fallback3>
  ./manage.sh provider disable <fallback|fallback2|fallback3>
  ./manage.sh provider render
EOF
}

show_menu() {
  echo "LiteLLM Ops Kit"
  echo "======================"
  echo "1) init               - 从模板创建 .env 文件"
  echo "2) start              - 使用 Docker 启动 LiteLLM 网关"
  echo "3) stop               - 停止 LiteLLM 网关"
  echo "4) restart            - 重启 LiteLLM 网关"
  echo "5) status             - 显示容器状态"
  echo "6) logs               - 查看服务日志"
  echo "7) quickstart         - 查看快速接入指引 (API 端点 / API Key)"
  echo "8) enable-autostart   - 启用并启动 systemd 用户服务"
  echo "9) disable-autostart  - 禁用 systemd 用户服务"
  echo "p) provider           - 管理 provider tiers"
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
      provider) shift; cmd_provider "$@" ;;
      quickstart) cmd_quickstart ;;
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
    read -rp "Select an option [0-9/p]: " choice
    case "$choice" in
      1) cmd_init ;;
      2) cmd_start ;;
      3) cmd_stop ;;
      4) cmd_restart ;;
      5) cmd_status ;;
      6) cmd_logs ;;
      7) cmd_quickstart ;;
      8) cmd_enable_autostart ;;
      9) cmd_disable_autostart ;;
      p|P) provider_menu ;;
      0) echo "Exiting."; exit 0 ;;
      *) echo "Invalid option. Please try again." ;;
    esac
    echo ""
  done
}

main "$@"
