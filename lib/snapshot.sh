#!/usr/bin/env bash
# @file: lib/snapshot.sh
# @author: redskaber
# @desc: Snapshot engine — capture live tmux state to JSON, restore JSON to
#        tmux, and diff two snapshots.
# @arch: Domain Layer — depends only on lib/core.sh.
# @deps: bash 4.4+, tmux 3.x, jq
# @sourcing: requires core.sh sourced first.

[[ -n "${_TX_SNAPSHOT_LOADED:-}" ]] && return 0
_TX_SNAPSHOT_LOADED=1

# shellcheck source=core.sh
# (core.sh is sourced by bin/tx before this file.)

# ============================================================
# === Helpers                                              ===
# ============================================================

# Read full command line for a PID (Linux /proc). Empty if unavailable.
snapshot_read_cmdline() {
  local pid="$1"
  [[ -z "$pid" || "$pid" == "0" ]] && return 0
  local f="/proc/$pid/cmdline"
  [[ -r "$f" ]] || return 0
  # Arguments are NUL-separated; join with space, strip trailing NULs.
  tr '\0' ' ' < "$f" | sed 's/ *$//'
}

# Is the given command name a plain interactive shell?
snapshot_is_shell() {
  case "$1" in
    bash|zsh|fish|sh|dash|ksh|tcsh|csh|nu) return 0 ;;
    *) return 1 ;;
  esac
}

# Field delimiter for jq-produced output (snapshot diff). 0x1F is a
# non-whitespace control char → `read` preserves empty fields. Safe here
# because this never passes through tmux's -F engine (which escapes controls).
readonly _TX_FS=$'\x1f'

# Delimiter for tmux -F output. tmux's format engine ESCAPES raw control bytes
# (a 0x1F becomes the literal text "\037"), so we cannot use a control char.
# TAB is a whitespace IFS char → `read` collapses consecutive tabs (empty
# fields like detached session_width would vanish and misalign everything).
# Solution: a printable multi-char token that tmux won't escape and that will
# not legitimately appear in paths / commands / window-names / layouts.
readonly _TX_TMUX_FS='~~~'

# Format string for tmux list-panes -a (one line per pane, ~~~-separated).
# Order MUST match the parsing in snapshot_capture.
_snapshot_pane_fmt() {
  local f="${_TX_TMUX_FS}"
  printf '%s' \
    "#{session_name}${f}#{session_attached}${f}#{session_width}${f}#{session_height}" \
    "${f}#{window_index}${f}#{window_name}${f}#{window_active}${f}#{window_layout}" \
    "${f}#{pane_index}${f}#{pane_id}${f}#{pane_active}${f}#{pane_current_path}" \
    "${f}#{pane_current_command}${f}#{pane_pid}${f}#{pane_width}${f}#{pane_height}" \
    "${f}#{pane_left}${f}#{pane_top}"
}

# Split a ~~~-delimited line into the global array _TX_FIELDS.
# Preserves empty fields (unlike IFS=tab). Uses newline substitution + mapfile.
_tx_split() {
  local line="$1"
  mapfile -t -d $'\n' _TX_FIELDS <<< "${line//${_TX_TMUX_FS}/$'\n'}"
}

# ============================================================
# === Capture                                              ===
# ============================================================

