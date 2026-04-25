#!/usr/bin/env bash
# lib/proxy.sh — reverse proxy config and rendering

PROXY_DIR="$PROJECT_DIR/proxy"
NGINX_DIR="$PROXY_DIR/nginx"
NGINX_CONFIG_FILE="$NGINX_DIR/default.conf"
PROXY_CERTS_DIR="$PROXY_DIR/certs"

proxy_type_label() {
  case "${1:-none}" in
    none|"") echo "disabled" ;;
    external) echo "external-self-managed" ;;
    nginx) echo "nginx" ;;
    *) echo "$1" ;;
  esac
}

proxy_enabled() {
  [[ "${PROXY_TYPE:-none}" != "none" && -n "${PROXY_TYPE:-}" ]]
}

proxy_profile_name() {
  case "${PROXY_TYPE:-none}" in
    nginx) echo "proxy-nginx" ;;
    *) return 1 ;;
  esac
}

proxy_listen_port() {
  printf '%s' "${PROXY_LISTEN_PORT:-8080}"
}

proxy_forwarded_proto() {
  printf '%s' "${PROXY_FORWARD_PROTO:-https}"
}

proxy_forwarded_port() {
  printf '%s' "${PROXY_FORWARD_PORT:-}"
}

proxy_backend_port() {
  printf '%s' "${LITELLM_PORT:-4000}"
}

proxy_anthropic_host_port() {
  printf '%s' "${ANTHROPIC_ROUTER_PORT:-4001}"
}

proxy_timeout() {
  printf '%s' "${PROXY_TIMEOUT:-120}"
}

proxy_external_base_url() {
  printf '%s' "${PROXY_BASE_URL:-}"
}

proxy_resolve_export_target() {
  local target="${1:-}"
  local base_url host port

  if [[ -n "$target" ]]; then
    printf '%s' "$target"
    return 0
  fi

  base_url="$(proxy_external_base_url)"
  if [[ -z "$base_url" ]]; then
    return 1
  fi

  if [[ "$base_url" =~ ^https?://([^/:]+)(:([0-9]+))?(/.*)?$ ]]; then
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[3]}"
    if [[ -z "$port" ]]; then
      if [[ "$base_url" =~ ^https:// ]]; then
        port="443"
      else
        port="80"
      fi
    fi
    printf '%s:%s' "$host" "$port"
    return 0
  fi

  return 1
}

proxy_status() {
  case "${PROXY_TYPE:-none}" in
    none|"") echo "disabled" ;;
    external)
      if [[ "$(proxy_listen_port)" =~ ^[0-9]+$ ]]; then
        echo "external"
      else
        echo "invalid"
      fi
      ;;
    nginx)
      if [[ "$(proxy_listen_port)" =~ ^[0-9]+$ ]]; then
        echo "enabled"
      else
        echo "invalid"
      fi
      ;;
    *)
      echo "invalid"
      ;;
  esac
}

disable_proxy() {
  env_batch_set "PROXY_TYPE" "none"
  env_batch_set "PROXY_LISTEN_PORT" "${PROXY_LISTEN_PORT:-8080}"
  env_batch_set "PROXY_FORWARD_PROTO" "${PROXY_FORWARD_PROTO:-https}"
  env_batch_set "PROXY_FORWARD_PORT" ""
}

validate_proxy_config() {
  load_env

  case "${PROXY_TYPE:-none}" in
    none|"")
      return 0
      ;;
    external|nginx)
      if [[ ! "$(proxy_backend_port)" =~ ^[0-9]+$ ]]; then
        ui_error "LITELLM_PORT must be numeric in $ENV_FILE"
        exit 1
      fi
      if [[ ! "$(proxy_listen_port)" =~ ^[0-9]+$ ]]; then
        ui_error "PROXY_LISTEN_PORT must be numeric in $ENV_FILE"
        exit 1
      fi
      if [[ "$(proxy_forwarded_proto)" != "http" && "$(proxy_forwarded_proto)" != "https" ]]; then
        ui_error "PROXY_FORWARD_PROTO must be http or https in $ENV_FILE"
        exit 1
      fi
      if [[ -n "$(proxy_forwarded_port)" && ! "$(proxy_forwarded_port)" =~ ^[0-9]+$ ]]; then
        ui_error "PROXY_FORWARD_PORT must be empty or numeric in $ENV_FILE"
        exit 1
      fi
      ;;
    *)
      ui_error "Unsupported PROXY_TYPE=${PROXY_TYPE} in $ENV_FILE"
      exit 1
      ;;
  esac
}

