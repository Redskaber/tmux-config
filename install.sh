#!/usr/bin/env bash
# @file: install.sh
# @author: redskaber
# @desc: Install tmux-config to ~/.config/tmux and wire `tx` onto PATH.
#        Detects whether the target is declaratively managed (a symlink, e.g.
#        by home-manager / stow) — if so, does NOT clobber it; prints a hint
#        instead. Otherwise does a manual copy + symlink.
# @usage: ./install.sh [--target DIR] [--store DIR] [--force]
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${TMUX_CONFIG_DIR:-$HOME/.config/tmux}"
STORE_DIR=""
FORCE=0

while (( $# > 0 )); do
  case "$1" in
    --store) STORE_DIR="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help)
      cat <<'EOF'
usage: ./install.sh [--target DIR] [--store DIR] [--force]

If ~/.config/tmux is a symlink (declaratively managed by home-manager / stow /
similar), prints a hint and does NOT modify it. Otherwise copies the config,
symlinks tx to ~/.local/bin, and wires PATH into your shell's rc file.
EOF
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ============================================================
# === General detection: is a path declaratively managed?  ===
# ============================================================
# If a config path is a symlink, it's managed by a declarative system
# (home-manager, stow, NixOS, Guix, etc.). We MUST NOT clobber it.
is_managed() {
  local p="$1"
  [[ -L "$p" ]]
}

# ============================================================
# === Context A: declaratively managed — print hint         ===
# ============================================================
managed_print_hint() {
  local target_dir="$1"
  cat <<EOF
${CYAN}► detected declaratively-managed config${RESET}

  $target_dir is a symlink — managed by home-manager / stow / similar.
  install.sh will NOT modify it (doing so would break the managing system).

  The config files are already deployed by your declarative system.
  The ONLY missing piece is getting ${BOLD}tx${RESET}${CYAN} onto PATH.

  Add this to your shell config or home-manager sessionVariables:

${YELLOW}    export PATH="\$HOME/.config/tmux/bin:\$PATH"${RESET}

  Then: ${BOLD}exec \$SHELL${RESET}${CYAN} && ${BOLD}tx doctor${RESET}

${DIM}  (re-run with --force to override and do a manual install anyway)${RESET}
EOF
}

# ============================================================
# === Context B: manual install                            ===
# ============================================================
manual_install() {
  local target="$1"
  echo "${CYAN}► installing tmux-config → $target${RESET}"
  mkdir -p "$(dirname "$target")"

  # Back up existing config (only if it's a real dir, not a symlink).
  if [[ -d "$target" && ! -L "$target" ]]; then
    echo "  backing up existing config → $target.bak.$(date +%s)"
    mv "$target" "$target.bak.$(date +%s)"
  fi

  cp -r "$PROJECT_DIR" "$target"
  rm -rf "$TARGET/tests" "$TARGET/install.sh" "$TARGET/.git" 2>/dev/null || true
  chmod +x "$TARGET/bin/tx" "$TARGET/scripts/"*.sh "$TARGET/policy/copy/"*.sh 2>/dev/null || true

  # Symlink tx onto ~/.local/bin.
  local link_dir="$HOME/.local/bin"
  mkdir -p "$link_dir"
  [[ -e "$link_dir/tx" || -L "$link_dir/tx" ]] && rm -f "$link_dir/tx"
  ln -s "$TARGET/bin/tx" "$link_dir/tx"
  echo "  ${GREEN}linked tx → $link_dir/tx${RESET}"

  # Shell-aware PATH wiring.
  local login_shell; login_shell="$(basename "${SHELL:-bash}")"
  _ensure_path() {
    local file="$1" marker='# tmux-config: tx on PATH'
    [[ -f "$file" ]] || return 0
    if ! grep -qF "$marker" "$file" 2>/dev/null; then
      { echo ""; echo "$marker"; echo 'export PATH="$HOME/.local/bin:$PATH"'; } >> "$file"
      echo "  ${GREEN}added ~/.local/bin to PATH in $(basename "$file")${RESET}"
    fi
  }
  _ensure_path_fish() {
    local file="$1" marker='# tmux-config: tx on PATH'
    [[ -f "$file" ]] || return 0
    if ! grep -qF "$marker" "$file" 2>/dev/null; then
      { echo ""; echo "$marker"; echo 'set -gx PATH $HOME/.local/bin $PATH'; } >> "$file"
      echo "  ${GREEN}added ~/.local/bin to PATH in $(basename "$file")${RESET}"
    fi
  }
  case "$login_shell" in
    zsh)  _ensure_path "$HOME/.zshrc"; touch "$HOME/.zshenv"; _ensure_path "$HOME/.zshenv" ;;
    fish) _ensure_path_fish "$HOME/.config/fish/config.fish" ;;
    *)    _ensure_path "$HOME/.bashrc"; [[ -f "$HOME/.profile" ]] && _ensure_path "$HOME/.profile" ;;
  esac

  # Optional custom store dir.
  if [[ -n "$STORE_DIR" ]]; then
    echo "  TX_STORE_DIR=$STORE_DIR"
    for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.zshenv"; do
      [[ -f "$rc" ]] || continue
      if ! grep -qF 'export TX_STORE_DIR=' "$rc" 2>/dev/null; then
        echo "export TX_STORE_DIR=\"$STORE_DIR\"" >> "$rc"
      fi
    done
  fi

  # Verify.
  echo
  echo "${CYAN}► verifying discoverability…${RESET}"
  export PATH="$link_dir:$PATH"
  command -v tx >/dev/null 2>&1 \
    && echo "  ${GREEN}✓ tx on PATH: $(command -v tx)${RESET}" \
    || echo "  ${RED}✗ tx NOT on PATH — run: exec \$SHELL${RESET}"
  "$TARGET/bin/tx" --version >/dev/null 2>&1 \
    && echo "  ${GREEN}✓ tx runs: $("$TARGET/bin/tx" --version)${RESET}" \
    || { echo "  ${RED}✗ tx binary not executable${RESET}"; exit 1; }

  echo
  echo "${GREEN}✓ installed.${RESET}"
  echo "  config:      $TARGET/tmux.conf"
  echo "  tx bin:      $TARGET/bin/tx  (→ $link_dir/tx)"
  echo "  store:       \${TX_STORE_DIR:-$HOME/.local/share/tx}"
  echo "  login shell: $login_shell"
  echo
  echo "next steps:"
  echo "  1. exec \$SHELL"
  echo "  2. tx doctor"
  echo "  3. tx start   # start tmux + pick a snapshot"
}

# ============================================================
# === Main: detect context and route                       ===
# ============================================================

# Colors (disabled if not a TTY).
if [[ -t 1 ]]; then
  RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; CYAN='\033[36m'; BOLD='\033[1m'; RESET='\033[0m'; DIM='\033[2m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''; DIM=''
fi

# Detect: is the target a symlink (declaratively managed)? If so, don't clobber.
if is_managed "$TARGET"; then
  if (( FORCE )); then
    echo "${YELLOW}⚠ --force: target is a managed symlink — proceeding anyway (may break the managing system)${RESET}"
    manual_install "$TARGET"
  else
    managed_print_hint "$TARGET"
  fi
else
  manual_install "$TARGET"
fi
