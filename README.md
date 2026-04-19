# tmux-config

A policy-driven tmux configuration with capability-based runtime resolution.

---

## Overview

This project is not a static `tmux.conf`.

It is a **structured runtime system** built around:

- **Capability abstraction**
- **Policy-driven resolution**
- **Composable layout templates (WIP)**

The goal is to keep tmux focused on session management, while externalizing behavior into modular, replaceable components.

---

## Architecture

### 1. Capability Layer

Core behaviors are abstracted as **capabilities**:

- clipboard (copy)
- layout (planned)
- keymap (partial)

Each capability consists of:

- `check_*`: determines availability
- `exec_*`: executes behavior

---

### 2. Policy Layer

Policies define **resolution order** via a capability queue.

Example (clipboard):

```
osc52 → wl-copy → xclip → pbcopy → fallback
```

- Order = priority
- Fully decoupled from implementation
- Easily replaceable

Location:

```
policy/
└── copy/
    ├── osc52.sh
    ├── wl-copy.sh
    ├── xclip.sh
    └── pbcopy.sh
```

Each file implements a **single backend**.

---

### 3. Executor (Runtime Resolver)

Implemented in:

```
scripts/tmux-clipboard.sh
```

Responsibilities:

- register capabilities into a queue
- evaluate `check_*` in order
- execute first matching backend
- fallback is treated as a normal capability

This replaces traditional `if/elif` branching with:

> ordered capability resolution

---

### 4. Tmux Integration

Clipboard integration:

```
bind -T copy-mode-vi y send-keys -X copy-pipe-and-cancel "./scripts/tmux-clipboard.sh"
```

Tmux delegates behavior → external resolver.

---

### 5. Layout System (WIP)

Planned structure:

```
policy/layouts/
├── template/   # declarative layout definitions
└── runtime/    # compiled tmux scripts
```

Future pipeline:

```
template → build → runtime → tmux session
```

---

## Features

- Vim-style navigation
- Meta-key (Alt) navigation without prefix
- Clipboard auto-resolution (Wayland / X11 / macOS / SSH)
- OSC52 support for remote sessions
- Popup keymap palette (fzf-based)
- Minimal, non-intrusive status bar

---

## Dependencies

Required:

- tmux (>= 3.x)

Optional (clipboard backends):

- wl-clipboard (Wayland)
- xclip or xsel (X11)
- pbcopy (macOS)

Optional (UI):

- fzf (for keymap palette)

---

## Philosophy

> Do One Thing Well — tmux manages sessions, not your workflow

This project enforces:

- separation of concerns
- runtime composition over static config
- explicit capability modeling
- minimal implicit behavior

---

## Usage

### Reload config

```
Ctrl-a r
```

### Open keymap palette

```
Ctrl-a ?
```

### Copy (auto backend)

```
Alt + Up → enter copy-mode
v         → select
y         → copy
```

---

## Design Notes

- No monolithic scripts
- No hardcoded environment branching
- No implicit fallbacks
- Everything is explicit, ordered, and replaceable

---

## Future Work

- layout template DSL / compiler
- dynamic policy injection
- capability metadata (tags / weights)
- integration with just / build pipeline

---

## License

MIT
