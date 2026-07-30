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
      ghosttyRev = "6ad1fe7d8cbda36c77b337a96c9bea8a77883699";
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          lib = pkgs.lib;
          ghosttySrc = pkgs.fetchzip {
            url = "https://github.com/ghostty-org/ghostty/archive/${ghosttyRev}.tar.gz";
            hash = "sha256-tmsO+ORO9TgdCBuLru4071zQJmgbaobLIMKV5QE4bFY=";
          };
          ghosttyDeps = pkgs.callPackage "${ghosttySrc}/build.zig.zon.nix" {
            name = "tinymux-ghostty-cache-${ghosttyRev}";
            linkFarm =
              name: entries:
              pkgs.runCommand name { } ''
                mkdir -p "$out"
                ${lib.concatMapStringsSep "\n" (entry: ''
                    cp -rL ${entry.path} "$out/${entry.name}"
                  '') entries}
              '';
          };
        in
        rec {
          tinymux = pkgs.stdenv.mkDerivation {
            pname = "tinymux";
            version = "0.1.0";

            src = lib.cleanSource ./.;

            nativeBuildInputs = [
              pkgs.zig_0_16
              pkgs.python3
              pkgs.bashInteractive
              pkgs.fish
              pkgs.zsh
              pkgs.nushell
            ];

            patchPhase = ''
              runHook prePatch
              cp -R ${ghosttySrc} .nix-ghostty
              chmod -R u+w .nix-ghostty
              python3 - <<'PY'
              from pathlib import Path

              def replace_dependency(path: Path, name: str, replacement: str) -> None:
                  text = path.read_text()
                  start = text.index(f".{name} = .{{")
                  end = text.index("        },", start) + len("        },")
                  path.write_text(text[:start] + replacement + text[end:])

              replace_dependency(
                  Path("build.zig.zon"),
                  "ghostty",
                  '.ghostty = .{ .path = "./.nix-ghostty", .lazy = true },',
              )
              PY
              runHook postPatch
            '';

            buildPhase = ''
              runHook preBuild
              export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
              export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
              zig build --system ${ghosttyDeps} -Doptimize=ReleaseSafe --summary all --prefix "$out"
              runHook postBuild
            '';

            checkPhase = ''
              runHook preCheck
              export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
              export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
              zig build --system ${ghosttyDeps} test --summary all
              # Darwin's Nix sandbox does not reliably deliver the watcher
              # exit signal used by the full seamless-shell lifecycle tests.
              python3 ${./tests/spec/tinymux_contract.py} \
                --tinymux "$out/bin/tinymux" \
                ${lib.optionalString pkgs.stdenv.hostPlatform.isDarwin "--persistent-only"}
              runHook postCheck
            '';

            installPhase = ''
              runHook preInstall
              runHook postInstall
            '';

            doCheck = true;

            meta = with lib; {
              description = "Tiny Boo-style split terminal multiplexer";
              homepage = "https://github.com/conroy/tinymux";
              mainProgram = "tinymux";
              platforms = platforms.unix;
            };
          };

          default = tinymux;
        }
      );

      homeManagerModules = {
        tinymux = import ./modules/home-manager/tinymux.nix { inherit self; };
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

      checks = forAllSystems (system: {
        package = self.packages.${system}.tinymux;
      });

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
