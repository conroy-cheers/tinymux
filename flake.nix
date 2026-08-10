{
  description = "tinymux: a tiny Boo-style split terminal multiplexer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];

      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        rec {
          tinymux = pkgs.callPackage ./package.nix { };

          default = tinymux;
        }
      );

      homeManagerModules = {
        tinymux = import ./modules/home-manager/tinymux.nix;
        default = self.homeManagerModules.tinymux;
      };

      apps = forAllSystems (
        system:
        let
          tinymuxApp = {
            type = "app";
            program = "${self.packages.${system}.tinymux}/bin/tinymux";
          };
        in
        {
          tinymux = tinymuxApp;
          default = tinymuxApp;
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          package = self.packages.${system}.tinymux;
          cpu-policy =
            assert import ./nix/zig-cpu-tests.nix { inherit (pkgs) lib; };
            pkgs.runCommand "tinymux-zig-cpu-policy" { } ''
              touch "$out"
            '';
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.zig_0_16
              pkgs.python3
              pkgs.bashInteractive
              pkgs.fish
              pkgs.zsh
              pkgs.nushell
              pkgs.tmux
              pkgs.nixpkgs-fmt
            ];

            TINYMUX_FEATURE_SCOPE = "boo-style-raw-main-with-output-only-bottom-split";

            shellHook = ''
              echo "tinymux dev shell"
              echo "scope: Boo-style raw main plus output-only split"
            '';
          };
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
