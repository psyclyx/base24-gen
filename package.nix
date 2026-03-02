{
  lib,
  stdenv,
  zig_0_15,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "base24-gen";
  version = "0.1.0";

  src = ./.;

  nativeBuildInputs = [ zig_0_15 ];

  # stb_image is vendored; no system libraries required beyond libc.

  buildPhase = ''
    export HOME=$(mktemp -d)
    zig build --prefix $out -Doptimize=ReleaseSafe
  '';

  installPhase = "true";

  meta = {
    description = "Deterministic Base24 colour scheme generator from images";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "base24-gen";
  };
})
