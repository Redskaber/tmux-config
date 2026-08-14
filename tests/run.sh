#!/usr/bin/env bash
# @file: tests/run.sh
# @author: redskaber
# @desc: Test suite for tmux-config / tx. Unit + integration tests against a
#        real, isolated tmux server and a throwaway store.
# @usage: ./tests/run.sh [-v]
# @deps: tmux 3.x, jq, fzf, bash 4.4+

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
BIN="$PROJECT_DIR/bin/tx"

# Isolated environment
export TX_STORE_DIR="${TX_STORE_DIR:-/tmp/tx-test-suite-$$}"
export TX_HOME="$PROJECT_DIR"
export TX_COLOR=never
export TX_LOG_LEVEL=error
export TERM=xterm-256color
# Ensure tmux/fzf on PATH (sandbox installs them under ~/.local/bin)
export PATH="$HOME/.local/bin:$PATH"

# tmux test config (base-index 1)
TMUX_TEST_CONF="$(mktemp)"
cat > "$TMUX_TEST_CONF" <<'EOF'
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on
set -g default-terminal "xterm-256color"
EOF

# ---------- Counters ----------
PASS=0; FAIL=0; SKIP=0
VERBOSE=0
[[ "${1:-}" == "-v" ]] && VERBOSE=1

# ---------- Assertions ----------
_red()   { printf '\033[31m%s\033[0m' "$*"; }
_green() { printf '\033[32m%s\033[0m' "$*"; }
_yellow(){ printf '\033[33m%s\033[0m' "$*"; }
_dim()   { printf '\033[2m%s\033[0m' "$*"; }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    if (( VERBOSE )); then printf '  %s %s\n' "$(_green ✓)" "$(_dim "$desc")"; fi
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); printf '  %s %s\n' "$(_red ✗)" "$desc"
    printf '      expected: [%s]\n' "$expected"
    printf '      actual:   [%s]\n' "$actual"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]] || grep -qF -- "$needle" <<<"$haystack"; then
    if (( VERBOSE )); then printf '  %s %s\n' "$(_green ✓)" "$(_dim "$desc")"; fi
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); printf '  %s %s\n' "$(_red ✗)" "$desc"
    printf '      expected to contain: [%s]\n' "$needle"
    printf '      in: [%s]\n' "$haystack"
  fi
}

assert_match() {
  local desc="$1" regex="$2" str="$3"
  if [[ "$str" =~ $regex ]]; then
    if (( VERBOSE )); then printf '  %s %s\n' "$(_green ✓)" "$(_dim "$desc")"; fi
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); printf '  %s %s\n' "$(_red ✗)" "$desc"
    printf '      expected to match: /%s/\n' "$regex"
    printf '      got: [%s]\n' "$str"
  fi
}

assert_json() {
  local desc="$1" json="$2"
  if echo "$json" | jq -e '.' >/dev/null 2>&1; then
    if (( VERBOSE )); then printf '  %s %s\n' "$(_green ✓)" "$(_dim "$desc")"; fi
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); printf '  %s %s (invalid JSON)\n' "$(_red ✗)" "$desc"
  fi
}

# ---------- Setup / teardown ----------
setup_tmux() {
  tmux kill-server 2>/dev/null || true
  rm -rf "$TX_STORE_DIR"
}

teardown_tmux() {
  # Per-test: kill server + clear store. Do NOT remove the shared config file
  # (it is reused by every test; removed only on final exit).
  tmux kill-server 2>/dev/null || true
  rm -rf "$TX_STORE_DIR"
}

final_cleanup() {
  tmux kill-server 2>/dev/null || true
  rm -rf "$TX_STORE_DIR"
  rm -f "$TMUX_TEST_CONF"
}

# Build a known session geometry for tests.
# IMPORTANT: use `new-window -t <session>:` (trailing colon) — NOT `-t <session>`.
# With renumber-windows on + base-index 1, `-t <session>` tries to create at
# base-index (already in use) and FAILS. `-t <session>:` appends correctly.
build_session() {
  local name="$1"
  tmux -f "$TMUX_TEST_CONF" new-session -d -s "$name" -x 200 -y 50 -n editor
  tmux split-window -h -t "$name:1" -c /tmp
  tmux split-window -v -t "$name:1.2" -c "$HOME"
  tmux new-window -t "$name:" -n logs -c /var/log
  tmux split-window -v -t "$name:2" -c /tmp
}