render_nginx_proxy_config() {
  local listen_port forward_proto forward_port backend_port timeout
  listen_port="$(proxy_listen_port)"
  forward_proto="$(proxy_forwarded_proto)"
  forward_port="$(proxy_forwarded_port)"
  backend_port="$(proxy_backend_port)"
  timeout="$(proxy_timeout)"

  mkdir -p "$NGINX_DIR"

  cat >"$NGINX_CONFIG_FILE" <<EOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    '' close;
}

map \$http_x_forwarded_proto \$litellm_forwarded_proto {
    default \$http_x_forwarded_proto;
    '' ${forward_proto};
}

map \$http_x_forwarded_port \$litellm_forwarded_port {
    default \$http_x_forwarded_port;
    '' ${forward_port:-$listen_port};
}

server {
    listen 8080;
    server_name _;

    location = /v1/messages {
        proxy_pass http://anthropic-router:4001;
        proxy_http_version 1.1;

        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-Proto \$litellm_forwarded_proto;
        proxy_set_header X-Forwarded-Port \$litellm_forwarded_port;
        proxy_redirect http://\$http_host/ \$litellm_forwarded_proto://\$http_host/;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        proxy_read_timeout ${timeout}s;
        proxy_send_timeout ${timeout}s;
    }

    location / {
        proxy_pass http://litellm:${backend_port};
        proxy_http_version 1.1;

        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-Proto \$litellm_forwarded_proto;
        proxy_set_header X-Forwarded-Port \$litellm_forwarded_port;
        proxy_redirect http://\$http_host/ \$litellm_forwarded_proto://\$http_host/;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        proxy_read_timeout ${timeout}s;
        proxy_send_timeout ${timeout}s;
    }
}
EOF
}

render_proxy_config() {
  validate_proxy_config

  case "${PROXY_TYPE:-none}" in
    none|"")
      return 0
      ;;
    external)
      return 0
      ;;
    nginx)
      render_nginx_proxy_config
      ;;
  esac
}

