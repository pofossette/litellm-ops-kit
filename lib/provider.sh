#!/usr/bin/env bash
# lib/provider.sh — provider tier logic + LiteLLM config rendering

provider_prefix_for_level() {
  case "$1" in
    0) echo "MAIN" ;;
    1) echo "FALLBACK" ;;
    2) echo "FALLBACK2" ;;
    3) echo "FALLBACK3" ;;
    *) return 1 ;;
  esac
}

provider_label_for_level() {
  case "$1" in
    0) echo "main" ;;
    1) echo "fallback" ;;
    2) echo "fallback-2" ;;
    3) echo "fallback-3" ;;
    *) return 1 ;;
  esac
}

provider_route_suffix() {
  case "$1" in
    0) echo "" ;;
    1) echo "-fallback" ;;
    2) echo "-fallback-2" ;;
    3) echo "-fallback-3" ;;
    *) return 1 ;;
  esac
}

route_model_name() {
  local route="$1"
  local level="$2"
  printf '%s%s' "$route" "$(provider_route_suffix "$level")"
}

provider_var_names() {
  local prefix="$1"
  cat <<EOF
${prefix}_ANTHROPIC_API_BASE
${prefix}_ANTHROPIC_API_KEY
${prefix}_OPENAI_API_BASE
${prefix}_OPENAI_API_KEY
${prefix}_OPUS_MODEL
${prefix}_SONNET_MODEL
${prefix}_HAIKU_MODEL
EOF
}

provider_tier_status() {
  local prefix="$1"
  local any_set=0
  local all_set=1
  local invalid=0
  local var_name

  while IFS= read -r var_name; do
    local value="${!var_name:-}"
    if [[ -n "$value" ]]; then
      any_set=1
      if is_placeholder_value "$value"; then
        invalid=1
      fi
    else
      all_set=0
    fi
  done < <(provider_var_names "$prefix")

  if [[ "$prefix" == "MAIN" ]]; then
    if [[ "$any_set" -eq 0 ]]; then
      echo "empty"
    elif [[ "$all_set" -eq 1 && "$invalid" -eq 0 ]]; then
      echo "ready"
    else
      echo "invalid"
    fi
    return
  fi

  if [[ "$any_set" -eq 0 ]]; then
    echo "empty"
  elif [[ "$all_set" -eq 1 && "$invalid" -eq 0 ]]; then
    echo "ready"
  else
    echo "invalid"
  fi
}

provider_tier_ready() {
  [[ "$(provider_tier_status "$1")" == "ready" ]]
}

provider_index_from_name() {
  case "${1:-}" in
    main|0) echo 0 ;;
    fallback|fallback1|fallback-1|1) echo 1 ;;
    fallback2|fallback-2|2) echo 2 ;;
    fallback3|fallback-3|3) echo 3 ;;
    *) return 1 ;;
  esac
}

disable_provider_tier_from_level() {
  local start_level="$1"
  local level
  for ((level=start_level; level<=MAX_FALLBACK_LEVELS; level++)); do
    local prefix
    prefix="$(provider_prefix_for_level "$level")"
    while IFS= read -r var_name; do
      env_unset "$var_name"
    done < <(provider_var_names "$prefix")
  done
}

prompt_provider_tier() {
  local level="$1"
  local prefix
  prefix="$(provider_prefix_for_level "$level")"

  ui_header "Configuring $(provider_label_for_level "$level") provider (${prefix})"
  env_write "${prefix}_ANTHROPIC_API_BASE" "$(prompt_value "Anthropic API base" "$(env_get "${prefix}_ANTHROPIC_API_BASE")")"
  env_write "${prefix}_ANTHROPIC_API_KEY" "$(prompt_value "Anthropic API key" "$(env_get "${prefix}_ANTHROPIC_API_KEY")" 1)"
  env_write "${prefix}_OPENAI_API_BASE" "$(prompt_value "OpenAI API base" "$(env_get "${prefix}_OPENAI_API_BASE")")"
  env_write "${prefix}_OPENAI_API_KEY" "$(prompt_value "OpenAI API key" "$(env_get "${prefix}_OPENAI_API_KEY")" 1)"
  env_write "${prefix}_OPUS_MODEL" "$(prompt_value "Opus model" "$(env_get "${prefix}_OPUS_MODEL")")"
  env_write "${prefix}_SONNET_MODEL" "$(prompt_value "Sonnet model" "$(env_get "${prefix}_SONNET_MODEL")")"
  env_write "${prefix}_HAIKU_MODEL" "$(prompt_value "Haiku model" "$(env_get "${prefix}_HAIKU_MODEL")")"
}