panes_descriptor() {
  tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_current_path} #{pane_active} #{pane_width}x#{pane_height}'
}

# ============================================================
# === Tests                                                ===
# ============================================================

test_doctor_passes() {
  setup_tmux
  local out; out="$("$BIN" doctor 2>&1)" || true
  assert_contains "doctor reports tmux" "tmux" "$out"
  assert_contains "doctor reports jq" "jq" "$out"
  teardown_tmux
}

test_save_creates_valid_snapshot() {
  setup_tmux
  build_session dev
  local out; out="$("$BIN" save snap1 -s dev -g g1 -t t1,t2 -d "desc" -y 2>&1)"
  assert_contains "save success message" "saved 'snap1'" "$out"
  assert_match "stats line 1s/2w/5p" '1s/2w/5p' "$out"
  local snapfile; snapfile="$TX_STORE_DIR/snapshots/$(ls "$TX_STORE_DIR/snapshots/")"
  assert_json "snapshot file is valid JSON" "$(cat "$snapfile")"
  local schema; schema="$(jq -r '.schema' "$snapfile")"
  assert_eq "schema version" "tx.snapshot.v1" "$schema"
  local name; name="$(jq -r '.meta.name' "$snapfile")"
  assert_eq "meta.name" "snap1" "$name"
  local sc; sc="$(jq -r '.stats.sessions' "$snapfile")"
  assert_eq "stats.sessions" "1" "$sc"
  local wc; wc="$(jq -r '.stats.windows' "$snapfile")"
  assert_eq "stats.windows" "2" "$wc"
  local pc; pc="$(jq -r '.stats.panes' "$snapfile")"
  assert_eq "stats.panes" "5" "$pc"
  local bi; bi="$(jq -r '.sessions[0].base_index' "$snapfile")"
  assert_eq "base_index captured" "1" "$bi"
  teardown_tmux
}

test_roundtrip_preserves_structure() {
  setup_tmux
  build_session dev
  "$BIN" save rt -s dev -y >/dev/null 2>&1
  local before; before="$(panes_descriptor)"
  tmux kill-session -t dev
  "$BIN" load rt --replace >/dev/null 2>&1
  local after; after="$(panes_descriptor)"
  assert_eq "pane structure identical after round-trip" "$before" "$after"
  teardown_tmux
}

test_roundtrip_multi_session_all() {
  setup_tmux
  build_session dev
  tmux -f "$TMUX_TEST_CONF" new-session -d -s aux -x 120 -y 40 -n w
  tmux split-window -v -t aux:1 -c /etc
  "$BIN" save multi -a -y >/dev/null 2>&1
  local before; before="$(panes_descriptor | sort)"
  tmux kill-server 2>/dev/null
  "$BIN" load multi --replace >/dev/null 2>&1
  local after; after="$(panes_descriptor | sort)"
  assert_eq "all-sessions round-trip preserves both sessions" "$before" "$after"
  teardown_tmux
}

test_list_and_filters() {
  setup_tmux
  build_session dev
  "$BIN" save a -s dev -g work -t frontend -y >/dev/null 2>&1
  "$BIN" save b -s dev -g personal -t backend -y >/dev/null 2>&1
  "$BIN" save c -s dev -g work -t frontend,api -y >/dev/null 2>&1
  local n; n="$("$BIN" ls 2>/dev/null | grep -cE '^[0-9a-f]{8}' || true)"
  assert_eq "ls shows 3 snapshots" "3" "$n"
  local ng; ng="$("$BIN" ls -g work 2>/dev/null | grep -cE '^[0-9a-f]{8}' || true)"
  assert_eq "ls -g work shows 2" "2" "$ng"
  local nt; nt="$("$BIN" ls -t frontend 2>/dev/null | grep -cE '^[0-9a-f]{8}' || true)"
  assert_eq "ls -t frontend shows 2" "2" "$nt"
  local json; json="$("$BIN" ls --json 2>/dev/null)"
  assert_json "ls --json valid" "$json"
  local jn; jn="$(echo "$json" | jq 'length')"
  assert_eq "ls --json length 3" "3" "$jn"
  teardown_tmux
}

