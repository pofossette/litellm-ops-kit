#!/usr/bin/env bash
# lib/service.sh — Docker lifecycle, systemd autostart, startup info, install/uninstall

# Print the raw command that was just executed, for transparency
show_raw_cmd() {
  local msg="$1"
  echo ""
  ui_section "原始命令"
  ui_code "$msg"
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

  local mode
  mode="$(get_mode)"

  ui_header "Service Started  (mode: ${mode})"

  ui_section "Gateway"
  ui_kv "Local"    "http://127.0.0.1:${port}"
  ui_kv "LAN"      "http://${host_ip}:${port}"
  ui_kv "Admin UI" "http://${host_ip}:${port}/ui"
  ui_kv "Master Key" "${LITELLM_MASTER_KEY}"

  ui_section "Routing"
  for level in "${!ROUTES[@]}"; do route_chain_summary "$level"; done

  ui_section "Claude Code env"
  ui_code "export ANTHROPIC_BASE_URL=http://${host_ip}:${port}"
  ui_code "export ANTHROPIC_AUTH_TOKEN=${LITELLM_MASTER_KEY}"
  ui_code "export ANTHROPIC_DEFAULT_OPUS_MODEL=my-opus"
  ui_code "export ANTHROPIC_DEFAULT_SONNET_MODEL=my-sonnet"
  ui_code "export ANTHROPIC_DEFAULT_HAIKU_MODEL=my-haiku"

  echo ""
  ui_kv "Autostart" "$(ui_status_badge "$autostart_state")"
  echo ""
}

write_systemd_service() {
  mkdir -p "$SYSTEMD_USER_DIR"
  resolve_compose_file

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
  ui_success "Environment template is ready at $ENV_FILE"
}

cmd_start() {
  require_configured_env
  render_litellm_config
  compose up -d
  show_raw_cmd "$COMPOSE_FILE up -d"
  print_startup_info
}

cmd_stop() {
  ensure_env_file
  compose down
  show_raw_cmd "$COMPOSE_FILE down"
  ui_success "Service stopped."
}

cmd_restart() {
  require_configured_env
  render_litellm_config
  compose down
  compose up -d
  show_raw_cmd "$COMPOSE_FILE down && $COMPOSE_FILE up -d"
  print_startup_info
}

cmd_status() {
  ensure_env_file
  local current_mode
  current_mode="$(get_mode)"

  ui_header "Service Status  (mode: ${current_mode})"

  # Container status
  ui_section "Container Status"
  compose ps
  echo ""

  # Image name, uptime, memory
  local container_name="litellm-ops-kit"
  if docker inspect "$container_name" >/dev/null 2>&1; then
    local image uptime mem_usage mem_limit
    image="$(docker inspect --format '{{.Config.Image}}' "$container_name" 2>/dev/null)"
    uptime="$(docker inspect --format '{{.State.StartedAt}}' "$container_name" 2>/dev/null)"
    mem_usage="$(docker stats --no-stream --format '{{.MemUsage}}' "$container_name" 2>/dev/null)"
    mem_limit="$(docker stats --no-stream --format '{{.MemPerc}}' "$container_name" 2>/dev/null)"

    ui_section "Container Details"
    ui_kv "Image" "$image"
    if [[ -n "$uptime" ]]; then
      local uptime_human
      uptime_human="$(docker inspect --format '{{.State.StartedAt}}' "$container_name" 2>/dev/null | xargs -I{} date -d "{}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$uptime")"
      ui_kv "Started at" "$uptime_human"
    fi
    if [[ -n "$mem_usage" ]]; then
      ui_kv "Memory" "${mem_usage} (${mem_limit})"
    fi

    local container_size image_size
    container_size="$(docker ps -s --no-trunc --filter "name=$container_name" --format '{{.Size}}' 2>/dev/null)"
    image_size="$(docker image inspect "$image" --format '{{.Size}}' 2>/dev/null)"
    if [[ -n "$image_size" ]]; then
      local image_size_mb
      image_size_mb=$((image_size / 1024 / 1024))
      ui_kv "Image disk" "${image_size_mb} MB"
    fi
    if [[ -n "$container_size" ]]; then
      ui_kv "Container" "$container_size"
    fi

    echo ""
    ui_section "原始命令"
    ui_code "docker compose --env-file $ENV_FILE -f $COMPOSE_FILE ps"
    ui_code "docker stats --no-stream $container_name"
    ui_code "docker system df"
  fi

  # For full mode, also show postgres
  if [[ "$current_mode" == "full" ]]; then
    local pg_container="litellm-ops-kit-postgres"
    if docker inspect "$pg_container" >/dev/null 2>&1; then
      local pg_image pg_mem
      pg_image="$(docker inspect --format '{{.Config.Image}}' "$pg_container" 2>/dev/null)"
      pg_mem="$(docker stats --no-stream --format '{{.MemUsage}} ({{.MemPerc}})' "$pg_container" 2>/dev/null)"
      echo ""
      ui_section "PostgreSQL"
      ui_kv "Image" "$pg_image"
      if [[ -n "$pg_mem" ]]; then
        ui_kv "Memory" "$pg_mem"
      fi
    fi
  fi
}

