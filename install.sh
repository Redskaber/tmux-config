#!/usr/bin/env bash
# @file: install.sh
# @author: redskaber
# @desc: Install tmux-config. GENERAL design: detects the deployment context
#        and adapts — does NOT special-case NixOS, but detects the GENERAL
#        signal (files are read-only symlinks to a system store) and routes
#        to the appropriate strategy.
#
#        Two contexts:
#          A) home-manager / NixOS — ~/.config/tmux is a store symlink (read-only).
#             install.sh MUST NOT clobber it. Instead, print the Nix snippet
#             that wires `tx` onto PATH via home.sessionPath.
#          B) manual install — ~/.config/tmux is a real dir or absent.
#             install.sh copies files, symlinks tx onto ~/.local/bin, and wires
#             PATH into the detected shell's rc file.
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

On NixOS / home-manager (detected automatically):
  prints the Nix snippet to wire `tx` onto PATH — does NOT touch managed files.

On other systems (manual install):
  copies tmux-config to ~/.config/tmux, symlinks tx to ~/.local/bin,
  and adds ~/.local/bin to your shell's rc file.
EOF
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ============================================================
# === General detection: is a path declaratively managed?  ===
# ============================================================
# GENERAL signal: if a config path is a symlink, it's managed by a declarative
# system (home-manager, stow, NixOS, Guix, etc.). We MUST NOT clobber it —
# doing so would break the managing system on its next apply. Instead, print
# the idiomatic wiring snippet.
#
# This is deliberately general: "symlink → managed" covers home-manager's
# /nix/store symlinks, stow's symlink farms, and any similar layout. No
# hardcode of /nix/store paths.
is_managed() {
  local p="$1"
  [[ -L "$p" ]]
}

# ============================================================
# === Context A: declaratively managed (home-manager, etc.) ===
# ============================================================
managed_print_snippet() {
  local target_dir="$1"
  cat <<EOF
${CYAN}► detected declaratively-managed config${RESET}

  $target_dir is a symlink — managed by home-manager / stow / similar.
  install.sh will NOT modify it (doing so would break the managing system).

  The ONLY missing piece is getting ${BOLD}tx${RESET}${CYAN} onto PATH.

${YELLOW}  ┌─ Option 1 (recommended): use the home-manager module from this repo ──
  │
  │  # In your home config (e.g. tmux.nix):
  │  { inputs, ... }: {
  │    imports = [ inputs.tmux-config.homeModules.tx-home ];
  │    programs.tx.enable = true;   # adds ~/.config/tmux/bin to PATH (all shells)
  │
  │    xdg.configFile."tmux" = {    # (already done) deploy the config files
  │      source = inputs.tmux-config; recursive = true; force = true;
  │    };
  │  }
  │
  │  Then: home-manager switch && exec \$SHELL && tx doctor
  │
  ├─ Option 2 (minimal): add ONE line to your existing home config ──
  │
  │  home.sessionPath = [ "\${config.xdg.configHome}/tmux/bin" ];
  │
  └────────────────────────────────────────────────────────────────${RESET}

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
  rm -rf "$TARGET/tests" "$TARGET/install.sh" "$TARGET/.git" "$TARGET/flake.nix" "$TARGET/nix" 2>/dev/null || true
  mkdir -p "$TARGET/store/snapshots"
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
    managed_print_snippet "$TARGET"
  fi
else
  manual_install "$TARGET"
fi
