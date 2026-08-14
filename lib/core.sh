#!/usr/bin/env bash
# @file: lib/core.sh
# @author: redskaber
# @desc: Cross-cutting foundation — config resolution, logging, tmux wrappers,
#        validation, and low-level UI helpers (colors / prompts).
# @arch: Core Layer — depended on by every other lib module. No deps on siblings.
# @deps: bash 4.4+, tmux 3.x, jq
# @sourcing: side-effect free; only defines functions + readonly constants.

# Guard against double-source.
[[ -n "${_TX_CORE_LOADED:-}" ]] && return 0
_TX_CORE_LOADED=1

# ============================================================
# === Constants                                            ===
# ============================================================

readonly TX_VERSION="2.0.0"
readonly TX_AUTHOR="redskaber"
readonly TX_SCHEMA_SNAPSHOT="tx.snapshot.v1"
readonly TX_SCHEMA_INDEX="tx.index.v1"
readonly TX_SCHEMA_GROUPS="tx.groups.v1"

# Reserved group for auto-snapshots.
readonly TX_GROUP_AUTO="auto"
readonly TX_GROUP_DEFAULT="default"

# ============================================================
# === Path / Config resolution                             ===
# ============================================================

# Resolve the project root (where lib/ lives).
# Strategy (robust against symlinks, renamed binaries, CWD):
#   1. TX_HOME env if set and valid
#   2. BASH_SOURCE of THIS file (lib/core.sh) → parent
#   3. Walk PATH: for each `tx` binary found, resolve its real dir
#   4. Common install locations as last resort
core_resolve_home() {
  local candidate
  # 1. env override
  if [[ -n "${TX_HOME:-}" && -d "$TX_HOME/lib" && -f "$TX_HOME/lib/core.sh" ]]; then
    printf '%s\n' "$TX_HOME"
    return 0
  fi
  # 2. derive from this file's location (works when sourced from bin/tx)
  candidate="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
  if [[ -n "$candidate" && -f "$candidate/lib/core.sh" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  # 3. walk PATH for a `tx` binary
  local p
  IFS=':' read -ra _path_parts <<< "${PATH:-}"
  for p in "${_path_parts[@]}"; do
    [[ -z "$p" ]] && continue
    if [[ -x "$p/tx" ]]; then
      local real
      real="$(readlink -f "$p/tx" 2>/dev/null || echo "$p/tx")"
      candidate="$(cd "$(dirname "$real")/.." 2>/dev/null && pwd)"
      if [[ -n "$candidate" && -f "$candidate/lib/core.sh" ]]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    fi
  done
  # 4. common install locations
  for candidate in "$HOME/.config/tmux" "$HOME/.tmux-config" "/usr/local/share/tmux-config"; do
    if [[ -f "$candidate/lib/core.sh" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

# Resolve the absolute path to the `tx` executable for use in tmux run-shell /
# popup contexts where PATH may not include ~/.local/bin.
core_resolve_tx_bin() {
  # 1. explicit override
  if [[ -n "${TX_BIN:-}" && -x "$TX_BIN" ]]; then
    printf '%s\n' "$TX_BIN"
    return 0
  fi
  # 2. next to lib/core.sh (project layout: <home>/bin/tx)
  local home; home="$(core_resolve_home 2>/dev/null || true)"
  if [[ -n "$home" && -x "$home/bin/tx" ]]; then
    printf '%s\n' "$home/bin/tx"
    return 0
  fi
  # 3. on PATH
  local p
  p="$(command -v tx 2>/dev/null || true)"
  if [[ -n "$p" ]]; then
    printf '%s\n' "$p"
    return 0
  fi
  # 4. common install symlinks
  for p in "$HOME/.local/bin/tx" "$HOME/.config/tmux/bin/tx"; do
    [[ -x "$p" ]] && { printf '%s\n' "$p"; return 0; }
  done
  return 1
}

# Resolve where snapshot DATA lives. Separate from code (XDG-ish).
# Override: TX_STORE_DIR env. Default: $HOME/.local/share/tx
core_resolve_store_dir() {
  if [[ -n "${TX_STORE_DIR:-}" ]]; then
    printf '%s\n' "$TX_STORE_DIR"
  else
    printf '%s\n' "${HOME}/.local/share/tx"
  fi
}

# Ensure store subdirs exist. Idempotent.
core_ensure_store_dirs() {
  local store
  store="$(core_resolve_store_dir)"
  mkdir -p "$store/snapshots" "$store"
}

core_snapshots_dir() {
  printf '%s/snapshots\n' "$(core_resolve_store_dir)"
}

core_index_file() {
  printf '%s/index.json\n' "$(core_resolve_store_dir)"
}

core_groups_file() {
  printf '%s/groups.json\n' "$(core_resolve_store_dir)"
}

# (core_config_get removed — unused. Env vars + TX_STORE_DIR cover all needs.)

# ============================================================
# === Color / TTY detection                                 ===
# ============================================================

# Disable color automatically when output is not a terminal, unless TX_COLOR=force.
core_color_enabled() {
  if [[ "${TX_COLOR:-}" == "force" ]]; then return 0; fi
  if [[ "${TX_COLOR:-}" == "never" ]]; then return 1; fi
  [[ -t 1 ]]
}

core_c() {
  # core_c <name> — echo the escape code for a color name (empty if disabled).
  local name="$1"
  if ! core_color_enabled; then printf ''; return; fi
  case "$name" in
    reset)  printf '\033[0m' ;;
    bold)   printf '\033[1m' ;;
    dim)    printf '\033[2m' ;;
    red)    printf '\033[31m' ;;
    green)  printf '\033[32m' ;;
    yellow) printf '\033[33m' ;;
    blue)   printf '\033[34m' ;;
    magenta) printf '\033[35m' ;;
    cyan)   printf '\033[36m' ;;
    gray)   printf '\033[90m' ;;
    *) printf '' ;;
  esac
}

