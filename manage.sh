#!/usr/bin/env bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.full.yml"
ENV_FILE="$PROJECT_DIR/.env"
ENV_EXAMPLE_FILE="$PROJECT_DIR/.env.example.full"
CONFIG_FILE="$PROJECT_DIR/litellm/config.yaml"
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SERVICE_NAME="litellm-ops-kit.service"
SERVICE_FILE="$SYSTEMD_USER_DIR/$SERVICE_NAME"

MAX_FALLBACK_LEVELS=3
ROUTES=(my-opus my-sonnet my-haiku)
ROUTE_KEYS=(OPUS SONNET HAIKU)

# shellcheck source=lib/ui.sh
source "$PROJECT_DIR/lib/ui.sh"
# shellcheck source=lib/common.sh
source "$PROJECT_DIR/lib/common.sh"
# shellcheck source=lib/provider.sh
source "$PROJECT_DIR/lib/provider.sh"
# shellcheck source=lib/service.sh
source "$PROJECT_DIR/lib/service.sh"

cmd_help() {
  ui_header "Usage: ./manage.sh <command>"
  echo ""
  ui_table_header "Command" 18 "Description" 34
  ui_table_divider 18 34
  ui_table_row "install" 18 "选择并安装 LiteLLM 版本 (轻量版/完整版)" 34
  ui_table_row "uninstall" 18 "卸载 LiteLLM (停止容器，删除镜像)" 34
  ui_table_row "switch" 18 "切换版本 (lite <-> full)" 34
  ui_table_row "init" 18 "从模板创建 .env 配置文件" 34
  ui_table_row "start" 18 "启动 LiteLLM 网关" 34
  ui_table_row "stop" 18 "停止 LiteLLM 网关" 34
  ui_table_row "restart" 18 "重启 LiteLLM 网关" 34
  ui_table_row "status" 18 "显示容器状态" 34
  ui_table_row "logs" 18 "查看服务日志" 34
  ui_table_row "provider" 18 "管理 provider tiers 和配置" 34
  ui_table_row "quickstart" 18 "查看快速接入指引" 34
  ui_table_row "enable-autostart" 18 "启用 systemd 用户服务" 34
  ui_table_row "disable-autostart" 18 "禁用 systemd 用户服务" 34
  ui_table_row "help" 18 "显示此帮助信息" 34
  echo ""
  ui_section "Provider 子命令"
  ui_code "./manage.sh provider list"
  ui_code "./manage.sh provider configure"
  ui_code "./manage.sh provider edit <main|fallback|fallback2|fallback3>"
  ui_code "./manage.sh provider disable <fallback|fallback2|fallback3>"
  ui_code "./manage.sh provider render"
  echo ""
}

show_menu() {
  local current_mode
  current_mode="$(get_mode)"
  local mode_display=""
  if [[ "$current_mode" != "none" ]]; then
    mode_display=" [${current_mode}]"
  fi

  echo ""
  ui_thick_divider 52
  printf "  ${C_BOLD}${C_BCYAN}🚀 LiteLLM Ops Kit${C_RESET}${C_BOLD}${C_WHITE}%s${C_RESET}\n" "$mode_display"
  ui_divider '-' 52

  ui_menu_item "1" "install"      "选择并安装版本 (轻量版/完整版)"
  ui_menu_item "2" "uninstall"    "卸载 (停止容器，删除镜像)"
  ui_menu_item "3" "switch"       "切换版本 (lite <-> full)"
  ui_menu_item "4" "start"        "启动 LiteLLM 网关"
  ui_menu_item "5" "stop"         "停止 LiteLLM 网关"
  ui_menu_item "6" "restart"      "重启 LiteLLM 网关"
  ui_menu_item "7" "status"       "显示容器状态"
  ui_menu_item "8" "logs"         "查看服务日志"
  ui_menu_item "9" "quickstart"   "查看快速接入指引"
  ui_menu_item "a" "autostart on" "启用 systemd 用户服务"
  ui_menu_item "b" "autostart off" "禁用 systemd 用户服务"
  ui_menu_item "p" "provider"     "管理 provider tiers"
  ui_menu_item "0" "exit"         "退出"
  ui_divider '-' 52
  echo ""
}

main() {
  if [[ $# -gt 0 ]]; then
    local cmd="$1"
    case "$cmd" in
      install) cmd_install ;;
      uninstall) cmd_uninstall ;;
      switch) cmd_switch ;;
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
        ui_error "Unknown command: $cmd"
        cmd_help
        exit 1
        ;;
    esac
    return
  fi

  while true; do
    show_menu
    read -rp "Select an option [0-9/a-p]: " choice
    case "$choice" in
      1) cmd_install ;;
      2) cmd_uninstall ;;
      3) cmd_switch ;;
      4) cmd_start ;;
      5) cmd_stop ;;
      6) cmd_restart ;;
      7) cmd_status ;;
      8) cmd_logs ;;
      9) cmd_quickstart ;;
      a|A) cmd_enable_autostart ;;
      b|B) cmd_disable_autostart ;;
      p|P) provider_menu ;;
      0) ui_info "Bye!"; exit 0 ;;
      *) ui_warning "无效选项，请重新选择" ;;
    esac
    echo ""
  done
}

main "$@"
