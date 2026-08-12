# @file: nix/tx-home.nix
# @author: redskaber
# @desc: home-manager module for tmux-config / tx — adds `tx` to PATH for ALL
#        shells (zsh, fish, bash) via home.sessionPath, so `tx` is callable
#        from interactive shells, tmux popups, and run-shell alike.
# @usage: import this module in your home-manager config, or copy the
#         `home.sessionPath` line into your existing shell config.
#
# WHY home.sessionPath (not programs.zsh.envExtra):
#   - home.sessionPath is shell-agnostic: home-manager writes it into
#     hm-session-vars.sh, which ALL shells source (zsh via .zshenv, fish via
#     shellInit, bash via .bashrc/.profile).
#   - programs.zsh.envExtra only helps zsh; tmux's run-shell may use bash.
#
# This module assumes the tmux-config files are ALREADY deployed to
# ~/.config/tmux/ (e.g. via xdg.configFile."tmux" = { source = inputs.tmux-config; }).
# It only handles PATH wiring + optional store dir.

{ config, lib, pkgs, ... }:

let
  cfg = config.programs.tx or {};
in
{
  options.programs.tx = {
    enable = lib.mkEnableOption "tx — tmux window-organization manager";

    storeDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.xdg.dataHome}/tx";
      description = "Where tx stores snapshots (TX_STORE_DIR).";
    };

    configDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.xdg.configHome}/tmux";
      description = "Where the tmux-config files live (must contain bin/tx).";
    };
  };

  config = lib.mkIf cfg.enable {
    # Add tx's bin/ to PATH for ALL shells. This is the single source of truth
    # for discoverability on NixOS — no shell-rc editing needed.
    home.sessionPath = [ "${cfg.configDir}/bin" ];

    # TX_STORE_DIR — where snapshots live. sessionVariables is sourced by all
    # shells via hm-session-vars.sh.
    home.sessionVariables.TX_STORE_DIR = cfg.storeDir;

    # TX_HOME — the engine root (where lib/ lives). Helps tx find its libs
    # even if invoked from a context where __file__ resolution is ambiguous.
    home.sessionVariables.TX_HOME = cfg.configDir;
  };
}
