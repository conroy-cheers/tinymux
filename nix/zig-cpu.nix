{ lib }:
{ platform
, cpuOverride ? null
,
}:
let
  normalizeModel = builtins.replaceStrings [ "-" ] [ "_" ];

  x86Cpu =
    let
      arch = platform.gcc.arch or null;
    in
    if arch == null || arch == "x86-64" then
      "baseline"
    else if builtins.hasAttr arch lib.systems.architectures.features then
      normalizeModel arch
    else
      throw "tinymux: unsupported Nix x86 CPU architecture '${arch}'; set zigCpu explicitly";

  armExtension = extension:
    {
      aes = "aes";
      crc = "crc";
      crypto = "crypto";
      fp16 = "fullfp16";
      lse = "lse";
      ras = "ras";
      rcpc = "rcpc";
      rdm = "rdm";
      sha2 = "sha2";
      simd = "neon";
    }.${extension}
      or (throw "tinymux: unsupported Nix AArch64 extension '${extension}'; set zigCpu explicitly");

  armArchCpu = arch:
    let
      parts = lib.splitString "+" arch;
      base = builtins.head parts;
      extensions = builtins.tail parts;
      baseFeature =
        {
          armv8-a = null;
          "armv8.1-a" = "v8_1a";
          "armv8.2-a" = "v8_2a";
          "armv8.3-a" = "v8_3a";
          "armv8.4-a" = "v8_4a";
          "armv8.5-a" = "v8_5a";
          "armv8.6-a" = "v8_6a";
          "armv8.7-a" = "v8_7a";
          "armv8.8-a" = "v8_8a";
          "armv8.9-a" = "v8_9a";
          armv9-a = "v9a";
          "armv9.1-a" = "v9_1a";
          "armv9.2-a" = "v9_2a";
          "armv9.3-a" = "v9_3a";
          "armv9.4-a" = "v9_4a";
        }.${base}
          or (throw "tinymux: unsupported Nix AArch64 architecture '${base}'; set zigCpu explicitly");
      features = lib.optional (baseFeature != null) baseFeature ++ map armExtension extensions;
    in
    "baseline" + lib.concatMapStrings (feature: "+${feature}") features;

  armCpu =
    let
      cpu = platform.gcc.cpu or null;
      arch = platform.gcc.arch or null;
    in
    if cpu != null then
      normalizeModel cpu
    else if arch == null then
      "baseline"
    else
      armArchCpu arch;
in
if cpuOverride != null then
  cpuOverride
else if platform.isx86_64 then
  x86Cpu
else if platform.isAarch64 then
  armCpu
else
  throw "tinymux: unsupported Nix platform '${platform.system}'; set zigCpu explicitly"
