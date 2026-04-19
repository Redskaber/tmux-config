#!/usr/bin/env bash
# @path: ~/.config/tmux/scripts/tmux-keymap-palette.sh
# @anthor: redskaber
# @datetime: 2026-04-19
# @description: keymap cheatSheet

cat <<'EOF' |
class               | commands           | description
-----------------------------------------------------------
Pane Navigation     | Ctrl     h/j/k/l   | move left/down/up/right
Pane Navigation     | Alt      h/j/k/l   | move (no prefix)
Pane Navigation     | Alt      Up        | enter copy-mode
Window Navigation   | Alt      Left      | previous window
Window Navigation   | Alt      Right     | next window
Window Navigation   | Alt      Tab       | last window
Pane Control        | Ctrl-a   |         | split horizontal
Pane Control        | Ctrl-a   _         | split vertical
Pane Control        | Ctrl-a   x         | kill pane
Pane Control        | Ctrl-a   X         | kill window
Resize              | Ctrl-a   H         | resize pane left
Resize              | Ctrl-a   J         | resize pane down
Resize              | Ctrl-a   K         | resize pane up
Resize              | Ctrl-a   L         | resize pane right
Font                | Ctrl-a   +         | font size up
Font                | Ctrl-a   -         | font size down
System              | Ctrl-a   Ctrl-r    | reload config
System              | Ctrl-a   d         | detach session
System              | Ctrl-a   Ctrl-s    | toggle status bar
Copy Mode(Alt-Up)   | v                  | begin selection
Copy Mode(Alt-up)   | y                  | copy to clipboard
Copy Mode(Alt-up)   | C-v                | rectangle mode
EOF
  fzf \
    --height=70% \
    --layout=reverse \
    --border=none \
    --no-info \
    --no-mouse \
    --prompt="tmux ❯ " \
    --delimiter="|" \
    --with-nth=1,2,3 \
    --color="prompt:cyan,pointer:cyan,marker:cyan" \
    --ansi