test_remove() {
  setup_tmux
  build_session dev
  "$BIN" save x -s dev -y >/dev/null 2>&1
  "$BIN" save y -s dev -y >/dev/null 2>&1
  "$BIN" rm x -f >/dev/null 2>&1
  local n; n="$("$BIN" ls 2>/dev/null | grep -cE '^[0-9a-f]{8}' || true)"
  assert_eq "one snapshot after rm" "1" "$n"
  local id; id="$("$BIN" ls 2>/dev/null | grep -E '^[0-9a-f]{8}' | awk '{print $1}')"
  assert_eq "remaining is y" "y" "$(jq -r '.meta.name' "$TX_STORE_DIR/snapshots/$id.json")"
  teardown_tmux
}

test_rename_and_tag() {
  setup_tmux
  build_session dev
  "$BIN" save orig -s dev -t keep -y >/dev/null 2>&1
  "$BIN" rename orig renamed >/dev/null 2>&1
  local id; id="$("$BIN" ls 2>/dev/null | grep -E '^[0-9a-f]{8}' | awk '{print $1}')"
  assert_eq "renamed" "renamed" "$(jq -r '.meta.name' "$TX_STORE_DIR/snapshots/$id.json")"
  "$BIN" tag renamed +new,hot -keep >/dev/null 2>&1
  local tags; tags="$(jq -r '.meta.tags|join(",")' "$TX_STORE_DIR/snapshots/$id.json")"
  assert_eq "tags after add/remove" "hot,new" "$tags"
  teardown_tmux
}

test_group_lifecycle() {
  setup_tmux
  build_session dev
  "$BIN" group add projA >/dev/null 2>&1
  "$BIN" group add projB "second project" >/dev/null 2>&1
  "$BIN" save s1 -s dev -g projA -y >/dev/null 2>&1
  local gc; gc="$("$BIN" group ls 2>/dev/null | grep -cE '^(proj|default|auto)' || true)"
  assert_eq "2 custom groups listed" "2" "$gc"
  "$BIN" group rm projB -f >/dev/null 2>&1
  local exists; exists="$("$BIN" group ls --json 2>/dev/null | jq -r '[.[]|select(.name=="projB")]|length')"
  assert_eq "projB removed" "0" "$exists"
  "$BIN" group mv projA projC >/dev/null 2>&1
  local moved; moved="$("$BIN" group ls --json 2>/dev/null | jq -r '[.[]|select(.name=="projC")]|length')"
  assert_eq "projA renamed to projC" "1" "$moved"
  local member_g; member_g="$(jq -r '.meta.group' "$TX_STORE_DIR"/snapshots/*.json)"
  assert_eq "member reassigned to projC" "projC" "$member_g"
  teardown_tmux
}

test_diff() {
  setup_tmux
  build_session dev
  "$BIN" save v1 -s dev -y >/dev/null 2>&1
  # modify: add a pane
  tmux split-window -h -t dev:1 -c /opt
  "$BIN" save v2 -s dev -y >/dev/null 2>&1
  local out; out="$("$BIN" diff v1 v2 2>&1)"
  assert_contains "diff shows pane count delta" "A → 5 panes" "$out"
  assert_contains "diff shows B has more" "B → 6 panes" "$out"
  teardown_tmux
}

test_index_self_heal() {
  setup_tmux
  build_session dev
  "$BIN" save h -s dev -y >/dev/null 2>&1
  # corrupt the index
  printf '' > "$TX_STORE_DIR/index.json"
  "$BIN" index check 2>&1 | grep -q "index:" && assert_eq "index rebuilt after corruption" "1" "1" || assert_eq "index check ran" "1" "0"
  local n; n="$(jq '.snapshots|length' "$TX_STORE_DIR/index.json")"
  assert_eq "index has 1 entry after heal" "1" "$n"
  teardown_tmux
}

test_show_renders_tree() {
  setup_tmux
  build_session dev
  "$BIN" save sh -s dev -y >/dev/null 2>&1
  local out; out="$("$BIN" show sh 2>&1)"
  assert_contains "show has Snapshot header" "Snapshot" "$out"
  assert_contains "show has Tree header" "Tree" "$out"
  assert_contains "show lists editor window" "editor" "$out"
  assert_contains "show lists logs window" "logs" "$out"
  teardown_tmux
}

test_name_uniqueness_and_overwrite() {
  setup_tmux
  build_session dev
  "$BIN" save uniq -s dev -y >/dev/null 2>&1
  # second save with same name without -f should fail
  if "$BIN" save uniq -s dev -y >/dev/null 2>&1; then
    assert_eq "duplicate name rejected" "rejected" "accepted"
  else
    assert_eq "duplicate name rejected" "rejected" "rejected"
  fi
  # with -f should overwrite
  "$BIN" save uniq -s dev -y -f >/dev/null 2>&1
  local n; n="$("$BIN" ls 2>/dev/null | grep -cE '^[0-9a-f]{8}' || true)"
  assert_eq "overwrite keeps single entry" "1" "$n"
  teardown_tmux
}

