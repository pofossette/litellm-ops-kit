#!/usr/bin/env bash
# lib/ui.sh -- terminal UI beautification: colors, symbols, dividers, tables

# -- Colors (with graceful fallback) --

if [[ -t 1 ]] && command -v tput &>/dev/null && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
  C_RESET='\033[0m'
  C_BOLD='\033[1m'
  C_DIM='\033[2m'
  C_RED='\033[31m'
  C_GREEN='\033[32m'
  C_YELLOW='\033[33m'
  C_BLUE='\033[34m'
  C_MAGENTA='\033[35m'
  C_CYAN='\033[36m'
  C_WHITE='\033[37m'
  C_BRED='\033[91m'
  C_BGREEN='\033[92m'
  C_BYELLOW='\033[93m'
  C_BBLUE='\033[94m'
  C_BMAGENTA='\033[95m'
  C_BCYAN='\033[96m'
  C_BWHITE='\033[97m'
else
  C_RESET='' C_BOLD='' C_DIM=''
  C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_MAGENTA='' C_CYAN='' C_WHITE=''
  C_BRED='' C_BGREEN='' C_BYELLOW='' C_BBLUE='' C_BMAGENTA='' C_BCYAN='' C_BWHITE=''
fi

# -- Status symbols (ASCII only, wide terminal compat) --

S_OK="${C_GREEN}+${C_RESET}"
S_FAIL="${C_RED}x${C_RESET}"
S_WARN="${C_YELLOW}!${C_RESET}"
S_INFO="${C_BLUE}i${C_RESET}"
S_DOT="${C_CYAN}*${C_RESET}"
S_CIRCLE="${C_DIM}o${C_RESET}"
S_ARROW="${C_CYAN}>${C_RESET}"

# -- Dividers --

ui_divider() {
  local char="${1:--}"
  local width="${2:-52}"
  printf "${C_DIM}%s${C_RESET}\n" "$(printf '%*s' "$width" '' | tr ' ' "$char")"
}

ui_thick_divider()  { ui_divider '=' "${1:-52}"; }
ui_dotted_divider() { ui_divider '-' "${1:-52}"; }

# -- Headers & sections --

ui_header() {
  local title="${1:-}"
  local width="${2:-52}"
  echo ""
  ui_thick_divider "$width"
  printf "  ${C_BOLD}${C_BCYAN}%s${C_RESET}\n" "$title"
  ui_divider '-' "$width"
}

ui_section() {
  local title="${1:-}"
  printf "\n  ${C_BOLD}${C_BBLUE}> %s${C_RESET}\n" "$title"
  ui_divider '-' 42
}

# -- Key-value & labels --

ui_kv() {
  local key="${1:-}"
  local value="${2:-}"
  local color="${3:-$C_BWHITE}"
  printf "  ${C_BOLD}${C_CYAN}%-14s${C_RESET} ${color}%s${C_RESET}\n" "$key" "$value"
}

ui_kv_dim() {
  local key="${1:-}"
  local value="${2:-}"
  printf "  ${C_DIM}%-14s %s${C_RESET}\n" "$key" "$value"
}

# -- Status badges --

ui_status_badge() {
  local status="${1:-}"
  case "$status" in
    ready|enabled|running|started|up)
      printf "${C_GREEN}${C_BOLD}[+] %s${C_RESET}" "$status" ;;
    empty|disabled|stopped|none|down)
      printf "${C_DIM}[o] %s${C_RESET}" "$status" ;;
    invalid|error|failed|exited)
      printf "${C_RED}${C_BOLD}[x] %s${C_RESET}" "$status" ;;
    *)
      printf "[*] %s" "$status" ;;
  esac
}

# -- Message helpers --

ui_success() { printf "\n  ${C_GREEN}${C_BOLD}[+] %s${C_RESET}\n" "${1:-}"; }
ui_error()   { printf "\n  ${C_RED}${C_BOLD}[x] %s${C_RESET}\n" "${1:-}" >&2; }
ui_warning() { printf "\n  ${C_YELLOW}${C_BOLD}[!] %s${C_RESET}\n" "${1:-}"; }
ui_info()    { printf "  ${C_BLUE}[i] %s${C_RESET}\n" "${1:-}"; }

# -- Menu items --

ui_menu_item() {
  local key="${1:-}" label="${2:-}" desc="${3:-}"
  printf "  ${C_BOLD}${C_CYAN}%3s${C_RESET}) ${C_BOLD}%-18s${C_RESET} ${C_DIM}%s${C_RESET}\n" "$key" "$label" "$desc"
}

# -- Code / command block --

ui_code() {
  printf "  ${C_DIM}  %s${C_RESET}\n" "${1:-}"
}

# -- Box drawing (ASCII only) --

ui_box() {
  local title="${1:-}"
  shift || true
  local lines=("$@")
  local max_len=${#title}
  for line in "${lines[@]+"${lines[@]}"}"; do
    (( ${#line} > max_len )) && max_len=${#line}
  done
  local inner=$((max_len + 2))
  local top="  +$(printf '%*s' "$inner" '' | tr ' ' '=')+"
  local bot="  +$(printf '%*s' "$inner" '' | tr ' ' '=')+"

  printf "${C_CYAN}%s${C_RESET}\n" "$top"
  printf "${C_CYAN}  |${C_RESET} ${C_BOLD}${C_BCYAN}%-*s${C_RESET} ${C_CYAN}|${C_RESET}\n" "$inner" "$title"
  if [[ ${#lines[@]} -gt 0 ]]; then
    printf "${C_CYAN}  +$(printf '%*s' "$inner" '' | tr ' ' '-')+${C_RESET}\n"
    for line in "${lines[@]}"; do
      printf "${C_CYAN}  |${C_RESET} %-*s ${C_CYAN}|${C_RESET}\n" "$inner" "$line"
    done
  fi
  printf "${C_CYAN}%s${C_RESET}\n" "$bot"
}

# -- Table helper --

ui_table_header() {
  local -a parts=()
  while [[ $# -gt 1 ]]; do
    local text="$1" width="$2"
    shift 2
    parts+=("$(printf "${C_BOLD}${C_WHITE}%-*s${C_RESET}" "$width" "$text")")
  done
  printf "  %s\n" "${parts[*]}"
}

ui_table_row() {
  local -a parts=()
  while [[ $# -gt 1 ]]; do
    local text="$1" width="$2"
    shift 2
    parts+=("$(printf "%-*s" "$width" "$text")")
  done
  printf "  %s\n" "${parts[*]}"
}

ui_table_divider() {
  local -a parts=()
  local width
  for width in "$@"; do
    parts+=("$(printf '%-*s' "$width" '' | tr ' ' '-')")
  done
  printf "  ${C_DIM}%s${C_RESET}\n" "${parts[*]}"
}