validate_provider_chain() {
  load_env

  local gap_seen=0
  local level prefix status

  for level in 0 1 2 3; do
    prefix="$(provider_prefix_for_level "$level")"
    status="$(provider_tier_status "$prefix")"

    if [[ "$level" -eq 0 ]]; then
      if [[ "$status" != "ready" ]]; then
        ui_error "main provider (${prefix}) must be fully configured in $ENV_FILE"
        exit 1
      fi
      continue
    fi

    case "$status" in
      ready)
        if [[ "$gap_seen" -eq 1 ]]; then
          ui_error "${prefix} is configured after a missing fallback tier. Configure fallback tiers contiguously."
          exit 1
        fi
        ;;
      empty)
        gap_seen=1
        ;;
      invalid)
        ui_error "${prefix} is partially configured or contains placeholder values in $ENV_FILE"
        exit 1
        ;;
    esac
  done
}

render_fallback_entry() {
  local route="$1"
  shift
  local models=("$@")
  local i

  printf '    - {"%s": [' "$route"
  for i in "${!models[@]}"; do
    if [[ "$i" -gt 0 ]]; then
      printf ', '
    fi
    printf '"%s"' "${models[$i]}"
  done
  printf ']}\n'
}

render_litellm_config() {
  validate_provider_chain

  local tmp_file
  tmp_file="$(mktemp)"
  local route_index level prefix route route_key model_name has_any_fallback=0

  {
    echo "model_list:"
    for route_index in "${!ROUTES[@]}"; do
      route="${ROUTES[$route_index]}"
      route_key="${ROUTE_KEYS[$route_index]}"

      for level in 0 1 2 3; do
        prefix="$(provider_prefix_for_level "$level")"
        if [[ "$(provider_tier_status "$prefix")" == "ready" ]]; then
          model_name="$(route_model_name "$route" "$level")"
          cat <<EOF
  - model_name: ${model_name}
    litellm_params:
      model: anthropic/os.environ/${prefix}_${route_key}_MODEL
      api_base: os.environ/${prefix}_ANTHROPIC_API_BASE
      api_key: os.environ/${prefix}_ANTHROPIC_API_KEY
  - model_name: ${model_name}
    litellm_params:
      model: openai/os.environ/${prefix}_${route_key}_MODEL
      api_base: os.environ/${prefix}_OPENAI_API_BASE
      api_key: os.environ/${prefix}_OPENAI_API_KEY

EOF
        fi
      done
    done

    cat <<EOF
litellm_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  drop_params: false
  set_verbose: true

router_settings:
  num_retries: ${LITELLM_NUM_RETRIES:-2}
  timeout: ${LITELLM_TIMEOUT:-120}
EOF

    for route_index in "${!ROUTES[@]}"; do
      route="${ROUTES[$route_index]}"
      local fallback_models=()
      for level in 1 2 3; do
        prefix="$(provider_prefix_for_level "$level")"
        if [[ "$(provider_tier_status "$prefix")" == "ready" ]]; then
          fallback_models+=( "$(route_model_name "$route" "$level")" )
        fi
      done
      if [[ "${#fallback_models[@]}" -gt 0 ]]; then
        has_any_fallback=1
        break
      fi
    done

    if [[ "$has_any_fallback" -eq 0 ]]; then
      echo "  fallbacks: []"
    else
      echo "  fallbacks:"
      for route_index in "${!ROUTES[@]}"; do
        route="${ROUTES[$route_index]}"
        local fallback_models=()
        for level in 1 2 3; do
          prefix="$(provider_prefix_for_level "$level")"
          if [[ "$(provider_tier_status "$prefix")" == "ready" ]]; then
            fallback_models+=( "$(route_model_name "$route" "$level")" )
          fi
        done
        if [[ "${#fallback_models[@]}" -gt 0 ]]; then
          render_fallback_entry "$route" "${fallback_models[@]}"
        fi
      done
    fi
  } >"$tmp_file"

  mv "$tmp_file" "$CONFIG_FILE"
}

