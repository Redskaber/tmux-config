# tmux-config

> A policy-driven tmux configuration with `tx` — a window-organization manager
> that gives tmux the seven capabilities it natively lacks:
> **snapshot · group · name · query · select · store · remove**.

**Author:** redskaber &nbsp;·&nbsp; **License:** MIT &nbsp;·&nbsp; **Version:** 1.3.0

[Install](#install) · [Commands](#the-tx-command) · [Architecture](#architecture) · [Data model](#snapshot-data-model) · [Changelog](#changelog)

---

## The problem

tmux itself does not manage window *organization*. It has no snapshot,
grouping, naming, querying, selecting, storing, or removal of layouts. Even if
you want a consistent window setup, every time you re-enter tmux you rebuild
and reconfigure windows one by one.

`tmux-config` closes that gap with a layered runtime system:

1. **Core tmux settings** — ergonomic navigation, copy mode, status bar.
2. **Policy-driven capability resolvers** — clipboard / keymaps / static layout
   templates, each a pluggable, ordered capability queue.
3. **`tx`** — the organization manager. Captures *live* session state to a
   versioned JSON document, stores it in a queryable repository, and restores
   it (geometry, working directories, window names, active pane/window) on demand.

---

## Install

This is a **pure tmux config repo** — no Nix code lives here. It contains
`tmux.conf`, the `tx` CLI, and supporting scripts. How `tx` gets onto PATH
depends on your platform (manual symlink, or NixOS `home.sessionPath`).

### Manual install (any Linux/macOS)

```bash
./install.sh                       # → ~/.config/tmux, links tx to ~/.local/bin
./install.sh --target ~/.config/tmux --store ~/.local/share/tx   # custom paths
```

Then:

```bash
exec $SHELL                        # pick up PATH
tx doctor                          # verify environment
tx start                           # ← ergonomic entry: pick a snapshot to restore
# or start tmux normally and use bindings inside:
tmux                               # Ctrl-a S (save), Ctrl-a O (load), Ctrl-a Ctrl-t (resume)
```

> `install.sh` **auto-detects** declaratively-managed configs: if
> `~/.config/tmux` is a symlink (home-manager / stow / similar), it prints a
> PATH hint instead of clobbering the symlink.

### NixOS / home-manager integration

Since this repo is a pure config library (declared with `flake = false`),
the Nix side — deploying the files and putting `tx` on PATH — is handled by
**your** home-manager config, not by this repo. A minimal `tmux.nix`:

```nix
# flake.nix
inputs.tmux-config.url = "github:redskaber/tmux-config";
inputs.tmux-config.flake = false;   # pure source tree, not a flake

# home/core/exp/sys/base/tmux.nix
{ inputs, config, ... }: {
  programs.tmux.enable = true;

  # Deploy the config files to ~/.config/tmux
  xdg.configFile."tmux" = {
    source = inputs.tmux-config;
    recursive = true;
    force = true;
  };

  # Put tx on PATH for ALL shells (zsh, fish, bash) — the Nix side's job
  home.sessionPath = [ "${config.xdg.configHome}/tmux/bin" ];
}
```

Then `nix flake update tmux-config && home-manager switch && exec $SHELL && tx doctor`.

### Dependencies

| tool  | version  | required for            |
|-------|----------|-------------------------|
| tmux  | ≥ 3.3    | everything              |
| jq    | ≥ 1.6    | snapshot/index JSON     |
| fzf   | ≥ 0.30   | interactive picker      |
| bash  | ≥ 4.4    | engine (associative arrays, mapfile) |

---

## The `tx` command

```
tx                              # default → interactive picker → load (inside tmux)
tx start   [NAME] [-r]          # START tmux + pick/restore a snapshot (ergonomic entry)
                                #   outside tmux: bootstraps a server then restores
                                #   inside tmux:  picker → switch client
tx save    [NAME] [-g -t -d -a -s -f -y]   snapshot current/all/specific session
tx load    <NAME|ID> [-r -a -c -k]         restore a snapshot
tx last    [-r] [-n N]                     restore / list the N most-recent snapshots
tx ls      [-g -t -n --sort --json]        list / filter snapshots
tx rm      <NAME|ID…> [-f] | -g GROUP      remove snapshot(s)
tx group   <ls|add|rm|mv|show> …           manage groups
tx rename  <OLD> <NEW>                     rename a snapshot
tx tag     <NAME|ID> [+t1,-t2 …]           add/remove tags
tx show    <NAME|ID>                       detailed tree view
tx diff    <A> <B>                         structural diff of two snapshots
tx edit    <NAME|ID>                       edit snapshot JSON in $EDITOR
tx index   <rebuild|check>                 manage the query index
tx doctor                            diagnose environment
tx info                              system & store info
```

### The ergonomic entry point: `tx start`

The single biggest usability win: **start tmux AND restore a snapshot in one command.**

```bash
tx start            # outside tmux → bootstraps a server, shows the picker,
                    #                  restores your selection, attaches
tx start myproj     # outside tmux → bootstrap + restore 'myproj' + attach
tx start            # inside tmux  → picker → switch-client to the restored session
```

Performance: `tx start` is **on-demand only** — it never auto-runs when tmux
starts (avoids adding latency to every `tmux` invocation). The picker reads
the cached index (microsecond cost). `tx last` is even cheaper — no picker,
just restore the newest snapshot (bound to `Ctrl-a C-t` for one-key resume).

### Examples

```bash
# Snapshot the current session, file it under a group + tags
tx save myproj -g work -t frontend,nextjs -d "morning setup"

# Restore it later (replace any existing session of the same name)
tx load myproj --replace --attach

# Re-run captured pane commands too (e.g. re-launch your watcher)
tx load myproj --replace --commands

# Query
tx ls -g work --sort name
tx ls -t urgent --json

# Organize
tx group add personal
tx tag myproj +urgent -wip
tx rename old-name new-name
tx group mv work company

# Inspect & diff
tx show myproj
tx diff v1 v2
```

### tmux keybindings

| keys              | action                                          |
|-------------------|-------------------------------------------------|
| `Ctrl-a S`        | save current session as a named snapshot (popup)|
| `Ctrl-a O`        | interactive picker → restore (popup)            |
| `Ctrl-a M-s`      | list snapshots (popup)                          |
| `Ctrl-a Ctrl-o`   | quick auto-named save (background)              |
| `Ctrl-a Ctrl-t`   | **one-key resume** — restore most-recent snapshot |
| `Ctrl-a L`        | apply a *static* layout template (fzf)          |
| `Ctrl-a ?`        | keymap cheat-sheet                              |

From outside tmux, use **`tx start`** (or `tx start NAME`) as the entry point.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  CLI Layer        bin/tx — arg parsing, dispatch, colors       │
├──────────────────────────────────────────────────────────────┤
│  UI Layer         lib/ui — fzf picker, tables, tree, formatters│
├──────────────────────────────────────────────────────────────┤
│  Domain Layer     lib/snapshot  capture · restore · diff       │
│                   lib/store     repository CRUD · index        │
│                   lib/group     group lifecycle                │
├──────────────────────────────────────────────────────────────┤
│  Core Layer       lib/core — config · log · tmux · validate   │
├──────────────────────────────────────────────────────────────┤
│  tmux 3.x  ·  jq  ·  fzf   (external)                         │
└──────────────────────────────────────────────────────────────┘
```

### Design principles

- **Separation of concerns** — each layer has one job; no layer reaches up.
- **Capability abstraction** — behavior is an ordered queue of `check_*`/`exec_*`
  backends, not `if/elif` chains (clipboard, layouts).
- **Explicit over implicit** — no hidden fallbacks; every resolution is logged.
- **Data/code separation** — engine lives in the config dir; *your snapshots*
  live in `~/.local/share/tx` (overridable via `TX_STORE_DIR`).
- **Portability** — pure bash 4.4+; deps are `tmux`, `jq`, `fzf`.
- **Self-healing** — corrupt index is auto-rebuilt; `tx doctor` verifies all.
- **Single source of truth** — one fzf-style helper (`ui_fzf_common_flags`),
  one index-numbering resolver (`core_tmux_base_index`), one PATH-wiring path
  per deployment context.
- **Tested** — 63 integration tests assert a save → kill → load round-trip
  reproduces the *exact* pane structure (indices, cwds, active states, geometry).

---

## Repository layout

```
tmux-config/
├── tmux.conf                  # core settings + keybindings (wires tx)
├── bin/
│   └── tx                     # CLI entrypoint (the organization manager)
├── lib/
│   ├── core.sh                # config · log · tmux wrappers · validate · colors
│   ├── snapshot.sh            # capture (live→JSON) · restore (JSON→tmux) · diff
│   ├── store.sh               # repository CRUD · atomic writes · index cache
│   ├── group.sh               # group lifecycle (create/list/rename/remove)
│   └── ui.sh                  # fzf picker · table/tree formatters · shared fzf style
├── policy/
│   ├── copy/                  # clipboard backends (osc52/wl-copy/xclip/pbcopy)
│   └── layouts/               # static layout templates (dashboard/dev/git/…)
├── scripts/
│   ├── tmux-clipboard.sh      # capability-based clipboard resolver
│   ├── tmux-keymaps.sh        # fzf keymap cheat-sheet (aligned style)
│   ├── tmux-layouts.sh        # static layout dispatcher (fzf → apply)
│   └── tmux-tx-save.sh        # popup helper for `prefix S`
├── tests/
│   └── run.sh                 # integration test suite (63 assertions)
├── install.sh                 # auto-detects managed vs manual install
├── LICENSE
└── README.md
```

---

## Snapshot data model

Schema: `tx.snapshot.v1`

```jsonc
{
  "schema": "tx.snapshot.v1",
  "meta": {
    "id": "a1b2c3d4",            // 8-hex unique id
    "name": "myproj",            // human name (unique)
    "group": "work",
    "tags": ["frontend", "nextjs"],
    "description": "morning setup",
    "created_at": "2026-04-19T10:30:00+08:00",
    "scope": "session",          // "session" | "all"
    "tmux_version": "3.5a",
    "tx_version": "1.3.0"
  },
  "stats": { "sessions": 1, "windows": 2, "panes": 5 },
  "sessions": [
    {
      "name": "dev",
      "base_index": 1,           // captured so restore aligns numbering
      "pane_base_index": 1,
      "windows": [
        {
          "index": 1, "name": "editor", "active": true,
          "layout": "21be,200x50,0,0{…}",   // tmux layout string
          "panes": [
            { "index": 1, "active": true,
              "cwd": "/home/me/proj",
              "command": "nvim",            // pane_current_command
              "cmdline": "nvim init.lua",   // /proc/<pid>/cmdline (Linux)
              "width": 100, "height": 50, "x": 0, "y": 0 }
          ]
        }
      ]
    }
  ]
}
```

### How restore reproduces geometry exactly

1. Create the session with the first window/pane and its saved cwd.
2. Set `base-index` / `pane-base-index` to the captured values (tmux
   retroactively renumbers existing windows/panes); `move-window -r` shifts
   the auto-created window up to `base-index` so saved indices line up.
3. For each window: `split-window -c <cwd>` until the pane count matches, then
   `select-layout <saved-layout>` to reshape the panes to the exact saved
   geometry. Window names and active pane/window are then restored.

The test suite asserts the pane descriptor (`session:win.pane cwd active WxH`)
is **byte-identical** before and after a kill → restore round-trip.

---

## Capability layer

### Clipboard

`scripts/tmux-clipboard.sh` is a runtime resolver. Backends live in
`policy/copy/` and are registered into an ordered queue:

```
osc52 → wl-copy → xclip → pbcopy → fallback
```

`check_*` is evaluated in order; the first match's `exec_*` runs. SSH sessions
auto-use OSC 52; local sessions auto-detect Wayland / X11 / macOS.

### Static layouts

`scripts/tmux-layouts.sh` scans `policy/layouts/*`, parses `@`-tagged metadata,
and presents an fzf picker. `[Enter]` creates a new session with the template;
`[Ctrl-O]` applies it to the current window. Templates define pane *geometry*
only (unlike `tx`, which captures *state*).

---

## Discoverability

`tx` is resolvable from any context via a 4-strategy resolver:

1. **`TX_BIN` env** (explicit override)
2. **next to `lib/core.sh`** (project layout: `<home>/bin/tx`)
3. **on PATH** (`command -v tx`)
4. **common install symlinks** (`~/.local/bin/tx`, `~/.config/tmux/bin/tx`)

`bin/tx` also prepends `TX_HOME/bin` to `PATH` on startup, so any subprocess
(popups, `run-shell`, the fzf preview) can call `tx` by bare name. The
`tmux.conf` bootstraps `TX_HOME` + `PATH` via `if-shell` so bindings work
immediately after install.

On NixOS/home-manager, the `nix/tx-home.nix` module wires PATH via
`home.sessionPath` — the idiomatic, shell-agnostic way.

---

## fzf theme

All fzf call sites share a centralized style (`ui_fzf_common_flags` in
`lib/ui.sh`), aligned with the common zsh `fzf-tab` configuration:

```
--prompt='❯ ' --pointer='▶' --marker='✓'
--border=none --height=55% --layout=reverse --info=inline-right
--cycle --no-bold
```

Catppuccin Mocha accent colors (consistent with the tmux status bar). Override
the entire style via the `TX_FZF_OPTS` environment variable.

---

## Environment variables

| var                | default                  | purpose                          |
|--------------------|--------------------------|----------------------------------|
| `TX_STORE_DIR`     | `~/.local/share/tx`      | where snapshot data lives        |
| `TX_HOME`          | (auto: dir of `bin/tx`)  | engine root                      |
| `TX_BIN`           | (auto)                   | explicit tx binary path          |
| `TX_COLOR`         | `auto`                   | `auto`/`never`/`force`           |
| `TX_LOG_LEVEL`     | `info`                   | `debug`/`info`/`warn`/`error`    |
| `TX_FZF_OPTS`      | (built-in defaults)      | override all fzf flags           |
| `TX_RESTORE_COMMANDS` | `0`                   | default for `tx load --commands` |
| `EDITOR`           | `vi`                     | used by `tx edit`                |

---

## Testing

```bash
./tests/run.sh            # run the suite (isolated tmux server + throwaway store)
./tests/run.sh -v         # verbose
```

The suite spins up an isolated tmux server, builds known session geometries,
and verifies:

- save produces a valid, schema-conformant snapshot with correct stats
- **round-trip** (save → kill → load) reproduces pane structure **exactly**
- **`tx start` (outside tmux)** bootstraps a server + restores a named snapshot
- **`tx last`** restores the *newest* snapshot (newest-first ordering)
- multi-session `--all` capture/restore
- list/filter (`-g`, `-t`, `--json`), remove, rename, tag, group lifecycle
- structural diff, index self-heal after corruption, show tree rendering
- name uniqueness + `--force` overwrite, missing-snapshot errors, `--commands` restore
- **discoverability**: `tx` runs from any CWD (not just `tmux-config/bin/`)
- **standardized index numbering**: `base-index` / `pane-base-index` resolve to validated integers
- **empty-tags regression**: the `ls` table renders cleanly when a snapshot has no tags
- **renumber-windows on**: multi-window round-trip (the v1.2.0 restore bug)
- **session == window name** edge case
- **managed-symlink detection** (install.sh on NixOS)
- **fzf flags centralization** + `TX_FZF_OPTS` override
- **Nix module existence** (`home.sessionPath` wiring)

---

## Changelog

### v1.4.0 — pure config repo (Nix code removed)

- **Architecture correction**: `tmux-config` is now a **pure tmux config
  library** — no Nix code lives here. Removed `flake.nix` and `nix/tx-home.nix`.
- **Separation of concerns**: the Nix side (deploying files + putting `tx` on
  PATH) is the responsibility of the consumer's `nix-config`, not this repo.
  README now shows a minimal `tmux.nix` using `xdg.configFile` + `home.sessionPath`.
- **`install.sh`** simplified: removed Nix module snippets; keeps the general
  "symlink → declaratively managed → print hint" detection (works for home-manager,
  stow, etc.).
- **Tests**: removed `test_nix_module_exists` (no Nix module to test). The bash
  test suite now validates the pure tmux-config library only. Nix integration is
  verified separately by simulating a consumer flake.
- Test suite: **62 tests** (was 63; removed the Nix-module existence check).

### v1.3.2 — fix `flake = false` deployment (the actual user bug)

- **Root cause found**: the user's `flake.nix` declares `tmux-config.flake = false`
  (the standard pattern for config repos — same as `starship-config`, `kitty-config`,
  etc.). With `flake = false`, Nix treats `inputs.tmux-config` as a **source path**,
  NOT a flake — so `inputs.tmux-config.homeModules` doesn't exist
  (`attribute 'homeModules' missing`).
- **Fix**: documented two loading patterns — **A1** (`flake = false` + `import`)
  and **A2** (`flake = true` + `homeModules`). A1 is recommended for consistency
  with other config repos. The module file `nix/tx-home.nix` is loadable both ways.
- **Verified** with a consumer flake using `flake = false`:
  `import "${inputs.tmux-config}/nix/tx-home.nix"` produces a valid module function;
  `homeModules` correctly absent under `flake = false`.
- **install.sh** snippet updated to show both patterns.
- **README** rewritten install section with A1/A2 + troubleshooting.

### v1.3.1 — flake module fix

- **flake.nix robustness** — removed `self.homeModules` self-reference; module
  bound to a `let` variable.
- **Module cleanup** — `nix/tx-home.nix` removed redundant `or {}`, added
  `defaultText`, consolidated `home.sessionVariables`.
- **Verified end-to-end with Nix 2.30**.

### v1.3.0 — NixOS/home-manager support + fzf theme alignment

- **NixOS / home-manager module** — new `nix/tx-home.nix` + `flake.nix`. The
  module uses `home.sessionPath` to add `tx` to PATH for **all shells** (zsh,
  fish, bash) — the idiomatic NixOS way, no rc-file editing.
- **`install.sh` auto-detects managed configs** — if `~/.config/tmux` is a
  symlink (home-manager / stow / similar), it prints the Nix snippet instead of
  clobbering the symlink. `--force` overrides. General "symlink → managed"
  heuristic, not a NixOS hardcode.
- **fzf theme aligned with zsh fzf-tab** — centralized `ui_fzf_common_flags()`
  in `lib/ui.sh`. All four fzf call sites use it. Override via `TX_FZF_OPTS`.
- **Author attribution** — all source files now carry `@author: redskaber`;
  `tx info` displays the author; LICENSE updated.
- Test suite expanded: 53 → **63 tests**.

### v1.2.0 — cross-platform & restore robustness

- **Critical restore fix** — `new-window -t <session>` (no colon) FAILS with
  `create window failed: index in use` when `renumber-windows on` + `base-index 1`.
  Changed to `new-window -t <session>:` (trailing colon, forces append).
- **Window index resolution** — restore resolves the ACTUAL current window
  index by name (not the saved index), robust across tmux 3.5a / 3.6a.
- **Real error reporting** — `new-session` / `new-window` capture and report
  the actual tmux error instead of blanket-suppressing stderr.
- **Shell-aware `install.sh`** — detects `$SHELL` (bash/zsh/fish) and writes
  PATH to the correct rc file (`.zshenv` for zsh — sourced by ALL shells).
- Test suite expanded: 48 → **53 tests**.

### v1.1.0 — ergonomics & discoverability

- **`tx start`** — ergonomic entry point: start tmux + pick/restore a snapshot.
- **`tx last`** — restore or list the N most-recent snapshots; `Ctrl-a C-t`.
- **Discoverability fix** — 4-strategy resolver; `bin/tx` prepends `TX_HOME/bin`
  to PATH; `tmux.conf` bootstraps the env via `if-shell`.
- **Standardized index numbering** — `core_tmux_base_index` / `core_tmux_pane_base_index`.
- **`store_list` always newest-first**.
- **FS-delimiter regression fix** — 0x1F / `~~~` instead of TAB.
- Test suite expanded: 38 → **48 tests**.

### v1.0.0 — initial release

Policy-driven tmux config + `tx` window-organization manager (snapshot · group ·
name · query · select · store · remove · restore).

---

## Philosophy

> **Do one thing well** — tmux manages sessions; `tx` manages organization.

- separation of concerns
- runtime composition over static config
- explicit capability modeling
- minimal implicit behavior
- data/code separation (snapshots are *your* data, not in the config repo)
- single source of truth (one fzf style, one index resolver, one PATH path per context)

---

## License

MIT © 2026 [redskaber](https://github.com/redskaber)
