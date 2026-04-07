#!/usr/bin/env bash
# lib/common.sh — shared utilities: env file ops, prompts, compose wrapper

MODE_FILE="$PROJECT_DIR/.mode"
ENV_BATCH_FILE=""

generate_master_key() {
  printf 'sk-%s' "$(openssl rand -hex 24)"
}

# ── Mode management ──

get_mode() {
  if [[ -f "$MODE_FILE" ]]; then
    cat "$MODE_FILE"
  else
    echo "none"
  fi
}

set_mode() {
  local mode="$1"
  printf '%s' "$mode" > "$MODE_FILE"
  # Update COMPOSE_FILE to match the mode
  COMPOSE_FILE="$PROJECT_DIR/docker-compose.${mode}.yml"
}

resolve_compose_file() {
  local mode
  mode="$(get_mode)"
  case "$mode" in
    lite) COMPOSE_FILE="$PROJECT_DIR/docker-compose.lite.yml" ;;
    full) COMPOSE_FILE="$PROJECT_DIR/docker-compose.full.yml" ;;
    *)
      # Legacy: if old docker-compose.yml exists, treat as full mode
      if [[ -f "$PROJECT_DIR/docker-compose.yml" ]]; then
        COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
      else
        COMPOSE_FILE="$PROJECT_DIR/docker-compose.full.yml"
      fi
      ;;
  esac
}

# ── Env file ──

ensure_env_file() {
  if [[ ! -f "$ENV_FILE" ]]; then
    local mode
    mode="$(get_mode)"
    local template
    case "$mode" in
      lite) template="$PROJECT_DIR/.env.example.lite" ;;
      *)    template="$PROJECT_DIR/.env.example.full" ;;
    esac
    cp "$template" "$ENV_FILE"
    local generated_key
    generated_key="$(generate_master_key)"
    env_write "LITELLM_MASTER_KEY" "$generated_key"
    env_write "UI_PASSWORD" "$generated_key"
    echo "Created $ENV_FILE with auto-generated master key and UI password."
    ui_info "Edit the endpoint URLs, API keys, and model IDs before starting the service."
  fi
}

load_env() {
  ensure_env_file
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
}

is_placeholder_value() {
  local value="${1:-}"
  [[ -z "$value" || "$value" == "replace-me" || "$value" == https://your-* ]]
}

env_get() {
  local var_name="$1"
  printf '%s' "${!var_name:-}"
}

env_write() {
  local key="$1"
  local value="$2"
  local tmp_file
  tmp_file="$(mktemp)"
  local updated=0
  local line

  touch "$ENV_FILE"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$key="* ]]; then
      printf '%s=%s\n' "$key" "$value" >>"$tmp_file"
      updated=1
    else
      printf '%s\n' "$line" >>"$tmp_file"
    fi
  done <"$ENV_FILE"

  if [[ "$updated" -eq 0 ]]; then
    printf '%s=%s\n' "$key" "$value" >>"$tmp_file"
  fi

  mv "$tmp_file" "$ENV_FILE"
}

env_write_in_file() {
  local target_file="$1"
  local key="$2"
  local value="$3"
  local tmp_file
  tmp_file="$(mktemp)"
  local updated=0
  local line

  touch "$target_file"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$key="* ]]; then
      printf '%s=%s\n' "$key" "$value" >>"$tmp_file"
      updated=1
    else
      printf '%s\n' "$line" >>"$tmp_file"
    fi
  done <"$target_file"

  if [[ "$updated" -eq 0 ]]; then
    printf '%s=%s\n' "$key" "$value" >>"$tmp_file"
  fi

  mv "$tmp_file" "$target_file"
}

env_unset() {
  local key="$1"
  local tmp_file
  tmp_file="$(mktemp)"
  local line

  touch "$ENV_FILE"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" != "$key="* ]]; then
      printf '%s\n' "$line" >>"$tmp_file"
    fi
  done <"$ENV_FILE"

  mv "$tmp_file" "$ENV_FILE"
}

env_unset_in_file() {
  local target_file="$1"
  local key="$2"
  local tmp_file
  tmp_file="$(mktemp)"
  local line

  touch "$target_file"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" != "$key="* ]]; then
      printf '%s\n' "$line" >>"$tmp_file"
    fi
  done <"$target_file"

  mv "$tmp_file" "$target_file"
}

env_batch_begin() {
  ENV_BATCH_FILE="$(mktemp)"
}

env_batch_set() {
  local key="$1"
  local value="$2"
  printf 'set\t%s\t%s\n' "$key" "$value" >>"$ENV_BATCH_FILE"
}

env_batch_unset() {
  local key="$1"
  printf 'unset\t%s\n' "$key" >>"$ENV_BATCH_FILE"
}

env_batch_apply() {
  local staged_env
  staged_env="$(mktemp)"
  cp "$ENV_FILE" "$staged_env"

  while IFS=$'\t' read -r op key value || [[ -n "$op" ]]; do
    case "$op" in
      set) env_write_in_file "$staged_env" "$key" "$value" ;;
      unset) env_unset_in_file "$staged_env" "$key" ;;
    esac
  done <"$ENV_BATCH_FILE"

  mv "$staged_env" "$ENV_FILE"
  rm -f "$ENV_BATCH_FILE"
  ENV_BATCH_FILE=""
}

env_batch_discard() {
  rm -f "$ENV_BATCH_FILE"
  ENV_BATCH_FILE=""
}

prompt_value() {
  local label="$1"
  local current="$2"
  local is_secret="${3:-0}"
  local display="$current"
  local input

  if [[ "$is_secret" -eq 1 && -n "$current" ]]; then
    display="<set>"
  elif [[ -z "$current" ]]; then
    display="<empty>"
  fi

  read -rp "${label} [${display}]: " input
  if [[ -z "$input" ]]; then
    printf '%s' "$current"
  else
    printf '%s' "$input"
  fi
}

prompt_choice() {
  local prompt="$1"
  local valid_spec="${2:-}"
  local choice

  while true; do
    read -rp "$prompt" choice
    if [[ -z "$valid_spec" || "$choice" =~ $valid_spec ]]; then
      printf '%s' "$choice"
      return 0
    fi
    echo "Invalid option. Please try again."
  done
}

prompt_port_value() {
  local label="$1"
  local current="$2"
  local default_value="${3:-}"
  local input value

  while true; do
    input="$(prompt_value "$label" "${current:-$default_value}")"
    value="${input:-$default_value}"
    if [[ "$value" =~ ^[0-9]+$ ]] && ((value >= 1 && value <= 65535)); then
      printf '%s' "$value"
      return 0
    fi
    ui_warning "请输入 1-65535 的端口号。"
  done
}

prompt_scheme_value() {
  local label="$1"
  local current="$2"
  local default_value="${3:-https}"
  local input value

  while true; do
    input="$(prompt_value "$label" "${current:-$default_value}")"
    value="${input:-$default_value}"
    if [[ "$value" == "http" || "$value" == "https" ]]; then
      printf '%s' "$value"
      return 0
    fi
    ui_warning "只能填写 http 或 https。"
  done
}

require_configured_env() {
  validate_provider_chain
}

compose() {
  resolve_compose_file
  ensure_env_file
  load_env

  local -a profile_args=()
  local proxy_profile
  proxy_profile="$(proxy_profile_name 2>/dev/null || true)"
  if [[ -n "$proxy_profile" ]]; then
    profile_args+=(--profile "$proxy_profile")
  fi

  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "${profile_args[@]}" "$@"
}
