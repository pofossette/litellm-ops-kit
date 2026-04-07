#!/usr/bin/env bash
# lib/common.sh — shared utilities: env file ops, prompts, compose wrapper

generate_master_key() {
  printf 'sk-%s' "$(openssl rand -hex 24)"
}

ensure_env_file() {
  if [[ ! -f "$ENV_FILE" ]]; then
    cp "$ENV_EXAMPLE_FILE" "$ENV_FILE"
    local generated_key
    generated_key="$(generate_master_key)"
    env_write "LITELLM_MASTER_KEY" "$generated_key"
    echo "Created $ENV_FILE with auto-generated master key."
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
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}
