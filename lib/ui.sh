#!/usr/bin/env bash
# @file: lib/ui.sh
# @author: redskaber
# @desc: Presentation layer — formatters (tables, trees) and the interactive
#        fzf picker with live preview.
# @arch: UI Layer — depends on lib/core.sh. Pure presentation; no business logic.
# @deps: bash 4.4+, jq, fzf (for interactive picker)
# @sourcing: requires core.sh sourced first.

[[ -n "${_TX_UI_LOADED:-}" ]] && return 0
_TX_UI_LOADED=1

# Path to the tx binary (used to build fzf preview commands).
# Uses the robust resolver from core.sh so the picker's preview works even
# when invoked from a tmux popup where PATH may not include ~/.local/bin.
ui_tx_bin() {
  local p
  p="$(core_resolve_tx_bin 2>/dev/null || true)"
  [[ -n "$p" ]] && { printf '%s\n' "$p"; return 0; }
  # Last resort: bare `tx` (relies on PATH).
  printf '%s\n' "tx"
}

# ============================================================
# === Shared fzf styling (aligned with zsh fzf-tab)        ===
# ============================================================
# Centralized so every fzf call site looks consistent. The defaults match the
# common fzf-tab configuration (prompt ❯, pointer ▶, marker ✓, border none,
# height 55%, cycle, no-bold, info inline-right). Override via TX_FZF_OPTS env.
#
# WHY a helper instead of per-call flags: "拒绝特解" — a single source of truth
# for the visual style. Change once here, all pickers update. The user's
# zsh.nix configures fzf-tab with these exact flags; tx now matches.
ui_fzf_common_flags() {
  # Allow full override: if TX_FZF_OPTS is set, use it verbatim.
  if [[ -n "${TX_FZF_OPTS:-}" ]]; then
    printf '%s\n' "$TX_FZF_OPTS"
    return 0
  fi
  # Default theme — mirrors the zsh fzf-tab config:
  #   --height=55% --layout=reverse --border=none --info=inline-right
  #   --prompt='❯ ' --pointer='▶' --marker='✓' --ansi --cycle --no-bold
  # Catppuccin Mocha accents (consistent with tmux.conf status bar).
  printf '%s\n' \
    --ansi \
    --height=55% \
    --layout=reverse \
    --border=none \
    --info=inline-right \
    --prompt='❯ ' \
    --pointer='▶' \
    --marker='✓' \
    --cycle \
    --no-bold \
    --color='prompt:#cba6f7,pointer:#f38ba8,marker:#a6e3a1,header:#6c7086,info:#89dceb,hl:#f9e2af,hl+:#f9e2af'
}

# ============================================================
# === Formatters                                          ===
# ============================================================

# ui_format_list <json_array> — pretty table to stdout.
ui_format_list() {
  local arr="$1"
  if [[ "$(echo "$arr" | jq 'length')" -eq 0 ]]; then
    printf '%s(no snapshots)%s\n' "$(core_c dim)" "$(core_c reset)"
    return 0
  fi
  # Header
  printf '%s%-8s  %-22s  %-12s  %-18s  %-16s  %s%s\n' \
    "$(core_c bold)" "ID" "NAME" "GROUP" "TAGS" "CREATED" "SIZE" "$(core_c reset)"
  printf '%s\n' "$(core_c dim)$(printf '%.0s─' {1..90})$(core_c reset)"
  # Use ASCII unit separator (0x1F) — NOT tab — so empty fields (e.g. a
  # snapshot with no tags) are preserved by `read`. Tab is a whitespace IFS
  # char, so `read` collapses consecutive tabs (empty fields vanish).
  local fs=$'\x1f'
  echo "$arr" | jq -r --arg fs "$fs" '
    .[] |
    "\(.id)\($fs)\(.name)\($fs)\(.group)\($fs)\((.tags|join(",")))\($fs)\(.created_at)\($fs)\(.stats.sessions)s/\(.stats.windows)w/\(.stats.panes)p"
  ' | while IFS="$fs" read -r id name group tags created size; do
    local tag_disp=""
    [[ -n "$tags" ]] && tag_disp="#${tags//,/ #}"
    local short_created
    short_created="$(echo "$created" | cut -d'T' -f1,2 | sed 's/T/ /' | cut -d'.' -f1 | cut -d'+' -f1)"
    printf '%s%-8s%s  %-22s  %s%-12s%s  %-18s  %-16s  %s%s%s\n' \
      "$(core_c yellow)" "$id" "$(core_c reset)" \
      "$(core_truncate "$name" 22)" \
      "$(core_c cyan)" "$(core_truncate "$group" 12)" "$(core_c reset)" \
      "$(core_truncate "$tag_disp" 18)" \
      "$short_created" \
      "$(core_c dim)" "$size" "$(core_c reset)"
  done
}

