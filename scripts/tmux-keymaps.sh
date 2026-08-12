#!/usr/bin/env bash
# @path: ~/.config/tmux/scripts/tmux-keymaps.sh
# @author: redskaber
# @description: keymap cheat-sheet (fzf palette)

cat <<'EOF' |
class               | keys              | description
--------------------|-------------------|------------------------------------------
Pane Navigation     | Ctrl-a  h/j/k/l   | move left/down/up/right
Pane Navigation     | Alt     h/j/k/l   | move (no prefix)
Pane Navigation     | Alt     Up        | enter copy-mode
Window Navigation   | Alt     Left      | previous window
Window Navigation   | Alt     Right     | next window
Window Navigation   | Alt     Tab       | last window
Pane Control        | Ctrl-a  |         | split horizontal
Pane Control        | Ctrl-a  _         | split vertical
Pane Control        | Ctrl-a  x         | kill pane
Pane Control        | Ctrl-a  X         | kill window
Resize              | Ctrl-a  H/J/K/L   | resize pane (repeatable)
Layout Templates    | Ctrl-a  L         | apply static layout (fzf)
tx · save           | Ctrl-a  S         | snapshot current session (popup)
tx · load           | Ctrl-a  O         | pick & restore a snapshot (popup)
tx · list           | Ctrl-a  M-s       | list snapshots (popup)
tx · quick-save     | Ctrl-a  Ctrl-o    | auto-name save (background)
tx · resume         | Ctrl-a  Ctrl-t    | restore most-recent snapshot (one-key)
tx · start          | (shell) tx start  | start tmux + pick a snapshot (outside tmux)
Zoom                | Ctrl-a  +         | toggle pane zoom
System              | Ctrl-a  Ctrl-r    | reload config
System              | Ctrl-a  d         | detach session
System              | Ctrl-a  Ctrl-s    | toggle status bar
Copy Mode (Alt-Up)  | v                 | begin selection
Copy Mode (Alt-Up)  | y                 | copy to clipboard
Copy Mode (Alt-Up)  | C-v               | rectangle mode
Nested tmux         | F12               | toggle outer/inner prefix
EOF
  # Aligned with the zsh fzf-tab theme (prompt ❯, border none, cycle, no-bold).
  # Override via TX_FZF_OPTS.
  common_flags="${TX_FZF_OPTS:---ansi --height=80% --layout=reverse --border=none --info=inline-right --prompt='❯ ' --pointer='▶' --marker='✓' --cycle --no-bold --color=prompt:#cba6f7,pointer:#f38ba8,marker:#a6e3a1}"
  # shellcheck disable=SC2086
  fzf \
    $common_flags \
    --no-info \
    --no-mouse \
    --delimiter="|" \
    --with-nth=1,2,3