detect_existing_proxy_services() {
  local -a hits=()
  local proc

  for proc in nginx caddy traefik haproxy apache2 httpd; do
    if pgrep -x "$proc" >/dev/null 2>&1; then
      hits+=("process:${proc}")
    fi
  done

  if command -v docker >/dev/null 2>&1; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      hits+=("docker:${line}")
    done < <(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null | awk '
      BEGIN { IGNORECASE=1 }
      /nginx|caddy|traefik|haproxy|apache|httpd/ { print $0 }
    ')
  fi

  if ((${#hits[@]} > 0)); then
    printf '%s\n' "${hits[@]}" | awk '!seen[$0]++'
  fi
}

print_proxy_summary() {
  load_env

  ui_section "Reverse Proxy"
  ui_kv "Type"   "$(proxy_type_label "${PROXY_TYPE:-none}")"
  ui_kv "Status" "$(ui_status_badge "$(proxy_status)")"
  if proxy_enabled; then
    ui_kv "nginx监听端口"  "$(proxy_listen_port)"
    if [[ "${PROXY_TYPE:-none}" == "external" ]]; then
      ui_kv "Owner"   "user-managed"
      ui_kv "litellm监听端口" "$(proxy_backend_port)"
      ui_kv "anthropic-router监听端口" "$(proxy_anthropic_host_port)"
      ui_kv "Anthropic" "/v1/messages -> 127.0.0.1:$(proxy_anthropic_host_port)"
      ui_kv "Other" "all other paths -> 127.0.0.1:$(proxy_backend_port)"
    else
      ui_kv "Owner"   "script-managed"
      ui_kv "litellm监听端口" "$(proxy_backend_port)"
      ui_kv "anthropic-router监听端口" "$(proxy_anthropic_host_port)"
      ui_kv "Anthropic" "/v1/messages -> anthropic-router:4001"
      ui_kv "Other" "all other paths -> litellm:$(proxy_backend_port)"
    fi
    ui_kv "Proto"   "$(proxy_forwarded_proto)"
    if [[ -n "${PROXY_BASE_URL:-}" ]]; then
      ui_kv "External" "${PROXY_BASE_URL}"
    fi
  fi
}

cmd_proxy_list() {
  print_proxy_summary
}

prompt_proxy_type() {
  local current="${PROXY_TYPE:-none}"
  local input
  read -rp "Proxy type [none/external/nginx] [${current}]: " input
  printf '%s' "${input:-$current}"
}

cmd_proxy_configure() {
  ensure_env_file
  load_env

  local detected
  detected="$(detect_existing_proxy_services || true)"
  if [[ -n "$detected" ]]; then
    ui_warning "Detected existing reverse proxy services:"
    while IFS= read -r line; do
      [[ -n "$line" ]] && ui_code "$line"
    done <<<"$detected"
    echo ""
    ui_info "If you already run a reverse proxy yourself, choose 'external'."
  fi

  echo ""
  ui_info "推荐模式:"
  ui_code "none     -> 不使用项目内代理"
  ui_code "external -> 你已经自己运行了 nginx/caddy/traefik"
  ui_code "nginx    -> 由脚本托管一个 nginx 代理"

  local selected
  selected="$(prompt_proxy_type)"

  case "$selected" in
    none)
      env_batch_begin
      disable_proxy
      env_batch_apply
      ui_success "Reverse proxy disabled."
      ;;
    external)
      ui_header "External Proxy Guide"
      ui_code "当前模式不会启动任何代理容器。"
      ui_code "你需要自己维护反代，并显式拆分 Anthropic 与 LiteLLM 两条上游。"
      ui_code "/v1/messages -> 127.0.0.1:$(proxy_anthropic_host_port)"
      ui_code "其他路径 -> 127.0.0.1:$(proxy_backend_port)"
      ui_code "主流程需要配置 nginx监听端口 和 litellm监听端口。"
      local listen_port backend_port anthropic_port confirm
      while true; do
        listen_port="$(prompt_port_value "nginx监听端口" "$(env_get "PROXY_LISTEN_PORT")" "8080")"
        backend_port="$(prompt_port_value "litellm监听端口" "$(env_get "LITELLM_PORT")" "4000")"
        anthropic_port="$(prompt_port_value "anthropic-router监听端口" "$(env_get "ANTHROPIC_ROUTER_PORT")" "4001")"
        if [[ "$listen_port" != "$backend_port" ]]; then
          break
        fi
        ui_warning "nginx监听端口 不能和 litellm监听端口 ${backend_port} 相同。"
      done
      echo ""
      ui_section "Pending Proxy Config"
      ui_kv "Type"   "external"
      ui_kv "nginx监听端口" "${listen_port}"
      ui_kv "litellm监听端口" "${backend_port}"
      ui_kv "anthropic-router监听端口" "${anthropic_port}"
      ui_kv "Proto"  "$(env_get "PROXY_FORWARD_PROTO" | sed 's/^$/https/')"
      ui_kv "Anthropic" "/v1/messages -> 127.0.0.1:${anthropic_port}"
      ui_kv "Other" "all other paths -> 127.0.0.1:${backend_port}"
      read -rp "Apply proxy changes? [Y/n]: " confirm
      confirm="${confirm:-Y}"
      if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        ui_warning "已取消，未写入 .env。"
        return 0
      fi
      env_batch_begin
      env_batch_set "PROXY_TYPE" "external"
      env_batch_set "PROXY_LISTEN_PORT" "$listen_port"
      env_batch_set "LITELLM_PORT" "$backend_port"
      env_batch_set "ANTHROPIC_ROUTER_PORT" "$anthropic_port"
      env_batch_set "PROXY_FORWARD_PROTO" "${PROXY_FORWARD_PROTO:-https}"
      env_batch_set "PROXY_FORWARD_PORT" ""
      env_batch_apply
      ui_info "Proxy service remains user-managed. Route /v1/messages to ${anthropic_port}, and everything else to ${backend_port}."
      ui_success "External reverse proxy metadata updated."
      ;;
    nginx)
      ui_header "Managed Nginx Guide"
      ui_code "推荐链路: 浏览器 -> SakuraFRP -> nginx:8080 -> (/v1/messages -> anthropic-router:4001, other -> litellm:$(proxy_backend_port))"
      ui_code "主流程需要配置 nginx监听端口 和 litellm监听端口。"
      local listen_port backend_port anthropic_port confirm
      while true; do
        listen_port="$(prompt_port_value "nginx监听端口" "$(env_get "PROXY_LISTEN_PORT")" "8080")"
        backend_port="$(prompt_port_value "litellm监听端口" "$(env_get "LITELLM_PORT")" "4000")"
        anthropic_port="$(prompt_port_value "anthropic-router监听端口" "$(env_get "ANTHROPIC_ROUTER_PORT")" "4001")"
        if [[ "$listen_port" != "$backend_port" ]]; then
          break
        fi
        ui_warning "nginx监听端口 不能和 litellm监听端口 ${backend_port} 相同。"
      done
      echo ""
      ui_section "Pending Proxy Config"
      ui_kv "Type"    "nginx"
      ui_kv "nginx监听端口"  "${listen_port}"
      ui_kv "litellm监听端口" "${backend_port}"
      ui_kv "anthropic-router监听端口" "${anthropic_port}"
      ui_kv "Anthropic" "/v1/messages -> anthropic-router:4001"
      ui_kv "Other" "all other paths -> litellm:${backend_port}"
      ui_kv "Proto"   "${PROXY_FORWARD_PROTO:-https}"
      ui_kv "FRP"     "把 SakuraFRP 本地目标端口改成 ${listen_port}"
      read -rp "Apply proxy changes? [Y/n]: " confirm
      confirm="${confirm:-Y}"
      if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        ui_warning "已取消，未写入 .env。"
        return 0
      fi
      env_batch_begin
      env_batch_set "PROXY_TYPE" "nginx"
      env_batch_set "PROXY_LISTEN_PORT" "$listen_port"
      env_batch_set "LITELLM_PORT" "$backend_port"
      env_batch_set "ANTHROPIC_ROUTER_PORT" "$anthropic_port"
      env_batch_set "PROXY_FORWARD_PROTO" "${PROXY_FORWARD_PROTO:-https}"
      env_batch_set "PROXY_FORWARD_PORT" ""
      env_batch_apply
      load_env
      render_proxy_config
      ui_success "Reverse proxy configuration updated."
      ;;
    *)
      ui_error "Unknown proxy type: $selected"
      return 1
      ;;
  esac
}