# ui_format_groups <json_array> — groups table.
ui_format_groups() {
  local arr="$1"
  if [[ "$(echo "$arr" | jq 'length')" -eq 0 ]]; then
    printf '%s(no groups)%s\n' "$(core_c dim)" "$(core_c reset)"
    return 0
  fi
  printf '%s%-18s  %-8s  %s%s\n' \
    "$(core_c bold)" "NAME" "COUNT" "DESCRIPTION" "$(core_c reset)"
  printf '%s\n' "$(core_c dim)$(printf '%.0s─' {1..60})$(core_c reset)"
  echo "$arr" | jq -r '.[] | "\(.name)\t\(.count)\t\(.description // "")"' | \
  while IFS=$'\t' read -r name count desc; do
    printf '%s%-18s%s  %s%-8s%s  %s\n' \
      "$(core_c cyan)" "$(core_truncate "$name" 18)" "$(core_c reset)" \
      "$(core_c bold)" "$count" "$(core_c reset)" \
      "${desc:-}"
  done
}

# ui_format_show <snapshot_json> — detailed tree view.
ui_format_show() {
  local snap="$1"
  local id name group desc created scope tmux_v
  id="$(echo "$snap" | jq -r '.meta.id')"
  name="$(echo "$snap" | jq -r '.meta.name')"
  group="$(echo "$snap" | jq -r '.meta.group')"
  desc="$(echo "$snap" | jq -r '.meta.description // ""')"
  created="$(echo "$snap" | jq -r '.meta.created_at')"
  scope="$(echo "$snap" | jq -r '.meta.scope')"
  tmux_v="$(echo "$snap" | jq -r '.meta.tmux_version')"
  tags="$(echo "$snap" | jq -r '.meta.tags | join(", ")')"

  core_header "Snapshot"
  printf '  %s%-12s%s %s\n' "$(core_c dim)" "id:"    "$(core_c reset)" "$id"
  printf '  %s%-12s%s %s\n' "$(core_c dim)" "name:"  "$(core_c reset)" "$(core_c bold)$name$(core_c reset)"
  printf '  %s%-12s%s %s\n' "$(core_c dim)" "group:" "$(core_c reset)" "$(core_c cyan)$group$(core_c reset)"
  printf '  %s%-12s%s %s\n' "$(core_c dim)" "tags:"  "$(core_c reset)" "${tags:-(none)}"
  printf '  %s%-12s%s %s\n' "$(core_c dim)" "scope:" "$(core_c reset)" "$scope"
  printf '  %s%-12s%s %s\n' "$(core_c dim)" "created:" "$(core_c reset)" "$created"
  printf '  %s%-12s%s %s\n' "$(core_c dim)" "tmux:"  "$(core_c reset)" "$tmux_v"
  [[ -n "$desc" && "$desc" != "null" ]] && printf '  %s%-12s%s %s\n' "$(core_c dim)" "desc:" "$(core_c reset)" "$desc"

  local sc wc pc
  sc="$(echo "$snap" | jq '.stats.sessions')"
  wc="$(echo "$snap" | jq '.stats.windows')"
  pc="$(echo "$snap" | jq '.stats.panes')"
  core_header "Stats"
  printf '  %s sessions · %s windows · %s panes\n' \
    "$(core_c bold)$sc$(core_c reset)" \
    "$(core_c bold)$wc$(core_c reset)" \
    "$(core_c bold)$pc$(core_c reset)"

  core_header "Tree"
  echo "$snap" | jq -r '
    .sessions[] |
    "  ● \(.name)  base=\(.base_index // 1):\(.pane_base_index // 1)  \(.windows | length)w" ,
    (.windows[] |
     "    ▢ [\(.index)] \(.name)\(if .active then " *" else "" end)  layout=\(.layout[0:24] + (if (.layout|length) > 24 then "…" else "" end))",
     (.panes[] |
      "        □ \(.index)\(if .active then " *" else "" end)  \(.cwd)  \(.command)\(if .cmdline != "" and .cmdline != .command then "  ⟪\(.cmdline)⟫" else "" end)"))
  '
}