# ============================================================
# === Logging                                              ===
# ============================================================

# Log levels: debug < info < warn < error. Controlled by TX_LOG_LEVEL.
core_log_level_num() {
  case "${1:-info}" in
    debug) printf 0 ;; info) printf 1 ;; warn) printf 2 ;; error) printf 3 ;; *) printf 1 ;;
  esac
}

core_log() {
  local level="$1"; shift
  local cur threshold
  cur="$(core_log_level_num "$level")"
  threshold="$(core_log_level_num "${TX_LOG_LEVEL:-info}")"
  (( cur < threshold )) && return 0

  local prefix icon color
  case "$level" in
    debug) icon="·";   color="$(core_c dim)"   ;;
    info)  icon="›";   color="$(core_c cyan)"  ;;
    warn)  icon="!";   color="$(core_c yellow)" ;;
    error) icon="✗";   color="$(core_c red)"   ;;
    *)     icon=" ";   color="" ;;
  esac
  printf '%s%s%s %s\n' "$color" "$icon" "$(core_c reset)" "$*" >&2
}

core_debug() { core_log debug "$@"; }
core_info()  { core_log info  "$@"; }
core_warn()  { core_log warn  "$@"; }
core_error() { core_log error "$@"; }

# Print a success line to stderr (green check).
core_ok() {
  printf '%s✓%s %s\n' "$(core_c green)" "$(core_c reset)" "$*" >&2
}

# Die with an error message and exit code.
core_die() {
  local msg="$1" code="${2:-1}"
  core_error "$msg"
  exit "$code"
}

# ============================================================
# === tmux wrappers                                        ===
# ============================================================

# Is there a running tmux server (any sessions)?
core_tmux_alive() {
  command tmux list-sessions >/dev/null 2>&1
}

# Run a tmux command. If invoked from inside tmux, normal; if outside,
# we still target the server (tmux auto-starts one for list-commands too).
core_tmux() {
  command tmux "$@"
}

# Name of the currently attached session, or empty if not in tmux.
core_tmux_current_session() {
  [[ -n "${TMUX:-}" ]] || return 0
  core_tmux display-message -p '#S' 2>/dev/null
}

# List session names (one per line). Empty if no server.
core_tmux_list_sessions() {
  core_tmux list-sessions -F '#{session_name}' 2>/dev/null || true
}

# Does a session exist?
core_tmux_has_session() {
  local s="$1"
  core_tmux has-session -t "$s" 2>/dev/null
}

# Kill a session if it exists.
core_tmux_kill_session() {
  local s="$1"
  core_tmux has-session -t "$s" 2>/dev/null && core_tmux kill-session -t "$s" 2>/dev/null || true
}

# tmux version string (e.g. "3.5a").
core_tmux_version() {
  core_tmux -V 2>/dev/null | awk '{print $2}'
}

# ============================================================
# === Index numbering (standardized resolution)            ===
# ============================================================

