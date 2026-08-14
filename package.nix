{ lib
, stdenv
, fetchzip
, callPackage
, runCommand
, zig_0_16
, python3
, bashInteractive
, fish
, zsh
, nushell
, apple-sdk
, writeShellScriptBin
, zigCpu ? null
,
}:
let
  ghosttyRev = "6ad1fe7d8cbda36c77b337a96c9bea8a77883699";
  ghosttySrc = fetchzip {
    url = "https://github.com/ghostty-org/ghostty/archive/${ghosttyRev}.tar.gz";
    hash = "sha256-tmsO+ORO9TgdCBuLru4071zQJmgbaobLIMKV5QE4bFY=";
  };
  ghosttyDeps = callPackage "${ghosttySrc}/build.zig.zon.nix" {
    name = "tinymux-ghostty-cache-${ghosttyRev}";
    linkFarm =
      name: entries:
      runCommand name { } ''
        mkdir -p "$out"
        ${lib.concatMapStringsSep "\n" (entry: ''
          cp -rL ${entry.path} "$out/${entry.name}"
        '') entries}
      '';
  };
  effectiveZigCpu = import ./nix/zig-cpu.nix { inherit lib; } {
    platform = stdenv.hostPlatform;
    cpuOverride = zigCpu;
  };
  xcodeSelect = writeShellScriptBin "xcode-select" ''
    echo ${apple-sdk}
  '';
in
stdenv.mkDerivation {
  pname = "tinymux";
  version = "0.1.0";

  src = lib.cleanSource ./.;

  nativeBuildInputs = [
    zig_0_16
    python3
    bashInteractive
    fish
    zsh
    nushell
  ]
  ++ lib.optionals stdenv.hostPlatform.isDarwin [ xcodeSelect ];

  buildInputs = lib.optionals stdenv.hostPlatform.isDarwin [ apple-sdk ];

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
    zig build --system ${ghosttyDeps} "-Dcpu=${effectiveZigCpu}" -Doptimize=ReleaseSafe --summary all --prefix "$out"
    runHook postBuild
  '';

  checkPhase = ''
    runHook preCheck
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
    export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
    zig build --system ${ghosttyDeps} "-Dcpu=${effectiveZigCpu}" test --summary all
    # Darwin's Nix sandbox does not reliably deliver the watcher
    # exit signal used by the full seamless-shell lifecycle tests.
    python3 ${./tests/spec/tinymux_contract.py} \
      --tinymux "$out/bin/tinymux" \
      ${lib.optionalString stdenv.hostPlatform.isDarwin "--persistent-only"}
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    runHook postInstall
  '';

  doCheck = true;

  passthru.zigCpu = effectiveZigCpu;

  meta = with lib; {
    description = "Tiny Boo-style split terminal multiplexer";
    homepage = "https://github.com/conroy/tinymux";
    mainProgram = "tinymux";
    platforms = platforms.unix;
  };
}