route_chain_summary() {
  local route_index="$1"
  local route="${ROUTES[$route_index]}"
  local route_key="${ROUTE_KEYS[$route_index]}"
  local summary=""
  local level prefix model_var model_name

  for level in 0 1 2 3; do
    prefix="$(provider_prefix_for_level "$level")"
    if [[ "$(provider_tier_status "$prefix")" == "ready" ]]; then
      model_var="${prefix}_${route_key}_MODEL"
      model_name="${!model_var:-}"
      if [[ -n "$summary" ]]; then
        summary+=" ${C_DIM}->${C_RESET} "
      fi
      summary+="$(provider_label_for_level "$level") (${C_BWHITE}${model_name}${C_RESET})"
    fi
  done

  if [[ -z "$summary" ]]; then
    summary="${C_DIM}not configured${C_RESET}"
  fi

  printf "  ${C_BOLD}${C_CYAN}%-12s${C_RESET} %s\n" "$route" "$summary"
}

print_provider_summary() {
  local level prefix status

  ui_section "Provider Tiers"
  ui_table_header "Tier" 12 "Status" 20
  ui_table_divider 12 20
  for level in 0 1 2 3; do
    prefix="$(provider_prefix_for_level "$level")"
    status="$(provider_tier_status "$prefix")"
    printf "  ${C_BOLD}%-12s${C_RESET}" "$prefix"
    printf " %s\n" "$(ui_status_badge "$status")"
  done

  echo ""
  ui_section "Route Chains"
  for level in "${!ROUTES[@]}"; do
    route_chain_summary "$level"
  done
}

cmd_provider_list() {
  load_env
  print_provider_summary
}

cmd_provider_render() {
  require_configured_env
  render_litellm_config
  ui_success "Rendered $CONFIG_FILE from $ENV_FILE"
}

cmd_provider_edit() {
  local tier_name="${1:-main}"
  local level
  level="$(provider_index_from_name "$tier_name")" || {
    ui_error "Unknown provider tier: ${tier_name}"
    return 1
  }

  ensure_env_file
  load_env

  if [[ "$level" -ne 0 ]]; then
    local previous_level=$((level - 1))
    local previous_prefix
    previous_prefix="$(provider_prefix_for_level "$previous_level")"
    if [[ "$(provider_tier_status "$previous_prefix")" != "ready" ]]; then
      ui_error "configure $(provider_label_for_level "$previous_level") before $(provider_label_for_level "$level")."
      return 1
    fi
  fi

  prompt_provider_tier "$level"
  render_litellm_config
  ui_success "Updated $(provider_label_for_level "$level") provider and rendered $CONFIG_FILE"
}

cmd_provider_disable() {
  local tier_name="${1:-fallback}"
  local level
  if [[ "$tier_name" == "all" || "$tier_name" == "fallbacks" ]]; then
    level=1
  else
    level="$(provider_index_from_name "$tier_name")" || {
      ui_error "Unknown provider tier: ${tier_name}"
      return 1
    }
  fi

  if [[ "$level" -eq 0 ]]; then
    ui_error "The main provider cannot be disabled."
    return 1
  fi

  ensure_env_file
  load_env
  disable_provider_tier_from_level "$level"
  render_litellm_config
  ui_success "Disabled $(provider_label_for_level "$level") and higher fallback tiers."
}