test_load_nonexistent() {
  setup_tmux
  build_session dev
  if "$BIN" load does-not-exist --replace >/dev/null 2>&1; then
    assert_eq "missing snapshot errors" "error" "ok"
  else
    assert_eq "missing snapshot errors" "error" "error"
  fi
  teardown_tmux
}

test_restore_commands_flag() {
  setup_tmux
  build_session dev
  # run a command in a pane, capture, restore with --commands
  tmux send-keys -t dev:1.1 "echo MARKER" C-m
  sleep 0.3
  "$BIN" save cmd -s dev -y >/dev/null 2>&1
  tmux kill-session -t dev
  "$BIN" load cmd --replace --commands >/dev/null 2>&1
  # session should exist with 2 windows (count window-index lines)
  local w; w="$(tmux list-windows -t dev -F '#{window_index}' 2>/dev/null | grep -c . || true)"
  assert_eq "restored with commands has 2 windows" "2" "$w"
  teardown_tmux
}

# --- New tests for v1.1.0 ergonomic & discoverability features ---

test_tx_start_named_outside_tmux() {
  # tx start NAME (outside tmux) should bootstrap a server + restore exactly.
  setup_tmux
  build_session dev
  "$BIN" save start-test -s dev -y >/dev/null 2>&1
  local before; before="$(panes_descriptor)"
  tmux kill-server 2>/dev/null
  # Now outside tmux (TMUX env unset by killing server).
  "$BIN" start start-test --replace --no-attach >/dev/null 2>&1
  local after; after="$(panes_descriptor)"
  assert_eq "tx start (outside tmux) reproduces structure" "$before" "$after"
  teardown_tmux
}

test_tx_last_restores_newest() {
  # tx last should restore the MOST-RECENT snapshot (newest-first ordering).
  setup_tmux
  build_session dev
  "$BIN" save older -s dev -y >/dev/null 2>&1
  sleep 1
  # build a different session, snapshot it later
  tmux new-session -d -s newer -x 100 -y 30 -n w
  tmux split-window -v -t newer:1 -c /etc
  "$BIN" save newer-snap -s newer -y >/dev/null 2>&1
  tmux kill-server 2>/dev/null
  "$BIN" last >/dev/null 2>&1
  # the restored session should be "newer" (the most-recent snapshot)
  local sessions; sessions="$(tmux list-sessions -F '#{session_name}' 2>/dev/null | sort | tr '\n' ',')"
  assert_contains "tx last restored newest (newer session exists)" "newer" "$sessions"
  teardown_tmux
}

test_tx_last_list_mode() {
  setup_tmux
  build_session dev
  "$BIN" save a -s dev -y >/dev/null 2>&1
  sleep 0.5
  "$BIN" save b -s dev -y >/dev/null 2>&1
  local out; out="$("$BIN" last -n 5 2>/dev/null)"
  # newest (b) should appear before older (a)
  local b_line a_line
  b_line="$(echo "$out" | grep -nE '^[0-9a-f]{8}.* b ' | head -1 | cut -d: -f1)"
  a_line="$(echo "$out" | grep -nE '^[0-9a-f]{8}.* a ' | head -1 | cut -d: -f1)"
  [[ -n "$b_line" && -n "$a_line" ]] && \
    assert_eq "newest (b) listed before older (a)" "1" "$(( b_line < a_line ))"
  teardown_tmux
}

test_store_list_newest_first() {
  # store_list must return newest-first regardless of insertion order.
  setup_tmux
  build_session dev
  "$BIN" save first -s dev -y >/dev/null 2>&1
  sleep 1
  "$BIN" save second -s dev -y >/dev/null 2>&1
  local order; order="$("$BIN" ls --json 2>/dev/null | jq -r '.[].name' | tr '\n' ',')"
  assert_eq "newest-first ordering" "second,first," "$order"
  teardown_tmux
}

test_tx_default_outside_tmux_gives_hint() {
  # `tx` with no args, outside tmux, should not crash — should hint at `tx start`.
  setup_tmux
  # Ensure the test process looks "outside tmux" (no inherited TMUX env).
  unset TMUX
  # No session built — outside tmux, no args. Capture combined stdout+stderr.
  local out
  out="$("$BIN" --color never 2>&1)" || true
  assert_contains "default outside-tmux mentions tx start" "tx start" "$out"
  teardown_tmux
}

