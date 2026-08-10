{ lib }:
let
  zigCpuForPlatform = import ./zig-cpu.nix { inherit lib; };
  platform =
    { system ? "x86_64-linux"
    , isx86_64 ? false
    , isAarch64 ? false
    , gcc ? { }
    ,
    }:
    {
      inherit
        system
        isx86_64
        isAarch64
        gcc
        ;
    };
  resolve = value: zigCpuForPlatform { platform = value; };
in
assert resolve (platform { isx86_64 = true; }) == "baseline";
assert resolve
  (platform {
    isx86_64 = true;
    gcc.arch = "x86-64-v3";
  }) == "x86_64_v3";
assert resolve
  (platform {
    isx86_64 = true;
    gcc.arch = "znver4";
  }) == "znver4";
assert resolve
  (platform {
    system = "aarch64-linux";
    isAarch64 = true;
    gcc.arch = "armv8-a";
  }) == "baseline";
assert resolve
  (platform {
    system = "aarch64-darwin";
    isAarch64 = true;
    gcc = {
      arch = "armv8.3-a+crypto+sha2+aes+crc+fp16+lse+simd+ras+rdm+rcpc";
      cpu = "apple-a13";
    };
  }) == "apple_a13";
assert resolve
  (platform {
    system = "aarch64-linux";
    isAarch64 = true;
    gcc.arch = "armv8.3-a+crypto+fp16+simd";
  }) == "baseline+v8_3a+crypto+fullfp16+neon";
assert zigCpuForPlatform
  {
    platform = platform { isx86_64 = true; };
    cpuOverride = "custom_cpu+feature";
  } == "custom_cpu+feature";
assert !(builtins.tryEval (resolve (platform {
  system = "aarch64-linux";
  isAarch64 = true;
  gcc.arch = "armv10-a";
}))).success;
true
