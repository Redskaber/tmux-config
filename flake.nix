# @file: flake.nix
# @author: redskaber
# @desc: Flake wrapper for tmux-config. Exposes:
#          - the config source (for xdg.configFile."tmux")
#          - a home-manager module (programs.tx) for PATH wiring
# @usage in your flake:
#   inputs.tmux-config.url = "github:you/tmux-config";
#   # in home config:
#   imports = [ inputs.tmux-config.nixosModules.tx-home ];
#   programs.tx.enable = true;
#   xdg.configFile."tmux" = { source = inputs.tmux-config; recursive = true; };
{
  description = "tmux-config — policy-driven tmux config + tx window-organization manager";

  outputs = { self, ... }: {
    # The config source tree (for xdg.configFile."tmux" = { source = self; }).
    # Flake inputs are self-contained source trees, so this is idiomatic.
    # (No overlay needed — consumers use `source = self` directly.)

    # Home-manager module usable from any flake that imports this as an input.
    homeModules.tx-home = import ./nix/tx-home.nix;

    # Convenience alias.
    homeModules.default = self.homeModules.tx-home;
  };
}
