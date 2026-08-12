#!/usr/bin/env bash
# @file: scripts/tmux-layouts.sh
# @author: redskaber
# @desc: Static layout dispatcher — Registry → FZF Select → Strategy Route → Executor.
#        Applies a pane-geometry template (dashboard/dev/git/monitor/writing) to
#        the current or a new session. Complementary to `tx` (which snapshots
#        live state); this is for fresh template-based scaffolding.
# @arch: Layered pipeline with policy-driven strategy management
# @deps: tmux 3.x, fzf 0.67+, bash 4+
# @usage: bind L run-shell "~/.config/tmux/scripts/tmux-layouts.sh"

set -euo pipefail

# ============================================================
# === Layer 0: Runtime resolution                          ===
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_ROOT="$(dirname "$SCRIPT_DIR")"
LAYOUTS_POLICY_DIR="${CONFIG_ROOT}/policy/layouts"

# ============================================================
# === Layer 1: Registry — scan & parse policy/layouts/*    ===
# ============================================================
# Entry format (FS-separated, pipeline-safe): NAME FS DESC FS PANES FS TAGS FS FILE

readonly _FS=$'\x1f'

registry_scan() {
  [[ -d "$LAYOUTS_POLICY_DIR" ]] || {
    echo "ERROR: layouts policy dir not found: $LAYOUTS_POLICY_DIR" >&2
    exit 1
  }
  while IFS= read -r -d '' policy_file; do
    [[ -f "$policy_file" && -r "$policy_file" ]] || continue
    local name desc panes tags
    name=$(grep -m1 '^# @layout:' "$policy_file" 2>/dev/null | sed 's/^# @layout:[[:space:]]*//' | tr -d '\r')
    desc=$(grep -m1 '^# @description:' "$policy_file" 2>/dev/null | sed 's/^# @description:[[:space:]]*//' | tr -d '\r')
    panes=$(grep -m1 '^# @panes:' "$policy_file" 2>/dev/null | sed 's/^# @panes:[[:space:]]*//' | tr -d '\r')
    tags=$(grep -m1 '^# @tags:' "$policy_file" 2>/dev/null | sed 's/^# @tags:[[:space:]]*//' | tr -d '\r')
    name="${name:-$(basename "$policy_file")}"
    desc="${desc:-(no description)}"
    panes="${panes:-?}"
    tags="${tags:-}"
    printf '%s%s%s%s%s%s%s%s%s\n' "$name" "$_FS" "$desc" "$_FS" "$panes" "$_FS" "$tags" "$_FS" "$policy_file"
  done < <(find "$LAYOUTS_POLICY_DIR" -maxdepth 1 -type f -print0 | sort -z)
}

# ============================================================
# === Layer 2: Formatter — registry → FZF display          ===
# ============================================================

format_for_fzf() {
  while IFS="$_FS" read -r name desc panes tags _filepath; do
    local tag_display=""
    [[ -n "$tags" ]] && tag_display=" #${tags//,/ #}"
    printf "%-14s  %-38s  [%s panes]%s\n" "$name" "$desc" "$panes" "$tag_display"
  done
}

# ============================================================
# === Layer 3: FZF selector                                ===
# ============================================================

run_fzf_selector() {
  local fzf_list
  fzf_list="$(registry_scan | format_for_fzf)"
  [[ -n "$fzf_list" ]] || { tmux display-message "no layouts found"; exit 0; }

  # Shared fzf flags — aligned with zsh fzf-tab theme (prompt ❯, border none,
  # height 55%, cycle, no-bold). Override via TX_FZF_OPTS env.
  local common_flags
  if [[ -n "${TX_FZF_OPTS:-}" ]]; then
    common_flags="$TX_FZF_OPTS"
  else
    common_flags="--ansi --height=55% --layout=reverse --border=none --info=inline-right --prompt='❯ ' --pointer='▶' --marker='✓' --cycle --no-bold --color=prompt:#cba6f7,pointer:#f38ba8,marker:#a6e3a1,header:#6c7086,info:#89dceb,hl:#f9e2af,hl+:#f9e2af"
  fi

  # shellcheck disable=SC2086
  fzf_list | fzf \
    $common_flags \
    --no-preview \
    --header=$'  [Enter] NEW session    [Ctrl-O] OVER current' \
    --expect="ctrl-o" \
    2>/dev/null || return 1
}

# ============================================================
# === Layer 4: Strategy router                             ===
# ============================================================

parse_selection() {
  local fzf_output="$1"
  local key_line layout_line
  key_line=$(echo "$fzf_output" | head -1)
  layout_line=$(echo "$fzf_output" | tail -1)
  local layout_name
  layout_name=$(echo "$layout_line" | awk '{print $1}' | tr -d '[:space:]')
  [[ -z "$layout_name" ]] && { echo "ERROR: no layout selected" >&2; return 1; }
  local mode="NEW"
  [[ "$key_line" == "ctrl-o" ]] && mode="OVER"
  printf '%s %s\n' "$mode" "$layout_name"
}

# ============================================================
# === Layer 5: Policy loader                               ===
# ============================================================

load_policy() {
  local layout_name="$1"
  registry_scan | while IFS="$_FS" read -r name _desc _panes _tags filepath; do
    if [[ "$name" == "$layout_name" ]]; then echo "$filepath"; break; fi
  done
}

# ============================================================
# === Layer 6: Executors                                   ===
# ============================================================

executor_new() {
  local layout_name="$1" policy_file="$2"
  local session_name="${layout_name}-$(date +%H%M%S)"
  tmux new-session -d -s "$session_name" -x 220 -y 50 2>/dev/null || {
    session_name="${layout_name}-$(date +%s)"
    tmux new-session -d -s "$session_name" -x 220 -y 50
  }
  ( # shellcheck source=/dev/null
    source "$policy_file"; layout_apply "$session_name" "1"
  )
  tmux switch-client -t "$session_name"
  tmux display-message "NEW session '${session_name}' (layout: ${layout_name})"
}

executor_over() {
  local layout_name="$1" policy_file="$2"
  local cur_session cur_window
  cur_session=$(tmux display-message -p '#S')
  cur_window=$(tmux display-message -p '#I')
  ( # shellcheck source=/dev/null
    source "$policy_file"; layout_apply "$cur_session" "$cur_window"
  )
  tmux display-message "Applied layout '${layout_name}' to ${cur_session}:${cur_window}"
}

# ============================================================
# === Layer 7: Pipeline entrypoint                         ===
# ============================================================

main() {
  local fzf_output
  fzf_output="$(run_fzf_selector)" || exit 0
  local route mode layout_name
  route="$(parse_selection "$fzf_output")" || exit 1
  mode=$(echo "$route" | cut -d' ' -f1)
  layout_name=$(echo "$route" | cut -d' ' -f2)
  local policy_file
  policy_file="$(load_policy "$layout_name")"
  [[ -n "$policy_file" && -f "$policy_file" ]] || { echo "ERROR: no policy for $layout_name" >&2; exit 1; }
  case "$mode" in
    NEW)  executor_new  "$layout_name" "$policy_file" ;;
    OVER) executor_over "$layout_name" "$policy_file" ;;
  esac
}

main "$@"
