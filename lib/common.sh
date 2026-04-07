#!/usr/bin/env bash
# lib/common.sh — shared utilities: env file ops, prompts, compose wrapper

MODE_FILE="$PROJECT_DIR/.mode"

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
    echo "Created $ENV_FILE with auto-generated master key."
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

require_configured_env() {
  validate_provider_chain
}

compose() {
  resolve_compose_file
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}
