{
  stdenv,
  fetchFromGitHub,
  autoPatchelfHook,
  lib,
  lld,
  zig,
  cmake,
  ninja,
  python3,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "fip-c";
  version = "0.3.2-unstable-2026-06-27";

  src = fetchFromGitHub {
    owner = "flint-lang";
    repo = "fip";
    # For the 0.4.0 release the rev can be changed to the tag again
    # tag = "v${finalAttrs.version}";
    rev = "07fcee0158b5eedf4b1dfea308579873abb152e0";
    sha256 = "";
  };

  llvm-src = fetchFromGitHub {
    owner = "llvm";
    repo = "llvm-project";
    tag = "llvmorg-21.1.8";
    hash = "sha256-pgd8g9Yfvp7abjCCKSmIn1smAROjqtfZaJkaUkBSKW0=";
  };

  nativeBuildInputs = [
    autoPatchelfHook
    lld
    zig
    cmake
    ninja
    python3
  ];

  strictDeps = true;
  __structuredAttrs = true;

  dontSetZigDefaultFlags = true;
  zigBuildFlags = [
    "--release=small"
    "-Dllvm-dir=${finalAttrs."llvm-src"}"
  ];

  meta = with lib; {
    description = "C Interop Module utilizing the Flint Interop Protocol";
    homepage = "https://github.com/flint-lang/fip";
    license = licenses.mit;
    platforms = [ "x86_64-linux" ];
    maintainers = with maintainers; [ zweiler1 ];
    mainProgram = "fip-c";
  };
})
