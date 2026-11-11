{
  lib,
  stdenv,
  linkFarm,

  zig,

  aroSrc,
  clapSrc,
  fipSrc,
  tomlc17Src,

  commitHash,
  commitDate,
}:

let
  # We construct our own 'zig-pkg' dir Zig then uses, so we still have control over fetching the dependencies before building
  zigPkgDir = linkFarm "fip-c-zig-pkg" [
    {
      name = "aro-0.0.0-JSD1QieDNwCxnCLH968EXw7cC_HFWpJ1Km0J6B_8gNzM";
      path = aroSrc;
    }
    {
      name = "clap-0.12.0-oBajB4XpAQCF1WRKnD5KOKPsnwwT_NNdAJ7Ww3irYJac";
      path = clapSrc;
    }
    {
      name = "fip-0.4.1-jXH3OV_oAgBzsf1MwFW1bfnemaM6u9wd3lgM5Fdpxxpo";
      path = fipSrc;
    }
    {
      name = "N-V-__8AAFeHAgBabNQUR0r3Nw2q1AtSvpwQVLt8ihh50mYO";
      path = tomlc17Src;
    }
  ];
in
stdenv.mkDerivation {
  pname = "fip-c";
  version = "0.4.2-0";

  src = lib.cleanSourceWith {
    src = ./.;

    filter =
      path: type:

      let
        name = builtins.baseNameOf (toString path);
      in
      lib.cleanSourceFilter path type
      && !(builtins.elem name [
        "result"
        "zig-out"
        ".zig-cache"
      ]);
  };

  strictDeps = true;
  __structuredAttrs = true;

  nativeBuildInputs = [
    zig
  ];

  dontSetZigDefaultFlags = true;
  enableParallelBuilding = true;

  zigBuildFlags = [
    "--system"
    "${zigPkgDir}"
    "-Dcommit-hash=${commitHash}"
    "-Dcommit-date=${commitDate}"
    "-j2"
    "--release=small"
  ];

  meta = {
    description = "C Interop Module utilizing the Flint Interop Protocol";
    homepage = "https://github.com/flint-lang/fip-c";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "fip-c";
  };
}
