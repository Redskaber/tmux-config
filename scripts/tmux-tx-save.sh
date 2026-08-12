#!/usr/bin/env bash
# @file: scripts/tmux-tx-save.sh
# @author: redskaber
# @desc: Guided-form popup helper for `tx save` (alternative to the bare
#        `tx save` interactive prompt). Prompts for metadata fields, then
#        calls `tx save`. Robustly resolves the tx binary.
# @invoked-by: (optional) bind S display-popup ... "tmux-tx-save.sh"
# @deps: tx (resolved via core_resolve_tx_bin strategy)

set -euo pipefail

# --- Resolve tx binary (same strategy as core.sh) ---
TX_BIN=""
for c in "${TX_BIN:-}" "$(command -v tx 2>/dev/null || true)" \
         "$HOME/.config/tmux/bin/tx" "$HOME/.local/bin/tx"; do
  [[ -n "$c" && -x "$c" ]] && { TX_BIN="$c"; break; }
done
[[ -n "$TX_BIN" ]] || {
  printf 'tx not found on PATH, ~/.local/bin, or ~/.config/tmux/bin\n'
  sleep 2; exit 1
}

# Detect current session (popup inherits $TMUX).
SESSION="$(tmux display-message -p '#S' 2>/dev/null || true)"

printf '\033[1;36m╭─ tx save ─────────────────────────────╮\033[0m\n'
printf '\033[1;36m│\033[0m  session: \033[1m%s\033[0m\n' "${SESSION:-(unknown)}"
printf '\033[1;36m╰───────────────────────────────────────╯\033[0m\n\n'

read -rp "snapshot name [auto]: " NAME
read -rp "group   [default]: " GROUP
read -rp "tags    (comma-sep): " TAGS
read -rp "description: " DESC

ARGS=()
[[ -n "$NAME" ]]  && ARGS+=("$NAME")
[[ -n "$GROUP" ]] && ARGS+=(-g "$GROUP")
[[ -n "$TAGS" ]]  && ARGS+=(-t "$TAGS")
[[ -n "$DESC" ]]  && ARGS+=(-d "$DESC")
# Scope to the current session explicitly (popup "current" is reliable).
[[ -n "$SESSION" ]] && ARGS+=(-s "$SESSION")
ARGS+=(-y)

printf '\n'
"$TX_BIN" save "${ARGS[@]}" || { printf '\n\033[1;31msave failed\033[0m\n'; sleep 2; exit 1; }

printf '\n'
read -rp "Press Enter to close..." _
