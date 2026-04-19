#!/bin/bash
# @path: ~/.config/tmux/scripts/tmux-clipboard.sh
# @anthor: redskaber
# @datetime: 2026-01-27
# @description: capability-based clipboard resolver

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLICY_DIR="$BASE_DIR/policy/copy"

# =========================
# === Capability Checks ===
# =========================

check_osc52() {
  [[ -n "${SSH_CONNECTION:-}" ]]
}

check_wl_copy() {
  command -v wl-copy >/dev/null 2>&1
}

check_xclip() {
  command -v xclip >/dev/null 2>&1
}

check_pbcopy() {
  command -v pbcopy >/dev/null 2>&1
}

check_fallback() {
  return 0
}

# =========================
# === Capability Execs  ===
# =========================

exec_osc52() {
  exec "$POLICY_DIR/osc52.sh"
}

exec_wl_copy() {
  exec "$POLICY_DIR/wl-copy.sh"
}

exec_xclip() {
  exec "$POLICY_DIR/xclip.sh"
}

exec_pbcopy() {
  exec "$POLICY_DIR/pbcopy.sh"
}

exec_fallback() {
  echo "tmux: no clipboard backend found" >&2
  tmux display-message -d 3000 "❌ No clipboard backend"
  exit 1
}

# =========================
# === Registry (Queue)  ===
# =========================

CAP_CHECKS=()
CAP_EXECS=()

register_capability() {
  CAP_CHECKS+=("$1")
  CAP_EXECS+=("$2")
}

# =========================
# === Policy Definition ===
# =========================
# 顺序 = 优先级（你可以拆成多个 policy 文件）

register_capability check_osc52 exec_osc52
register_capability check_wl_copy exec_wl_copy
register_capability check_xclip exec_xclip
register_capability check_pbcopy exec_pbcopy
register_capability check_fallback exec_fallback

# =========================
# === Executor          ===
# =========================

run_capabilities() {
  for i in "${!CAP_CHECKS[@]}"; do
    if "${CAP_CHECKS[$i]}"; then
      "${CAP_EXECS[$i]}"
      exit 0
    fi
  done
}

run_capabilities