cmd_provider_configure() {
  ensure_env_file
  load_env

  prompt_provider_tier 0

  local level prefix status answer default_answer
  for level in 1 2 3; do
    prefix="$(provider_prefix_for_level "$level")"
    status="$(provider_tier_status "$prefix")"
    if [[ "$status" == "empty" ]]; then
      default_answer="n"
    else
      default_answer="y"
    fi

    if [[ "$default_answer" == "y" ]]; then
      read -rp "Configure $(provider_label_for_level "$level") provider? [Y/n]: " answer
    else
      read -rp "Configure $(provider_label_for_level "$level") provider? [y/N]: " answer
    fi
    answer="${answer:-$default_answer}"

    if [[ "$answer" =~ ^[Yy]$ ]]; then
      if [[ "$level" -gt 1 ]]; then
        local previous_prefix
        previous_prefix="$(provider_prefix_for_level $((level - 1)))"
        if [[ "$(provider_tier_status "$previous_prefix")" != "ready" ]]; then
          ui_error "configure $(provider_label_for_level $((level - 1))) before $(provider_label_for_level "$level")."
          return 1
        fi
      fi
      prompt_provider_tier "$level"
    else
      disable_provider_tier_from_level "$level"
      break
    fi
  done

  render_litellm_config
  ui_success "Provider configuration updated and rendered $CONFIG_FILE"
}

cmd_provider_help() {
  ui_header "Usage: ./manage.sh provider <command>"
  echo ""
  ui_table_header "Command" 14 "Description" 40
  ui_table_divider 14 40
  ui_table_row "list" 14 "显示 provider 状态和路由链" 40
  ui_table_row "configure" 14 "向导式配置主 provider 和 fallback tiers" 40
  ui_table_row "edit" 14 "编辑指定 tier: main/fallback/fallback2/3" 40
  ui_table_row "disable" 14 "禁用指定 tier 及更深层 fallback" 40
  ui_table_row "render" 14 "从 .env 重新生成 LiteLLM 配置" 40
  echo ""
}

show_provider_menu() {
  echo ""
  ui_thick_divider 52
  printf "  ${C_BOLD}${C_BMAGENTA}⚙  Provider 管理${C_RESET}\n"
  ui_divider '-' 52

  ui_menu_item "1" "list"            "查看当前 provider 状态"
  ui_menu_item "2" "configure"       "向导式配置主 provider 和 fallback tiers"
  ui_menu_item "3" "edit main"       "单独编辑主 provider"
  ui_menu_item "4" "edit fallback"   "单独编辑第一层 fallback"
  ui_menu_item "5" "edit fallback2"  "单独编辑第二层 fallback"
  ui_menu_item "6" "edit fallback3"  "单独编辑第三层 fallback"
  ui_menu_item "7" "disable fb1"     "禁用 fallback 及更深层"
  ui_menu_item "8" "disable fb2"     "禁用 fallback2 及更深层"
  ui_menu_item "9" "disable fb3"     "只禁用 fallback3"
  ui_menu_item "10" "render"         "重新生成 LiteLLM 配置"
  ui_menu_item "0" "back"            "返回主菜单"
  ui_divider '-' 52
  echo ""
}

provider_menu() {
  while true; do
    load_env
    show_provider_menu
    print_provider_summary
    echo ""
    local choice
    choice="$(prompt_choice "Select an option [0-10]: " '^[0-9]+$')"
    case "$choice" in
      1) cmd_provider_list ;;
      2) cmd_provider_configure ;;
      3) cmd_provider_edit main ;;
      4) cmd_provider_edit fallback ;;
      5) cmd_provider_edit fallback2 ;;
      6) cmd_provider_edit fallback3 ;;
      7) cmd_provider_disable fallback ;;
      8) cmd_provider_disable fallback2 ;;
      9) cmd_provider_disable fallback3 ;;
      10) cmd_provider_render ;;
      0) return 0 ;;
      *) ui_warning "无效选项，请重新选择" ;;
    esac
    echo ""
  done
}

cmd_provider() {
  local action="${1:-list}"
  case "$action" in
    list) cmd_provider_list ;;
    configure) cmd_provider_configure ;;
    edit) shift; cmd_provider_edit "${1:-main}" ;;
    disable) shift; cmd_provider_disable "${1:-fallback}" ;;
    render|sync) cmd_provider_render ;;
    help|-h|--help) cmd_provider_help ;;
    *)
      ui_error "Unknown provider command: $action"
      cmd_provider_help
      return 1
      ;;
  esac
}