# ============================================================
# === Interactive picker (fzf)                             ===
# ============================================================

# ui_pick_snapshot <json_array> → echo selected id (empty if cancelled).
ui_pick_snapshot() {
  local arr="$1"
  command -v fzf >/dev/null 2>&1 || { core_error "fzf not installed"; return 1; }
  if [[ "$(echo "$arr" | jq 'length')" -eq 0 ]]; then
    core_warn "no snapshots to show"
    return 1
  fi

  local bin; bin="$(ui_tx_bin)"
  # Build display lines. FS = 0x1F (unit sep) so empty fields (e.g. no tags)
  # are preserved by `read` (tab would collapse them — see ui_format_list).
  local fs=$'\x1f'
  local lines
  lines="$(echo "$arr" | jq -r --arg fs "$fs" '
    .[] | "\(.id)\($fs)\(.name)\($fs)\(.group)\($fs)\((.tags|join(",")))\($fs)\(.stats.sessions)s/\(.stats.windows)w/\(.stats.panes)p\($fs)\(.created_at)"
  ' | while IFS="$fs" read -r id name group tags size created; do
    local tag_disp=""
    [[ -n "$tags" ]] && tag_disp="#${tags//,/ #}"
    local sc; sc="$(echo "$created" | cut -dT -f1,2 | sed 's/T/ /' | cut -d'.' -f1 | cut -d'+' -f1)"
    printf '%-8s  %-22s  %-12s  %-16s  %s  %s\n' "$id" "$(core_truncate "$name" 22)" "$group" "$(core_truncate "$tag_disp" 16)" "$size" "$sc"
  done)"

  local preview_cmd
  preview_cmd="$bin show {1} 2>/dev/null || echo '(no preview)'"

  local selected
  selected="$(printf '%s\n' "$lines" | fzf \
    $(ui_fzf_common_flags) \
    --header=$'  [Enter] load   [Ctrl-X] remove   [Ctrl-E] edit' \
    --preview="$preview_cmd" \
    --preview-window=right:50%:wrap \
    --expect="ctrl-x,ctrl-e" \
    2>/dev/null)" || return 1

  local key line id
  key="$(echo "$selected" | head -1)"
  line="$(echo "$selected" | tail -1)"
  id="$(echo "$line" | awk '{print $1}')"

  [[ -z "$id" ]] && return 1

  case "$key" in
    ctrl-x) printf 'rm:%s\n' "$id" ;;
    ctrl-e) printf 'edit:%s\n' "$id" ;;
    *)      printf '%s\n' "$id" ;;
  esac
}

# ui_pick_live_session → echo selected session name (empty if cancelled).
ui_pick_live_session() {
  command -v fzf >/dev/null 2>&1 || { core_error "fzf not installed"; return 1; }
  # tmux's -F engine escapes control bytes, so use a printable multi-char
  # delimiter (~~~) — same approach as snapshot.sh's _TX_TMUX_FS.
  local fs='~~~'
  local lines
  lines="$(core_tmux list-sessions -F "#{session_name}${fs}#{session_windows}${fs}#{session_created}${fs}#{session_attached}" 2>/dev/null \
    | while IFS="$fs" read -r n w c a; do
        [[ -z "$n" ]] && continue
        local att=""; [[ "$a" == "1" ]] && att=" (attached)"
        printf '%-20s  %sw%s  %s%s\n' "$n" "$(core_c dim)" "$w" "$(date -d "@$c" +%Y-%m-%d_%H:%M 2>/dev/null || echo "?")" "$att"
      done)"
  [[ -n "$lines" ]] || { core_warn "no live sessions"; return 1; }
  local sel
  sel="$(printf '%s\n' "$lines" | fzf \
    $(ui_fzf_common_flags) \
    2>/dev/null)" || return 1
  echo "$sel" | awk '{print $1}'
}

# ui_prompt_string <prompt> [default] → echo entered string.
ui_prompt_string() {
  local prompt="$1" default="${2:-}"
  if [[ ! -t 0 ]]; then
    printf '%s\n' "$default"
    return 0
  fi
  local val
  printf '%s' "$prompt" >&2
  [[ -n "$default" ]] && printf ' [%s]' "$default" >&2
  printf ': ' >&2
  read -r val
  printf '%s\n' "${val:-$default}"
}
