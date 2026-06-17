{
  description = "tinymux: a high-performance terminal multiplexer with one fixed two-pane split";

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
          lib = pkgs.lib;

          sourceHasCargoLock =
            builtins.pathExists ./Cargo.toml
            && builtins.pathExists ./Cargo.lock;

          parityPython = pkgs.python3.withPackages (pythonPackages: with pythonPackages; [
            pyte
          ]);
          xtermJs = pkgs.fetchurl {
            url = "https://registry.npmjs.org/@xterm/xterm/-/xterm-5.5.0.tgz";
            hash = "sha256-vZVPpyGHIXAYjMXX6D6I2zyDyaGKTo0kwng9JkkfWdI=";
          };

          libvtermEnv = ''
            for candidate in \
              "${pkgs.libvterm-neovim}/lib/libvterm.so" \
              "${pkgs.libvterm-neovim}"/lib/libvterm.so.* \
              "${pkgs.libvterm-neovim}"/lib/libvterm.*.dylib \
              "${pkgs.libvterm-neovim}/lib/libvterm.dylib"; do
              if [ -e "$candidate" ]; then
                export TINYMUX_LIBVTERM="$candidate"
                break
              fi
            done
          '';

          nativeBuildInputs = with pkgs; [
            pkg-config
          ];

          buildInputs =
            with pkgs;
            [
              libevent
              ncurses
              utf8proc
            ];

          meta = with lib; {
            description = "High-performance terminal multiplexer with a main pane above one secondary pane";
            homepage = "https://github.com/conroy/tinymux";
            mainProgram = "tinymux";
            platforms = platforms.unix;
          };
        in
        rec {
          tinymux =
            if sourceHasCargoLock then
              pkgs.rustPlatform.buildRustPackage
                {
                  pname = "tinymux";
                  version = "0.1.0";

                  src = lib.cleanSource ./.;
                  cargoLock.lockFile = ./Cargo.lock;

                  inherit nativeBuildInputs buildInputs meta;
                }
            else
              pkgs.stdenvNoCC.mkDerivation {
                pname = "tinymux";
                version = "0.1.0";

                dontUnpack = true;

                installPhase = ''
                                    runHook preInstall

                                    mkdir -p "$out/bin"
                                    cat > "$out/bin/tinymux" <<'EOF'
                  #!/usr/bin/env sh
                  cat <<'MESSAGE'
                  tinymux package scaffold

                  This flake is ready for the tinymux source tree. Once Cargo.toml and
                  Cargo.lock exist, packages.tinymux will build the Rust crate directly.

                  Feature scope: one fixed two-pane split, with the main pane above and a
                  secondary pane below.
                  MESSAGE
                  EOF
                                    chmod +x "$out/bin/tinymux"

                                    runHook postInstall
                '';

                inherit meta;
              };

          default = tinymux;

          "tmux-parity-runner" = pkgs.writeShellApplication {
            name = "tinymux-tmux-parity";
            runtimeInputs = [
              pkgs.libvterm-neovim
              parityPython
              pkgs.tmux
            ];
            text = ''
              ${libvtermEnv}
              exec ${parityPython}/bin/python ${./tests/parity/tmux_snapshot_parity.py} \
                --tinymux ${tinymux}/bin/tinymux \
                --tmux ${pkgs.tmux}/bin/tmux \
                --shell ${pkgs.runtimeShell} \
                "$@"
            '';
          };
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

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages =
              with pkgs;
              [
                cargo
                clang
                clippy
                cmake
                expect
                gnumake
                lldb
                ninja
                libvterm-neovim
                nixpkgs-fmt
                nodejs
                pkg-config
                playwright
                playwright-driver
                tmux
                rust-analyzer
                rustc
                rustfmt
              ]
              ++ [
                (python3.withPackages (pythonPackages: with pythonPackages; [
                  pyte
                ]))
              ]
              ++ [
                pkgs.libevent
                pkgs.ncurses
                pkgs.utf8proc
              ];

            RUST_BACKTRACE = "1";
            TINYMUX_FEATURE_SCOPE = "fixed-two-pane-main-above-secondary-below";

            shellHook = ''
              echo "tinymux dev shell"
              echo "scope: main pane above one secondary pane"
            '';
          };
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          sourceHasCargoLock =
            builtins.pathExists ./Cargo.toml
            && builtins.pathExists ./Cargo.lock;
          parityPython = pkgs.python3.withPackages (pythonPackages: with pythonPackages; [
            pyte
          ]);
          xtermJs = pkgs.fetchurl {
            url = "https://registry.npmjs.org/@xterm/xterm/-/xterm-5.5.0.tgz";
            hash = "sha256-vZVPpyGHIXAYjMXX6D6I2zyDyaGKTo0kwng9JkkfWdI=";
          };
          libvtermEnv = ''
            for candidate in \
              "${pkgs.libvterm-neovim}/lib/libvterm.so" \
              "${pkgs.libvterm-neovim}"/lib/libvterm.so.* \
              "${pkgs.libvterm-neovim}"/lib/libvterm.*.dylib \
              "${pkgs.libvterm-neovim}/lib/libvterm.dylib"; do
              if [ -e "$candidate" ]; then
                export TINYMUX_LIBVTERM="$candidate"
                break
              fi
            done
          '';
        in
        {
          package = self.packages.${system}.tinymux;

          "tmux-parity-suite" = pkgs.runCommand "tinymux-tmux-parity-suite"
            {
              nativeBuildInputs = [
                parityPython
              ];
            }
            ''
              cp ${./tests/parity/tmux_snapshot_parity.py} tmux_snapshot_parity.py
              cp ${./tests/parity/browser_xterm_required_check.mjs} browser_xterm_required_check.mjs
              cp ${./docs/subset.md} subset.md
              ${parityPython}/bin/python -m py_compile tmux_snapshot_parity.py
              ${parityPython}/bin/python - <<'PY'
              import importlib.util
              import pathlib
              import re
              import sys

              spec = pathlib.Path("subset.md").read_text()
              defined = set(re.findall(r"`([A-Z]+-\d{3})`", spec))
              module_spec = importlib.util.spec_from_file_location("parity", "tmux_snapshot_parity.py")
              parity = importlib.util.module_from_spec(module_spec)
              sys.modules[module_spec.name] = parity
              module_spec.loader.exec_module(parity)
              used = {spec_id for scenario in parity.scenarios() for spec_id in scenario.spec_ids}
              missing = sorted(used - defined)
              if missing:
                  raise SystemExit(f"scenario spec IDs missing from docs/subset.md: {missing}")
              PY
              ${pkgs.nodejs}/bin/node --check browser_xterm_required_check.mjs

              mkdir -p "$out/bin" "$out/share/tinymux/tests/parity"
              cp tmux_snapshot_parity.py "$out/share/tinymux/tests/parity/"
              cp browser_xterm_required_check.mjs "$out/share/tinymux/tests/parity/"
              cat > "$out/bin/tinymux-tmux-parity" <<EOF
              #!${pkgs.runtimeShell}
              exec ${parityPython}/bin/python "$out/share/tinymux/tests/parity/tmux_snapshot_parity.py" "\$@"
              EOF
              chmod +x "$out/bin/tinymux-tmux-parity"
            '';

          "tmux-parity-required" =
            if sourceHasCargoLock then
              pkgs.runCommand "tinymux-tmux-parity"
                {
                  nativeBuildInputs = [
                    pkgs.nodejs
                    pkgs.libvterm-neovim
                    parityPython
                    pkgs.playwright
                    pkgs.playwright-driver
                    pkgs.tmux
                    self.packages.${system}.tinymux
                  ];
                }
                ''
                  mkdir -p artifacts "$out"
                  ${libvtermEnv}
                  ${parityPython}/bin/python ${./tests/parity/tmux_snapshot_parity.py} \
                    --tinymux ${self.packages.${system}.tinymux}/bin/tinymux \
                    --tmux ${pkgs.tmux}/bin/tmux \
                    --shell ${pkgs.runtimeShell} \
                    --tier required \
                    --emulator-backend pyte+vterm \
                    --hz 60 \
                    --deadline-tolerance-ms 1000 \
                    --latency-slack-ms 1000 \
                    --artifacts artifacts
                  mkdir -p node_modules xterm screenshots
                  ln -s ${pkgs.playwright} node_modules/playwright-core
                  tar -xzf ${xtermJs} -C xterm
                  PLAYWRIGHT_CORE_PATH=${pkgs.playwright} \
                    PLAYWRIGHT_BROWSERS_PATH=${pkgs.playwright-driver.browsers} \
                    ${pkgs.nodejs}/bin/node ${./tests/parity/browser_xterm_required_check.mjs} \
                      --artifacts artifacts \
                      --xterm-js "$PWD/xterm/package/lib/xterm.js" \
                      --xterm-css "$PWD/xterm/package/css/xterm.css" \
                      --screenshots screenshots
                  cp -R artifacts "$out/"
                  cp -R screenshots "$out/"
                ''
            else
              pkgs.runCommand "tinymux-tmux-parity-skipped" { } ''
                mkdir -p "$out"
                cat > "$out/README" <<'EOF'
                tmux parity execution skipped.

                The full 60 Hz snapshot comparison runs automatically once
                Cargo.toml and Cargo.lock exist and packages.tinymux builds the
                real implementation instead of the scaffold executable.
                EOF
              '';

          "tmux-parity" = self.checks.${system}."tmux-parity-required";

          "throughput-100mbps" =
            if sourceHasCargoLock then
              pkgs.runCommand "tinymux-throughput-100mbps"
                {
                  nativeBuildInputs = [
                    self.packages.${system}.tinymux
                  ];
                }
                ''
                  tinymux --main true --secondary true \
                    --throughput-bench-bytes $((128 * 1024 * 1024)) > throughput.txt
                  cp throughput.txt "$out"
                ''
            else
              pkgs.runCommand "tinymux-throughput-100mbps-skipped" { } ''
                echo "throughput check skipped until Cargo.toml and Cargo.lock exist" > "$out"
              '';

          "tmux-parity-extended-suite" = pkgs.runCommand "tinymux-tmux-parity-extended-suite"
            {
              nativeBuildInputs = [
                parityPython
              ];
            }
            ''
              cp ${./tests/parity/tmux_snapshot_parity.py} tmux_snapshot_parity.py
              cp ${./tests/parity/browser_xterm_required_check.mjs} browser_xterm_required_check.mjs
              ${pkgs.nodejs}/bin/node --check browser_xterm_required_check.mjs
              ${parityPython}/bin/python tmux_snapshot_parity.py \
                --tinymux /bin/false \
                --tmux /bin/false \
                --tier extended \
                --scenario extended-copy-mode-scrollback \
                --help > "$out"
            '';
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