cmd_proxy_disable() {
  ensure_env_file
  load_env
  env_batch_begin
  disable_proxy
  env_batch_apply
  ui_success "Reverse proxy disabled."
}

cmd_proxy_render() {
  ensure_env_file
  load_env
  if [[ "${PROXY_TYPE:-none}" == "external" ]]; then
    ui_info "External reverse proxy is user-managed. Nothing to render."
    return 0
  fi
  render_proxy_config
  ui_success "Rendered reverse proxy config."
}

cmd_proxy_export_cert() {
  ensure_env_file
  load_env

  local target="${1:-}"
  local output_path="${2:-}"
  local resolved_target host port default_output tmp_file

  if ! resolved_target="$(proxy_resolve_export_target "$target")"; then
    ui_error "Missing target. Use: ./manage.sh proxy export-cert <host:port> [output.crt]"
    ui_info "Or set PROXY_BASE_URL in .env so the script can infer the external host and port."
    return 1
  fi

  if [[ ! "$resolved_target" =~ ^([^:]+):([0-9]+)$ ]]; then
    ui_error "Invalid target: $resolved_target"
    ui_info "Expected format: host:port"
    return 1
  fi

  host="${BASH_REMATCH[1]}"
  port="${BASH_REMATCH[2]}"

  mkdir -p "$PROXY_CERTS_DIR"
  default_output="$PROXY_CERTS_DIR/${host}-${port}.crt"
  output_path="${output_path:-$default_output}"
  tmp_file="$(mktemp)"

  if ! echo | openssl s_client -connect "${host}:${port}" -servername "$host" 2>/dev/null \
    | sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' >"$tmp_file"; then
    rm -f "$tmp_file"
    ui_error "Failed to connect to ${host}:${port}"
    return 1
  fi

  if [[ ! -s "$tmp_file" ]]; then
    rm -f "$tmp_file"
    ui_error "No certificate was returned by ${host}:${port}"
    return 1
  fi

  mv "$tmp_file" "$output_path"

  ui_success "Certificate exported."
  ui_kv "Target" "${host}:${port}"
  ui_kv "Output" "$output_path"
  ui_info "Install it on Debian/Ubuntu with:"
  ui_code "sudo cp '$output_path' /usr/local/share/ca-certificates/$(basename "$output_path")"
  ui_code "sudo update-ca-certificates"
}