# Resolve the EFFECTIVE base-index for a session (session-level if set, else
# global default, else the tmux builtin default of 0).
# Echoes a validated integer. Never empty. Never non-numeric.
# core_tmux_base_index [session]
core_tmux_base_index() {
  local session="${1:-}" v=""
  if [[ -n "$session" ]]; then
    v="$(core_tmux show-options -v -t "$session" base-index 2>/dev/null || true)"
  fi
  [[ -n "$v" ]] || v="$(core_tmux show-options -g -v base-index 2>/dev/null || true)"
  [[ -n "$v" ]] || v=0
  # Validate: must be a non-negative integer.
  [[ "$v" =~ ^[0-9]+$ ]] || v=0
  printf '%s\n' "$v"
}

# Resolve the EFFECTIVE pane-base-index for a session (window option).
# core_tmux_pane_base_index [session]
core_tmux_pane_base_index() {
  local session="${1:-}" v=""
  if [[ -n "$session" ]]; then
    v="$(core_tmux show-window-options -v -t "$session" pane-base-index 2>/dev/null || true)"
  fi
  [[ -n "$v" ]] || v="$(core_tmux show-window-options -g -v pane-base-index 2>/dev/null || true)"
  [[ -n "$v" ]] || v=0
  [[ "$v" =~ ^[0-9]+$ ]] || v=0
  printf '%s\n' "$v"
}

# ============================================================
# === Validation                                           ===
# ============================================================

# Validate a human name (snapshot/group). Allowed: [A-Za-z0-9._-], 1..64 chars,
# may not start with a dash. Returns 0 if valid, prints reason to stderr otherwise.
core_validate_name() {
  local name="$1"
  if [[ -z "$name" ]]; then
    core_error "name cannot be empty"
    return 1
  fi
  if (( ${#name} > 64 )); then
    core_error "name too long (max 64): $name"
    return 1
  fi
  if [[ "$name" == -* ]]; then
    core_error "name must not start with '-': $name"
    return 1
  fi
  if [[ ! "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
    core_error "name has invalid chars (allowed: A-Z a-z 0-9 . _ -): $name"
    return 1
  fi
  return 0
}

# Validate an ID (8 hex chars).
core_validate_id() {
  local id="$1"
  if [[ ! "$id" =~ ^[0-9a-f]{8}$ ]]; then
    core_error "invalid id format (expected 8 hex chars): $id"
    return 1
  fi
  return 0
}

# Validate a tag (alphanumeric, dot, dash, plus).
core_validate_tag() {
  local t="$1"
  if [[ -z "$t" ]]; then return 1; fi
  if (( ${#t} > 32 )); then return 1; fi
  [[ "$t" =~ ^[A-Za-z0-9._+-]+$ ]]
}

# ============================================================
# === ID & time generation                                 ===
# ============================================================

# Generate a short unique id (8 hex chars).
core_gen_id() {
  local raw
  if [[ -r /dev/urandom ]]; then
    raw="$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  else
    raw="$(printf '%s%d' "$RANDOM" "$(date +%s%N)")"
  fi
  printf '%s\n' "${raw:0:8}"
}

# ISO-8601 local timestamp with offset.
core_now_iso() {
  date +%Y-%m-%dT%H:%M:%S%:z
}

# (core_iso_to_epoch removed — unused, and GNU date -d is not portable to macOS.)

# ============================================================
# === UI helpers                                           ===
# ============================================================

# core_confirm <prompt> [default(y/n)] — returns 0 on yes.
# Non-interactive (no TTY) → uses default.
core_confirm() {
  local prompt="$1" default="${2:-n}"
  if [[ ! -t 0 ]]; then
    [[ "$default" == "y" ]]
    return $?
  fi
  local hint
  if [[ "$default" == "y" ]]; then hint="Y/n"; else hint="y/N"; fi
  local answer
  printf '%s [%s] ' "$prompt" "$hint" >&2
  read -r answer
  answer="${answer:-$default}"
  case "${answer:0:1}" in
    y|Y) return 0 ;;
    *) return 1 ;;
  esac
}

# Print a section header.
core_header() {
  local title="$1"
  printf '\n%s%s══ %s ══%s\n' \
    "$(core_c bold)" "$(core_c cyan)" "$title" "$(core_c reset)"
}

# Pad/truncate a string to a width (printf %-W truncates, but multi-byte safe here).
core_truncate() {
  local str="$1" width="$2"
  if (( ${#str} > width )); then
    printf '%s…' "${str:0:$((width-1))}"
  else
    printf '%-*s' "$width" "$str"
  fi
}

# (core_jq_escape removed — unused; jq --arg handles escaping.)