# snapshot_capture <scope>  → emits snapshot JSON on stdout.
# scope: "current" | "all" | "<session-name>"
snapshot_capture() {
  local scope="${1:-current}"

  core_tmux_alive || core_die "no running tmux server" 3

  # --- Resolve sessions in scope ---
  local -a want=()
  case "$scope" in
    current)
      local cur; cur="$(core_tmux_current_session)"
      [[ -n "$cur" ]] || core_die "not inside a tmux session (use --all)" 3
      want=("$cur")
      ;;
    all)
      while IFS= read -r s; do [[ -n "$s" ]] && want+=("$s"); done < <(core_tmux_list_sessions)
      (( ${#want[@]} > 0 )) || core_die "no tmux sessions running" 3
      ;;
    *)
      core_tmux_has_session "$scope" || core_die "no such session: $scope" 3
      want=("$scope")
      ;;
  esac

  # --- Capture base-index / pane-base-index per session (standardized) ---
  # Uses core_tmux_base_index / core_tmux_pane_base_index which resolve the
  # EFFECTIVE value (session-level → global → 0) and validate it's an integer.
  # This is the single source of truth for index numbering.
  declare -A base_index pane_base_index
  local s
  for s in "${want[@]}"; do
    base_index["$s"]="$(core_tmux_base_index "$s")"
    pane_base_index["$s"]="$(core_tmux_pane_base_index "$s")"
  done

  # --- One tmux call to enumerate ALL panes with full context ---
  local raw
  raw="$(core_tmux list-panes -a -F "$(_snapshot_pane_fmt)" 2>/dev/null)" \
    || core_die "tmux list-panes failed" 3

  # --- Build flat JSON records (one per pane), filtered to scope ---
  local tmp; tmp="$(mktemp)"
  {
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      _tx_split "$line"
      local sname="${_TX_FIELDS[0]:-}"  satt="${_TX_FIELDS[1]:-0}"
      local sw="${_TX_FIELDS[2]:-0}"    sh="${_TX_FIELDS[3]:-0}"
      local widx="${_TX_FIELDS[4]:-0}"  wname="${_TX_FIELDS[5]:-}"
      local wactive="${_TX_FIELDS[6]:-0}" wlayout="${_TX_FIELDS[7]:-}"
      local pidx="${_TX_FIELDS[8]:-0}"  pid_="${_TX_FIELDS[9]:-}"
      local pactive="${_TX_FIELDS[10]:-0}" pcwd="${_TX_FIELDS[11]:-}"
      local pcmd="${_TX_FIELDS[12]:-}"  ppid="${_TX_FIELDS[13]:-0}"
      local pw="${_TX_FIELDS[14]:-0}"   ph="${_TX_FIELDS[15]:-0}"
      local px="${_TX_FIELDS[16]:-0}"   py="${_TX_FIELDS[17]:-0}"

      # scope filter
      local keep=0 ss
      for ss in "${want[@]}"; do [[ "$sname" == "$ss" ]] && keep=1 && break; done
      (( keep )) || continue

      # full command line (best-effort)
      local cmdline; cmdline="$(snapshot_read_cmdline "$ppid")"

      # Coerce possibly-empty numeric fields to 0 (detached sessions have
      # no session_width/height; some formats may yield empty strings).
      local _satt="${satt:-0}" _sw="${sw:-0}" _sh="${sh:-0}"
      local _widx="${widx:-0}" _wactive="${wactive:-0}"
      local _pidx="${pidx:-0}" _pactive="${pactive:-0}" _ppid="${ppid:-0}"
      local _pw="${pw:-0}" _ph="${ph:-0}" _px="${px:-0}" _py="${py:-0}"
      # Final guard: ensure they are integers (else 0).
      [[ "$_satt"    =~ ^[0-9]+$ ]] || _satt=0
      [[ "$_sw"      =~ ^[0-9]+$ ]] || _sw=0
      [[ "$_sh"      =~ ^[0-9]+$ ]] || _sh=0
      [[ "$_widx"    =~ ^[0-9]+$ ]] || _widx=0
      [[ "$_wactive" =~ ^[0-9]+$ ]] || _wactive=0
      [[ "$_pidx"    =~ ^[0-9]+$ ]] || _pidx=0
      [[ "$_pactive" =~ ^[0-9]+$ ]] || _pactive=0
      [[ "$_ppid"    =~ ^[0-9]+$ ]] || _ppid=0
      [[ "$_pw"      =~ ^[0-9]+$ ]] || _pw=0
      [[ "$_ph"      =~ ^[0-9]+$ ]] || _ph=0
      [[ "$_px"      =~ ^[0-9]+$ ]] || _px=0
      [[ "$_py"      =~ ^[0-9]+$ ]] || _py=0

      jq -c -n \
        --arg session "$sname" \
        --argjson attached "$_satt" \
        --argjson swidth "$_sw" \
        --argjson sheight "$_sh" \
        --argjson windex "$_widx" \
        --arg wname "$wname" \
        --argjson wactive "$_wactive" \
        --arg wlayout "$wlayout" \
        --argjson pindex "$_pidx" \
        --arg pane_id "$pid_" \
        --argjson pactive "$_pactive" \
        --arg cwd "$pcwd" \
        --arg command "$pcmd" \
        --argjson pid "$_ppid" \
        --arg cmdline "$cmdline" \
        --argjson width "$_pw" \
        --argjson height "$_ph" \
        --argjson x "$_px" \
        --argjson y "$_py" \
        '{session:$session, attached:$attached, swidth:$swidth, sheight:$sheight,
          windex:$windex, wname:$wname, wactive:$wactive, wlayout:$wlayout,
          pindex:$pindex, pane_id:$pane_id, pactive:$pactive, cwd:$cwd,
          command:$command, pid:$pid, cmdline:$cmdline,
          width:$width, height:$height, x:$x, y:$y}'
    done <<< "$raw"
  } > "$tmp"

  [[ -s "$tmp" ]] || { rm -f "$tmp"; core_die "captured no panes (empty result)" 3; }

  # --- Nest flat records into sessions → windows → panes ---
  local nested
  nested="$(jq -s '
    group_by(.session) | map({
      name: .[0].session,
      attached: .[0].attached,
      width: .[0].swidth,
      height: .[0].sheight,
      windows: (group_by(.windex) | map({
        index: .[0].windex,
        name: .[0].wname,
        active: (.[0].wactive == 1),
        layout: .[0].wlayout,
        panes: (map({
          index: .pindex,
          id: .pane_id,
          active: (.pactive == 1),
          cwd: .cwd,
          command: .command,
          pid: .pid,
          cmdline: .cmdline,
          width: .width,
          height: .height,
          x: .x,
          y: .y
        }) | sort_by(.index))
      }) | sort_by(.index))
    })
  ' "$tmp")"
  rm -f "$tmp"

  # --- Attach per-session base-index info + wrap with meta ---
  # Build a lookup object { "<session>": {base_index, pane_base_index} }.
  local lookup_json='{}'
  for s in "${want[@]}"; do
    lookup_json="$(jq -n --arg s "$s" \
      --argjson bi "${base_index[$s]}" \
      --argjson pbi "${pane_base_index[$s]}" \
      --arg prev "$lookup_json" \
      '($prev | fromjson) + {($s): {base_index:$bi, pane_base_index:$pbi}}')"
  done

  local scope_label
  if (( ${#want[@]} == 1 )); then scope_label="session"; else scope_label="all"; fi

  jq -n \
    --arg schema "$TX_SCHEMA_SNAPSHOT" \
    --argjson sessions "$nested" \
    --argjson bi_lookup "$lookup_json" \
    --arg scope "$scope_label" \
    --arg tmux_version "$(core_tmux_version)" \
    --arg tx_version "$TX_VERSION" \
    --arg captured_at "$(core_now_iso)" \
    '{
      schema: $schema,
      meta: {
        scope: $scope,
        tmux_version: $tmux_version,
        tx_version: $tx_version,
        captured_at: $captured_at
      },
      sessions: ($sessions | map(. + {base_index: ($bi_lookup[.name].base_index // 0),
                                      pane_base_index: ($bi_lookup[.name].pane_base_index // 0)}))
    }'
}

# ============================================================
# === Restore                                              ===
# ============================================================

# snapshot_restore <snapshot_json> [opts]
# opts (env-style, parsed by caller into globals):
#   TX_OPT_REPLACE=1   kill existing target sessions first
#   TX_OPT_ATTACH=1    attach/switch-client after restore
#   TX_OPT_COMMANDS=1  re-run captured commands in panes
#   TX_OPT_KEEP_CWD=1  ignore stored cwd (use current)
# Returns 0 on success. Prints the list of restored sessions.
snapshot_restore() {
  local snap_json="$1"
  local store_dir; store_dir="$(core_resolve_store_dir)"

  [[ -n "$snap_json" ]] || core_die "empty snapshot json" 3
  echo "$snap_json" | jq -e '.sessions' >/dev/null 2>&1 || core_die "invalid snapshot json (no .sessions)" 3

  local replace="${TX_OPT_REPLACE:-0}"
  local attach="${TX_OPT_ATTACH:-0}"
  local commands="${TX_OPT_COMMANDS:-0}"
  local keep_cwd="${TX_OPT_KEEP_CWD:-0}"

  local session_count window_count pane_count
  session_count="$(echo "$snap_json" | jq '.sessions | length')"
  core_info "restoring $session_count session(s) [replace=$replace commands=$commands attach=$attach]"

  local restored=()
  local i
  for (( i=0; i<session_count; i++ )); do
    local sjson
    sjson="$(echo "$snap_json" | jq -c ".sessions[$i]")"
    local sname base pbi swidth sheight
    sname="$(echo "$sjson" | jq -r '.name')"
    base="$(echo "$sjson" | jq -r '.base_index // 0')"
    pbi="$(echo "$sjson" | jq -r '.pane_base_index // 0')"
    swidth="$(echo "$sjson" | jq -r '.width // 0')"
    sheight="$(echo "$sjson" | jq -r '.height // 0')"
    # Detached sessions capture size 0 (no client) — fall back to a sane default.
    (( swidth > 0 )) || swidth=200
    (( sheight > 0 )) || sheight=50

    # Name collision handling
    if core_tmux_has_session "$sname"; then
      if (( replace )); then
        core_warn "replacing existing session: $sname"
        core_tmux_kill_session "$sname"
      else
        # Rename to avoid clobber: append -<id>-N
        sname="${sname}-restored-$$"
        core_warn "session exists; restoring as: $sname"
      fi
    fi

    _restore_one_session "$sjson" "$sname" "$base" "$pbi" "$swidth" "$sheight" "$commands" "$keep_cwd" \
      || core_die "failed to restore session: $sname" 3
    restored+=("$sname")
  done

  # Attach / switch
  if (( attach )) && (( ${#restored[@]} > 0 )); then
    local target="${restored[0]}"
    if [[ -n "${TMUX:-}" ]]; then
      core_tmux switch-client -t "$target" 2>/dev/null && core_ok "switched to: $target"
    else
      core_info "attach with: tmux attach -t $target"
    fi
  fi

  printf '%s\n' "${restored[@]}"
}

# Restore a single session from its JSON.
_restore_one_session() {
  local sjson="$1" sname="$2" base="$3" pbi="$4" swidth="$5" sheight="$6" commands="$7" keep_cwd="$8"

  local wcount
  wcount="$(echo "$sjson" | jq '.windows | length')"
  (( wcount > 0 )) || { core_warn "session '$sname' has no windows; skipping"; return 0; }

  # First window's first pane defines the new-session seed.
  local w0json w0name w0p0cwd
  w0json="$(echo "$sjson" | jq -c '.windows[0]')"
  w0name="$(echo "$w0json" | jq -r '.name')"
  w0p0cwd="$(echo "$w0json" | jq -r '.panes[0].cwd')"
  (( keep_cwd )) && w0p0cwd="$(pwd)"

  # Validate / fallback cwd
  _safe_cwd w0p0cwd

  # Create detached session with first window. Capture tmux's stderr so we can
  # report the REAL reason on failure (don't blanket-suppress with 2>/dev/null).
  local ns_err
  ns_err="$(core_tmux new-session -d -s "$sname" -n "$w0name" -c "$w0p0cwd" \
              -x "${swidth:-200}" -y "${sheight:-50}" 2>&1 >/dev/null)" || \
    core_die "cannot create session '$sname': ${ns_err:-unknown tmux error}" 3

  # Align index numbering with the saved snapshot.
  # base-index / pane-base-index retroactively renumber existing windows/panes;
  # move-window -r shifts the auto-created window 0 up to base-index so the
  # saved window indices line up with the restored ones.
  core_tmux set-option -t "$sname" base-index "$base" 2>/dev/null || true
  core_tmux set-window-option -t "$sname" pane-base-index "$pbi" 2>/dev/null || true
  core_tmux move-window -r -t "$sname" 2>/dev/null || true

  # Restore each window.
  local j
  for (( j=0; j<wcount; j++ )); do
    local wjson wname wlayout wpanes pcount
    wjson="$(echo "$sjson" | jq -c ".windows[$j]")"
    wname="$(echo "$wjson" | jq -r '.name')"
    wlayout="$(echo "$wjson" | jq -r '.layout')"
    pcount="$(echo "$wjson" | jq '.panes | length')"

    # Target window index (base-relative). Window 0 already exists for j==0.
    local widx
    widx="$(echo "$wjson" | jq -r '.index')"

    if (( j == 0 )); then
      # The first window was created by new-session. Rename it to the saved
      # name. Try the saved index first, fall back to the session's current.
      core_tmux rename-window -t "$sname:$widx" "$wname" 2>/dev/null \
        || core_tmux rename-window -t "$sname" "$wname" 2>/dev/null || true
    else
      # Create the window. Capture stderr so we report the REAL tmux error
      # (not a generic "cannot create") — critical for cross-version debugging.
      local seed_cwd
      seed_cwd="$(echo "$wjson" | jq -r '.panes[0].cwd')"
      (( keep_cwd )) && seed_cwd="$(pwd)"
      _safe_cwd seed_cwd
      local nw_out
      nw_out="$(core_tmux new-window -t "$sname:" -n "$wname" -c "$seed_cwd" -P 2>&1)" || \
        core_die "cannot create window '$wname' in session '$sname': ${nw_out:-tmux error}" 3
    fi

    # Resolve the ACTUAL current index of this window (by name within the
    # session), rather than assuming it equals the saved index. This is robust
    # against base-index / renumber-windows interactions across tmux versions
    # (3.5a vs 3.6a) which is the root cause of the "cannot create window" bug.
    local cur_widx
    cur_widx="$(core_tmux list-windows -t "$sname" -F '#{window_index}#{window_name}' 2>/dev/null \
                  | awk -v n="$wname" '$0 ~ n"$" {sub(n"$","",$0); print $0; exit}')"
    [[ -n "$cur_widx" ]] || cur_widx="$widx"
    core_debug "window '$wname' → actual index $cur_widx"

    # Set pane-base-index for THIS window (a window option is NOT inherited by
    # newly-created windows). tmux retroactively renumbers existing panes.
    core_tmux set-window-option -t "$sname:$cur_widx" pane-base-index "$pbi" 2>/dev/null || true

    # Ensure correct number of panes.
    local existing
    existing="$(core_tmux list-panes -t "$sname:$cur_widx" 2>/dev/null | wc -l | tr -d ' ')"
    while (( existing < pcount )); do
      local split_cwd
      split_cwd="$(echo "$wjson" | jq -r ".panes[$existing].cwd")"
      (( keep_cwd )) && split_cwd="$(pwd)"
      _safe_cwd split_cwd
      core_tmux split-window -t "$sname:$cur_widx" -c "$split_cwd" 2>/dev/null || true
      existing=$(( existing + 1 ))
    done
    # If snapshot had fewer panes than current, kill extras (shouldn't happen normally).
    while (( existing > pcount )); do
      core_tmux kill-pane -t "$sname:$cur_widx.$((pbi + pcount))" 2>/dev/null || break
      existing=$(( existing - 1 ))
    done

    # Apply saved layout (geometry). select-layout reshapes existing panes.
    if [[ -n "$wlayout" && "$wlayout" != "null" ]]; then
      core_tmux select-layout -t "$sname:$cur_widx" "$wlayout" 2>/dev/null \
        || core_debug "layout apply failed for $sname:$cur_widx ($wlayout)"
    fi

    # Optionally re-run commands + set active pane.
    local p
    for (( p=0; p<pcount; p++ )); do
      local pjson pcmd pcwd pactive pid_target
      pjson="$(echo "$wjson" | jq -c ".panes[$p]")"
      pcmd="$(echo "$pjson" | jq -r '.command')"
      pcwd="$(echo "$pjson" | jq -r '.cwd')"
      pactive="$(echo "$pjson" | jq -r '.active')"
      pid_target="$sname:$cur_widx.$((pbi + p))"

      if (( commands )) && [[ -n "$pcmd" && "$pcmd" != "null" ]] && ! snapshot_is_shell "$pcmd"; then
        local cmdline
        cmdline="$(echo "$pjson" | jq -r '.cmdline // empty')"
        [[ -z "$cmdline" ]] && cmdline="$pcmd"
        # cd into cwd first, then run command
        if (( ! keep_cwd )) && [[ -n "$pcwd" && "$pcwd" != "null" && -d "$pcwd" ]]; then
          core_tmux send-keys -t "$pid_target" "cd $(printf %q "$pcwd")" C-m 2>/dev/null || true
        fi
        core_tmux send-keys -t "$pid_target" "$cmdline" C-m 2>/dev/null || true
      fi

      if [[ "$pactive" == "true" ]]; then
        core_tmux select-pane -t "$pid_target" 2>/dev/null || true
      fi
    done

    # Select active window if marked (by name — robust to index renumbering).
    local wactive
    wactive="$(echo "$wjson" | jq -r '.active')"
    [[ "$wactive" == "true" ]] && core_tmux select-window -t "$sname:$cur_widx" 2>/dev/null || true
  done

  # Select the active window of the session (resolve by name, not saved index,
  # since indices may have shifted during restore).
  local aw_name
  aw_name="$(echo "$sjson" | jq -r '[.windows[] | select(.active==true)] | .[0].name // .windows[0].name')"
  if [[ -n "$aw_name" && "$aw_name" != "null" ]]; then
    local aw_idx
    aw_idx="$(core_tmux list-windows -t "$sname" -F '#{window_index}#{window_name}' 2>/dev/null \
                | awk -v n="$aw_name" '$0 ~ n"$" {sub(n"$","",$0); print $0; exit}')"
    [[ -n "$aw_idx" ]] && core_tmux select-window -t "$sname:$aw_idx" 2>/dev/null || true
  fi

  return 0
}

# Ensure a cwd is usable; fall back to $HOME otherwise.
_safe_cwd() {
  local ref="$1"
  if [[ -z "${!ref:-}" || "${!ref}" == "null" || ! -d "${!ref}" ]]; then
    printf -v "$ref" '%s' "$HOME"
  fi
}

# ============================================================
# === Diff                                                 ===
# ============================================================

# snapshot_diff <json_a> <json_b>  → human-readable diff on stdout.
# Compares structure: sessions, windows, panes (cwd/command).
snapshot_diff() {
  local a="$1" b="$2"
  echo "$a" | jq -e '.sessions' >/dev/null 2>&1 || core_die "snapshot A invalid" 3
  echo "$b" | jq -e '.sessions' >/dev/null 2>&1 || core_die "snapshot B invalid" 3

  # Flatten both into FS-separated lines, then diff.
  local fa fb
  fa="$(echo "$a" | jq -r --arg fs "$_TX_FS" '
    .sessions[] | .name as $s | .windows[] | .index as $w | .name as $wn |
    .panes[] | "\($s):\($w)\($fs)\($wn)\($fs)\(.index)\($fs)\(.cwd)\($fs)\(.command)"')"
  fb="$(echo "$b" | jq -r --arg fs "$_TX_FS" '
    .sessions[] | .name as $s | .windows[] | .index as $w | .name as $wn |
    .panes[] | "\($s):\($w)\($fs)\($wn)\($fs)\(.index)\($fs)\(.cwd)\($fs)\(.command)"')"

  local tmpa tmpb
  tmpa="$(mktemp)"; tmpb="$(mktemp)"
  printf '%s\n' "$fa" > "$tmpa"
  printf '%s\n' "$fb" > "$tmpb"

  local na nb
  na="$(printf '%s\n' "$fa" | grep -c . || true)"
  nb="$(printf '%s\n' "$fb" | grep -c . || true)"

  printf '%s%s A → %s panes   %s B → %s panes%s\n' \
    "$(core_c dim)" "$(core_c bold)" "$na" "$(core_c bold)" "$nb" "$(core_c reset)"

  # Lines only in A (removed/changed), only in B (added/changed).
  local onlya onlyb
  onlya="$(comm -23 <(sort "$tmpa") <(sort "$tmpb"))"
  onlyb="$(comm -13 <(sort "$tmpa") <(sort "$tmpb"))"

  if [[ -z "$onlya" && -z "$onlyb" ]]; then
    printf '%sidentical%s\n' "$(core_c green)" "$(core_c reset)"
    rm -f "$tmpa" "$tmpb"
    return 0
  fi

  if [[ -n "$onlya" ]]; then
    printf '\n%s— only in A:%s\n' "$(core_c red)" "$(core_c reset)"
    while IFS= read -r ln; do
      [[ -z "$ln" ]] && continue
      local s w wn p c cmd
      IFS="$_TX_FS" read -r s wn p c cmd <<< "$ln"
      printf '  %s%s:%s%s %s  %s\n' "$(core_c dim)" "$s" "$p" "$(core_c reset)" "$c" "$cmd"
    done <<< "$onlya"
  fi
  if [[ -n "$onlyb" ]]; then
    printf '\n%s+ only in B:%s\n' "$(core_c green)" "$(core_c reset)"
    while IFS= read -r ln; do
      [[ -z "$ln" ]] && continue
      local s w wn p c cmd
      IFS="$_TX_FS" read -r s wn p c cmd <<< "$ln"
      printf '  %s%s:%s%s %s  %s\n' "$(core_c dim)" "$s" "$p" "$(core_c reset)" "$c" "$cmd"
    done <<< "$onlyb"
  fi

  rm -f "$tmpa" "$tmpb"
}
