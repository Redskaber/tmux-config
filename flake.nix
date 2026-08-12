# @file: flake.nix
# @author: redskaber
# @desc: Flake wrapper for tmux-config. Exposes:
#          - the config source (for xdg.configFile."tmux" = { source = inputs.tmux-config; })
#          - a home-manager module (programs.tx) for PATH wiring
# @usage in your flake:
#   inputs.tmux-config.url = "github:redskaber/tmux-config";
#   # in home config:
#   imports = [ inputs.tmux-config.homeModules.tx-home ];
#   programs.tx.enable = true;
#   xdg.configFile."tmux" = { source = inputs.tmux-config; recursive = true; };
{
  description = "tmux-config — policy-driven tmux config + tx window-organization manager";

  outputs = { self, ... }:
    let
      txHomeModule = import ./nix/tx-home.nix;
    in
    {
      # The config source tree — consumers use `source = inputs.tmux-config`
      # directly (flake inputs ARE source trees).

      # Home-manager module: adds ~/.config/tmux/bin to PATH for ALL shells.
      # Usage: imports = [ inputs.tmux-config.homeModules.tx-home ];
      homeModules.tx-home = txHomeModule;

      # Convenience alias: imports = [ inputs.tmux-config.homeModules.default ];
      homeModules.default = txHomeModule;
    };
}