cmd_logs() {
  ensure_env_file
  ui_info "按 Ctrl+C 退出日志查看"
  ui_code "docker compose --env-file $ENV_FILE -f $COMPOSE_FILE logs --tail=200 -f"
  echo ""
  compose logs --tail=200 -f
}

cmd_quickstart() {
  load_env
  local port="${LITELLM_PORT:-4000}"
  local host_ip
  host_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  local api_url="http://${host_ip}:${port}"
  local current_mode
  current_mode="$(get_mode)"

  echo ""
  ui_thick_divider 52
  printf "  ${C_BOLD}${C_BCYAN}🚀 Quick Start${C_RESET}\n"
  ui_divider '-' 52

  ui_section "Endpoints"
  ui_kv "Web Panel"    "${api_url}/ui"
  ui_kv "API Endpoint" "${api_url}"
  ui_kv "API Key"      "${LITELLM_MASTER_KEY}"

  ui_section "Web Panel 登录"
  ui_kv "地址"   "${api_url}/ui"
  ui_kv "用户名" "(留空)"
  ui_kv "密码"   "${LITELLM_MASTER_KEY}"

  ui_section "Available Models"
  ui_kv "my-opus"   "Opus"
  ui_kv "my-sonnet" "Sonnet"
  ui_kv "my-haiku"  "Haiku"

  ui_kv "Mode" "${current_mode}"

  ui_section "Claude Code 配置"
  ui_dotted_divider 46
  ui_code "export ANTHROPIC_BASE_URL=${api_url}"
  ui_code "export ANTHROPIC_AUTH_TOKEN=${LITELLM_MASTER_KEY}"
  ui_code "export ANTHROPIC_DEFAULT_OPUS_MODEL=my-opus"
  ui_code "export ANTHROPIC_DEFAULT_SONNET_MODEL=my-sonnet"
  ui_code "export ANTHROPIC_DEFAULT_HAIKU_MODEL=my-haiku"
  ui_dotted_divider 46

  ui_thick_divider 52
  echo ""
}

cmd_enable_autostart() {
  require_configured_env
  render_litellm_config
  write_systemd_service
  systemctl --user daemon-reload
  systemctl --user enable "$SERVICE_NAME"
  systemctl --user start "$SERVICE_NAME"
  ui_success "Autostart enabled."
  ui_info "Systemd user service: $SERVICE_FILE"
  print_startup_info
}

cmd_disable_autostart() {
  if systemctl --user is-enabled "$SERVICE_NAME" >/dev/null 2>&1; then
    systemctl --user disable --now "$SERVICE_NAME"
  fi
  rm -f "$SERVICE_FILE"
  systemctl --user daemon-reload
  ui_success "Autostart disabled."
}

# ── Install / Uninstall / Switch ──

cmd_install() {
  local current_mode
  current_mode="$(get_mode)"

  if [[ "$current_mode" != "none" ]]; then
    ui_info "Current mode: ${current_mode}"
    echo ""
  fi

  echo ""
  ui_thick_divider 52
  printf "  ${C_BOLD}${C_BCYAN}📦 选择安装版本${C_RESET}\n"
  ui_divider '-' 52
  ui_menu_item "1" "lite" "轻量版 — 不带数据库，镜像更小"
  ui_menu_item "2" "full" "完整版 — 带 PostgreSQL，支持持久化和 UI"
  ui_divider '-' 52
  echo ""
  local choice
  choice="$(prompt_choice "请选择 [1/2]: " '^[12]$')"

  local mode
  case "$choice" in
    1) mode="lite" ;;
    2) mode="full" ;;
  esac

  echo ""
  set_mode "$mode"
  ui_success "已选择: ${mode} 版本"

  # Create .env from the correct template if it doesn't exist yet
  if [[ ! -f "$ENV_FILE" ]]; then
    local template
    case "$mode" in
      lite) template="$PROJECT_DIR/.env.example.lite" ;;
      full) template="$PROJECT_DIR/.env.example.full" ;;
    esac
    cp "$template" "$ENV_FILE"
    local generated_key
    generated_key="$(generate_master_key)"
    env_write "LITELLM_MASTER_KEY" "$generated_key"
    ui_info "Created $ENV_FILE with auto-generated master key."
  fi

  echo ""
  ui_section "下一步"
  ui_code "1) ./manage.sh provider configure   # 配置 API provider"
  ui_code "2) ./manage.sh start                # 启动服务"
  echo ""
}

