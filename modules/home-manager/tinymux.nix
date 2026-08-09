{ self }:
{ config, lib, pkgs, ... }:

let
  cfg = config.programs.tinymux;
  inherit (lib) elem mkEnableOption mkIf mkOption types;

  system = pkgs.stdenv.hostPlatform.system;
  tinymuxPackage =
    self.packages.${system}.tinymux
      or (throw "tinymux does not provide a package for ${system}");
in
{
  options.programs.tinymux = {
    enable = mkEnableOption "tinymux";

    package = mkOption {
      type = types.package;
      default = tinymuxPackage;
      defaultText = lib.literalExpression "tinymux.packages.\${pkgs.stdenv.hostPlatform.system}.tinymux";
      description = "The tinymux package to install.";
    };

    session = {
      enable = mkEnableOption "a persistent tinymux session for interactive shells";

      shells = mkOption {
        type = types.listOf (types.enum [ "fish" ]);
        default = [ "fish" ];
        description = "Interactive shells bootstrapped inside a persistent tinymux session.";
      };

      externalMuxPolicy = mkOption {
        type = types.enum [ "skip" "nest" ];
        default = "skip";
        description = "Whether to skip bootstrap when another supported multiplexer is active.";
      };
    };
  };

  config = mkIf cfg.enable {
    home.packages = [ cfg.package ];

    programs.fish.interactiveShellInit = mkIf
      (cfg.session.enable && elem "fish" cfg.session.shells)
      (lib.mkBefore ''
        function __tinymux_bootstrap_session
          status is-interactive; or return 1
          test -t 0; and test -t 1; or return 1
          set -q TINYMUX; and return 1
          test "$TINYMUX_DISABLE" = 1; and return 1
          ${lib.optionalString (cfg.session.externalMuxPolicy == "skip") ''
            set -q TMUX; and return 1
            set -q ZELLIJ; and return 1
            set -q KITTY_LISTEN_ON; and return 1
            test "$TERM_PROGRAM" = WezTerm; and return 1
          ''}
          return 0
        end

        if __tinymux_bootstrap_session
          set -l __tinymux_fish_args --interactive
          status is-login; and set -a __tinymux_fish_args --login
          exec ${cfg.package}/bin/tinymux session -- ${pkgs.fish}/bin/fish $__tinymux_fish_args
        end
        functions -e __tinymux_bootstrap_session
      '');
  };
}
