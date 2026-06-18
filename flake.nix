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
      ghosttyRev = "69095e298ab88bb0eb5ba541f4c505f2c22d07f5";
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          lib = pkgs.lib;
          ghosttySrc = pkgs.fetchzip {
            url = "https://github.com/ghostty-org/ghostty/archive/${ghosttyRev}.tar.gz";
            hash = "sha256-XH2zydfK97HYkW7Ra5I3nrL8hlZRDEMzXW+9OH+ryvU=";
          };
          uucodeSrc = pkgs.fetchzip {
            url = "https://deps.files.ghostty.org/uucode-0.2.0-ZZjBPqZVVABQepOqZHR7vV_NcaN-wats0IB6o-Exj6m9.tar.gz";
            hash = "sha256-jLrhrmCXQ1T+LQP1JTBBB3Jn+1hCZfODbC4SdlfNdKg=";
          };
          wuffsCoreSrc = pkgs.fetchzip {
            url = "https://deps.files.ghostty.org/wuffs-122037b39d577ec2db3fd7b2130e7b69ef6cc1807d68607a7c232c958315d381b5cd.tar.gz";
            hash = "sha256-XbupK4QYnPudUlO5tRWrQRncGHITzJL//Yk/E7WNxYk=";
          };
        in
        rec {
          tinymux = pkgs.stdenv.mkDerivation {
            pname = "tinymux";
            version = "0.1.0";

            src = lib.cleanSource ./.;

            nativeBuildInputs = [
              pkgs.zig_0_15
              pkgs.python3
            ];

            patchPhase = ''
              runHook prePatch
              cp -R ${ghosttySrc} .nix-ghostty
              cp -R ${uucodeSrc} .nix-uucode
              cp -R ${wuffsCoreSrc} .nix-wuffs-core
              chmod -R u+w .nix-ghostty
              chmod -R u+w .nix-uucode
              chmod -R u+w .nix-wuffs-core
              cp -R ${uucodeSrc} .nix-ghostty/.nix-uucode
              chmod -R u+w .nix-ghostty/.nix-uucode
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
              replace_dependency(
                  Path("build.zig.zon"),
                  "uucode",
                  '.uucode = .{ .path = "./.nix-uucode", .lazy = true },',
              )
              replace_dependency(
                  Path("build.zig.zon"),
                  "wuffs_core",
                  '.wuffs_core = .{ .path = "./.nix-wuffs-core", .lazy = true },',
              )
              replace_dependency(
                  Path(".nix-ghostty/build.zig.zon"),
                  "uucode",
                  '.uucode = .{ .path = "./.nix-uucode" },',
              )
              PY
              runHook postPatch
            '';

            buildPhase = ''
              runHook preBuild
              export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
              export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
              zig build -Doptimize=ReleaseSafe -Dghostty-src=.nix-ghostty --summary all --prefix "$out"
              runHook postBuild
            '';

            checkPhase = ''
              runHook preCheck
              export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
              export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
              zig build test -Dghostty-src=.nix-ghostty --summary all
              python3 ${./tests/spec/tinymux_contract.py} --tinymux "$out/bin/tinymux"
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
              pkgs.zig_0_15
              pkgs.python3
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