cmd_uninstall() {
  local current_mode
  current_mode="$(get_mode)"
  if [[ "$current_mode" == "none" ]]; then
    ui_warning "未检测到已安装的版本，无需卸载。"
    return 0
  fi

  ui_header "卸载 LiteLLM  (当前: ${current_mode})"
  echo ""
  ui_warning "卸载将执行以下操作:"
  printf "  ${S_FAIL} 停止正在运行的服务\n"
  printf "  ${S_FAIL} 删除 Docker 容器\n"
  printf "  ${S_FAIL} 删除 Docker 镜像\n"
  if [[ "$current_mode" == "full" ]]; then
    printf "  ${S_FAIL} 删除 PostgreSQL 数据卷\n"
  fi
  printf "  ${C_DIM}  .env 配置文件将被保留${C_RESET}\n"
  echo ""

  local confirm
  read -rp "确认卸载? [y/N]: " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    ui_info "已取消。"
    return 0
  fi

  # Stop and remove containers
  compose down --rmi all --volumes 2>/dev/null || compose down --volumes 2>/dev/null || compose down 2>/dev/null || true

  # Remove images explicitly (for --rmi all fallback)
  echo ""
  ui_section "清理镜像"
  if [[ "$current_mode" == "lite" ]]; then
    docker rmi ghcr.io/berriai/litellm:main-stable 2>/dev/null && ui_info "已删除 litellm:main-stable 镜像" || ui_info "litellm:main-stable 镜像不存在或已删除"
  else
    docker rmi ghcr.io/berriai/litellm-database:main-stable 2>/dev/null && ui_info "已删除 litellm-database:main-stable 镜像" || ui_info "litellm-database:main-stable 镜像不存在或已删除"
    docker rmi postgres:16-alpine 2>/dev/null && ui_info "已删除 postgres:16-alpine 镜像" || ui_info "postgres:16-alpine 镜像不存在或已删除"
  fi

  # Remove mode file
  rm -f "$MODE_FILE"

  # Disable autostart if enabled
  cmd_disable_autostart 2>/dev/null || true

  echo ""
  ui_success "卸载完成。"
  ui_info ".env 配置文件已保留在 $ENV_FILE"
}

cmd_switch() {
  local current_mode
  current_mode="$(get_mode)"
  if [[ "$current_mode" == "none" ]]; then
    ui_warning "尚未安装，请先运行 ./manage.sh install"
    return 1
  fi

  local target_mode
  if [[ "$current_mode" == "lite" ]]; then
    target_mode="full"
  else
    target_mode="lite"
  fi

  ui_header "版本切换"
  ui_kv "当前" "${current_mode}"
  ui_kv "目标" "${target_mode}"
  echo ""
  ui_warning "切换版本将:"
  printf "  ${S_WARN} 停止当前运行的服务\n"
  if [[ "$current_mode" == "full" && "$target_mode" == "lite" ]]; then
    printf "  ${S_WARN} 从带数据库版本切换到轻量版本\n"
    printf "  ${C_DIM}  PostgreSQL 数据将被保留在 Docker 卷中${C_RESET}\n"
  else
    printf "  ${S_WARN} 从轻量版本切换到带数据库版本\n"
  fi
  printf "  ${C_DIM}  .env 配置文件将被保留${C_RESET}\n"
  echo ""

  local confirm
  read -rp "确认切换? [y/N]: " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    ui_info "已取消。"
    return 0
  fi

  # Stop current services
  compose down 2>/dev/null || true

  # Remove old images
  echo ""
  ui_section "清理旧镜像"
  if [[ "$current_mode" == "lite" ]]; then
    docker rmi ghcr.io/berriai/litellm:main-stable 2>/dev/null || true
  else
    docker rmi ghcr.io/berriai/litellm-database:main-stable 2>/dev/null || true
    docker rmi postgres:16-alpine 2>/dev/null || true
  fi

  # Switch mode
  set_mode "$target_mode"
  echo ""
  ui_success "已切换到 ${target_mode} 版本。"
  ui_info "运行 ./manage.sh start 启动新版本。"
}
