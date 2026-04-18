#!/usr/bin/env bash

cat <<'EOF' |
Pane Navigation   | h/j/k/l   | move left/down/up/right
Pane Navigation   | M-h/j/k/l | move (no prefix)
Pane Navigation   | M-Up      | enter copy-mode

Window Navigation | M-Left    | previous window
Window Navigation | M-Right   | next window
Window Navigation | M-Tab     | last window

Pane Control      | \|        | split horizontal
Pane Control      | _         | split vertical
Pane Control      | x         | kill pane
Pane Control      | X         | kill window

Resize            | H         | resize pane left
Resize            | J         | resize pane down
Resize            | K         | resize pane up
Resize            | L         | resize pane right

System            | C-r       | reload config
System            | d         | detach session
System            | +         | toggle zoom
System            | C-s       | toggle status bar

Copy Mode         | v         | begin selection
Copy Mode         | y         | copy to clipboard
Copy Mode         | C-v       | rectangle mode
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
