{ self }:
{ config, lib, pkgs, ... }:

let
  cfg = config.programs.tinymux;
  inherit (lib) elem mkEnableOption mkIf mkOption optional types;

  system = pkgs.stdenv.hostPlatform.system;
  tinymuxPackage =
    self.packages.${system}.tinymux
      or (throw "tinymux does not provide a package for ${system}");

  wrapper = "${cfg.package}/bin/tinymux-direnv-instant";
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

    direnvInstant = {
      enable = mkEnableOption "tinymux wrapping for direnv-instant shell hooks";

      package = mkOption {
        type = types.nullOr types.package;
        default = pkgs.direnv-instant or null;
        defaultText = lib.literalExpression "pkgs.direnv-instant";
        description = ''
          The direnv-instant package to install alongside tinymux. Set this
          to null when another module already installs direnv-instant.
        '';
      };

      shells = mkOption {
        type = types.listOf (types.enum [ "bash" "fish" "nu" "zsh" ]);
        default = [ ];
        example = [ "fish" "zsh" ];
        description = "Shells where the tinymux direnv-instant hook should be installed.";
      };
    };
  };

  config = mkIf cfg.enable {
    home.packages =
      [ cfg.package ]
      ++ optional (cfg.direnvInstant.enable && cfg.direnvInstant.package != null) cfg.direnvInstant.package;

    programs.bash.initExtra = mkIf
      (cfg.direnvInstant.enable && elem "bash" cfg.direnvInstant.shells)
      (lib.mkAfter ''
        eval "$(${wrapper} hook bash)"
      '');

    programs.fish.interactiveShellInit = mkIf
      (cfg.direnvInstant.enable && elem "fish" cfg.direnvInstant.shells)
      (lib.mkAfter ''
        ${wrapper} hook fish | source
      '');

    programs.nushell.extraConfig = mkIf
      (cfg.direnvInstant.enable && elem "nu" cfg.direnvInstant.shells)
      (lib.mkAfter ''
        source ${pkgs.runCommand "tinymux-direnv-instant-hook.nu" { } ''
          ${wrapper} hook nu > "$out"
        ''}
      '');

    programs.zsh.initExtra = mkIf
      (cfg.direnvInstant.enable && elem "zsh" cfg.direnvInstant.shells)
      (lib.mkAfter ''
        eval "$(${wrapper} hook zsh)"
      '');
  };
}
