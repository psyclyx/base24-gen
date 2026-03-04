{
  lib,
  stdenv,
  installShellFiles,
  zig_0_15,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "base24-gen";
  version = "0.1.0";

  src = ./.;

  nativeBuildInputs = [
    zig_0_15
    installShellFiles
  ];

  # stb_image is vendored; no system libraries required beyond libc.

  buildPhase = ''
    export HOME=$(mktemp -d)
    zig build --prefix $out -Doptimize=ReleaseSafe
  '';

  installPhase = ''
    installShellCompletion --bash completions/base24-gen.bash
    installShellCompletion --zsh completions/base24-gen.zsh
    installShellCompletion --fish completions/base24-gen.fish
  '';

  meta = {
    description = "Deterministic Base24 colour scheme generator from images";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "base24-gen";
  };
})