cmd_proxy_help() {
  ui_header "Usage: ./manage.sh proxy <command>"
  echo ""
  ui_table_header "Command" 14 "Description" 40
  ui_table_divider 14 40
  ui_table_row "list" 14 "显示当前反向代理配置" 40
  ui_table_row "configure" 14 "先探测再配置 external/nginx" 40
  ui_table_row "disable" 14 "禁用反向代理" 40
  ui_table_row "render" 14 "重新渲染代理配置文件" 40
  ui_table_row "export-cert" 14 "导出外部 HTTPS 入口证书" 40
  echo ""
  ui_code "./manage.sh proxy export-cert frp-put.com:33745"
  ui_code "./manage.sh proxy export-cert frp-put.com:33745 /tmp/sakurafrp.crt"
  ui_code "./manage.sh proxy export-cert   # 从 PROXY_BASE_URL 自动推断"
}

show_proxy_menu() {
  echo ""
  ui_thick_divider 52
  printf "  ${C_BOLD}${C_BMAGENTA}# Reverse Proxy${C_RESET}\n"
  ui_divider '-' 52
  ui_menu_item "1" "list"      "查看当前代理状态"
  ui_menu_item "2" "configure" "选择并配置代理"
  ui_menu_item "3" "disable"   "禁用代理"
  ui_menu_item "4" "render"    "重新生成代理配置"
  ui_menu_item "5" "export-cert" "导出外部 HTTPS 证书"
  ui_menu_item "0" "back"      "返回主菜单"
  ui_divider '-' 52
  echo ""
}

proxy_menu() {
  while true; do
    load_env
    show_proxy_menu
    print_proxy_summary
    echo ""
    local choice
    choice="$(prompt_choice "Select an option [0-5]: " '^[0-5]$')"
    case "$choice" in
      1) cmd_proxy_list ;;
      2) cmd_proxy_configure ;;
      3) cmd_proxy_disable ;;
      4) cmd_proxy_render ;;
      5) cmd_proxy_export_cert ;;
      0) return 0 ;;
    esac
    echo ""
  done
}

cmd_proxy() {
  local action="${1:-list}"
  case "$action" in
    list) cmd_proxy_list ;;
    configure) cmd_proxy_configure ;;
    disable) cmd_proxy_disable ;;
    render) cmd_proxy_render ;;
    export-cert) shift; cmd_proxy_export_cert "$@" ;;
    help|-h|--help) cmd_proxy_help ;;
    *)
      ui_error "Unknown proxy command: $action"
      cmd_proxy_help
      return 1
      ;;
  esac
}
