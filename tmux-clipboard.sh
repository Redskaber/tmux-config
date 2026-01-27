#!/bin/sh
# @path: ~/.config/tmux/tmux-clipboard.sh
# @anthor: redskaber
# @datetime: 2026-01-27
# @description: handle tmux copy

if command -v wl-copy >/dev/null 2>&1; then
  wl-copy
elif command -v xclip >/dev/null 2>&1; then
  xclip -selection clipboard -i
elif command -v xsel >/dev/null 2>&1; then
  xsel --clipboard --input
elif command -v pbcopy >/dev/null 2>&1; then
  pbcopy
else
  # 输出错误到 stderr，tmux 会捕获并在状态栏显示
  echo "tmux: install wl-clipboard (Wayland), xclip/xsel (X11), or pbcopy (macOS)" >&2
  # Optional: 通知
  tmux display-message -d 3000 "❌ No clipboard tool! Install xclip/wl-clipboard etc."
  exit 1
fi