test_ls_table_renders_empty_tags() {
  # Regression: a snapshot with NO tags must render cleanly (TAGS col empty,
  # CREATED col correct) — previously tab-collapse misaligned columns.
  setup_tmux
  build_session dev
  "$BIN" save notags -s dev -y >/dev/null 2>&1
  # Disable color so grep patterns match cleanly; find the notags row.
  local line; line="$("$BIN" --color never ls 2>/dev/null | grep 'notags' || true)"
  # The CREATED column should contain a date-like string "2026-... NN:NN:SS"
  assert_match "notags row has a proper created timestamp" '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' "$line"
  teardown_tmux
}

test_base_index_standardization() {
  # The standardized base-index resolver should return a validated integer
  # for a session with global base-index set, and 0 when nothing is set.
  setup_tmux
  build_session dev
  local bi pbi
  bi="$(bash -c "source '$PROJECT_DIR/lib/core.sh'; core_tmux_base_index dev")"
  pbi="$(bash -c "source '$PROJECT_DIR/lib/core.sh'; core_tmux_pane_base_index dev")"
  assert_match "base_index is an integer" '^[0-9]+$' "$bi"
  assert_match "pane_base_index is an integer" '^[0-9]+$' "$pbi"
  teardown_tmux
}

test_tx_resolvable_from_arbitrary_cwd() {
  # tx must be callable from any CWD (not just tmux-config/bin/) — the
  # discoverability fix. Invoke from /tmp and check it runs.
  setup_tmux
  build_session dev
  local out
  out="$(cd /tmp && "$BIN" --version 2>&1)" || true
  assert_contains "tx runs from arbitrary CWD" "tx" "$out"
  # `tx info` should print its header (non-empty) from /tmp.
  local info_out
  info_out="$(cd /tmp && "$BIN" --color never info 2>&1)" || true
  assert_contains "tx info runs from /tmp" "tx info" "$info_out"
  teardown_tmux
}

test_restore_renumber_windows_on() {
  # Regression for v1.2.0: with renumber-windows on + base-index 1, the OLD
  # restore used `new-window -t <session>` (no colon), which FAILED with
  # "create window failed: index 1 in use". The fix uses `-t <session>:`.
  # This test builds a 3-window session and asserts all 3 windows survive the
  # round-trip (previously only window 1 survived).
  setup_tmux
  tmux -f "$TMUX_TEST_CONF" new-session -d -s multi -x 200 -y 50 -n proxy
  tmux split-window -h -t multi:1 -c /tmp
  tmux new-window -t multi: -n A -c /var
  tmux split-window -v -t multi:2 -c /etc
  tmux new-window -t multi: -n editor -c "$HOME"
  local before; before="$(panes_descriptor)"
  local wb4; wb4="$(tmux list-windows -t multi -F '#{window_name}' | tr '\n' ',')"
  assert_eq "3 windows before save" "proxy,A,editor," "$wb4"

  "$BIN" save multi-snap -s multi -y >/dev/null 2>&1
  tmux kill-session -t multi
  "$BIN" load multi-snap --replace >/dev/null 2>&1
  local after; after="$(panes_descriptor)"
  local waft; waft="$(tmux list-windows -t multi -F '#{window_name}' | tr '\n' ',')"
  assert_eq "3 windows after restore" "proxy,A,editor," "$waft"
  assert_eq "round-trip identical (renumber on)" "$before" "$after"
  teardown_tmux
}

test_restore_session_name_equals_window_name() {
  # Edge case: a session named "proxy" with a window also named "proxy".
  # The restore must not confuse session and window targets.
  setup_tmux
  tmux -f "$TMUX_TEST_CONF" new-session -d -s proxy -x 200 -y 50 -n proxy
  tmux split-window -h -t proxy:1 -c /tmp
  tmux new-window -t proxy: -n logs -c /var
  local before; before="$(panes_descriptor)"
  "$BIN" save name-collision -s proxy -y >/dev/null 2>&1
  tmux kill-session -t proxy
  "$BIN" load name-collision --replace >/dev/null 2>&1
  local after; after="$(panes_descriptor)"
  assert_eq "session==window name round-trip" "$before" "$after"
  teardown_tmux
}

test_tx_start_outside_tmux_multi_window() {
  # The EXACT user-reported bug: `tx start` outside tmux with a multi-window
  # snapshot previously failed with "cannot create window ... in N".
  setup_tmux
  build_session dev
  "$BIN" save start-multi -s dev -y >/dev/null 2>&1
  local before; before="$(panes_descriptor)"
  tmux kill-server 2>/dev/null
  "$BIN" start start-multi --replace --no-attach >/dev/null 2>&1
  local after; after="$(panes_descriptor)"
  assert_eq "tx start multi-window round-trip" "$before" "$after"
  teardown_tmux
}

test_install_detects_managed_symlink() {
  # install.sh must detect when ~/.config/tmux is a symlink (managed by
  # home-manager / stow / similar) and NOT clobber it — print a PATH hint instead.
  local fake_home; fake_home="$(mktemp -d)"
  mkdir -p "$fake_home/.config"
  ln -s /tmp/nonexistent-store-target "$fake_home/.config/tmux"
  local out
  out="$(HOME="$fake_home" "$PROJECT_DIR/install.sh" 2>&1)" || true
  assert_contains "install detects managed symlink" "declaratively-managed" "$out"
  # The hint should mention PATH (the thing the user still needs to wire).
  assert_contains "install prints PATH hint" "PATH" "$out"
  # It must NOT clobber the symlink.
  assert_contains "install does not clobber" "will NOT modify" "$out"
  rm -rf "$fake_home"
}

test_fzf_flags_centralized() {
  # v1.3.0: ui_fzf_common_flags must return the shared fzf-tab-aligned style.
  # Verify it's sourced and callable, and produces the expected defaults.
  setup_tmux
  build_session dev
  # Source ui.sh and call the helper.
  local flags
  flags="$(bash -c "source '$PROJECT_DIR/lib/core.sh'; source '$PROJECT_DIR/lib/ui.sh'; ui_fzf_common_flags" 2>/dev/null)"
  assert_contains "fzf flags include prompt ❯" "--prompt=❯" "$flags"
  assert_contains "fzf flags include border none" "--border=none" "$flags"
  assert_contains "fzf flags include cycle" "--cycle" "$flags"
  assert_contains "fzf flags include no-bold" "--no-bold" "$flags"
  # Override via TX_FZF_OPTS
  flags="$(TX_FZF_OPTS="--custom" bash -c "source '$PROJECT_DIR/lib/core.sh'; source '$PROJECT_DIR/lib/ui.sh'; ui_fzf_common_flags" 2>/dev/null)"
  assert_eq "TX_FZF_OPTS override respected" "--custom" "$flags"
  teardown_tmux
}


# ============================================================
# === Runner                                               ===
# ============================================================

main() {
  printf '\n%s\n' "$(_dim '──────── tmux-config / tx — test suite ────────')"
  printf '  project: %s\n' "$PROJECT_DIR"
  printf '  store:   %s\n\n' "$TX_STORE_DIR"

  local tests=(
    test_doctor_passes
    test_save_creates_valid_snapshot
    test_roundtrip_preserves_structure
    test_roundtrip_multi_session_all
    test_list_and_filters
    test_remove
    test_rename_and_tag
    test_group_lifecycle
    test_diff
    test_index_self_heal
    test_show_renders_tree
    test_name_uniqueness_and_overwrite
    test_load_nonexistent
    test_restore_commands_flag
    test_tx_start_named_outside_tmux
    test_tx_last_restores_newest
    test_tx_last_list_mode
    test_store_list_newest_first
    test_tx_default_outside_tmux_gives_hint
    test_ls_table_renders_empty_tags
    test_base_index_standardization
    test_tx_resolvable_from_arbitrary_cwd
    test_restore_renumber_windows_on
    test_restore_session_name_equals_window_name
    test_tx_start_outside_tmux_multi_window
    test_install_detects_managed_symlink
    test_fzf_flags_centralized
  )

  for t in "${tests[@]}"; do
    printf '%s %s\n' "$(_yellow '▶')" "$t"
    "$t"
  done

  printf '\n%s\n' "$(_dim '──────── summary ────────')"
  printf '  %s passed   %s failed   %s total\n' "$(_green "$PASS")" \
    "$([ "$FAIL" -gt 0 ] && _red "$FAIL" || echo "$FAIL")" "$((PASS + FAIL))"
  if (( FAIL > 0 )); then exit 1; fi
  printf '  %s all tests passed\n\n' "$(_green ✓)"
}

trap 'final_cleanup' EXIT
main "$@"
